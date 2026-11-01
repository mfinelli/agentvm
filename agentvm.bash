#!/usr/bin/env bash

set -euo pipefail

# I'm experimenting with running an agent in a dedicated throwaway VM to keep
# it isolated from the rest of my system and to give it more autonomy. This
# script is to speed-up the initial "setup" of a new VM. Currently runs against
# a Debian Trixie install with the GNOME desktop and standard system utilities.
#
# 1. Install curl: sudo apt install curl
# 2. Run the script: bash -c "$(curl -fsSL https://mfgo.link/agentvm)"
#
# How it is put together:
#
# - Every chunk of setup is a `component_<name>` function.
# - `COMPONENTS` is the registry. It lists the components in the order they
#   must run; a component may rely on anything earlier in that list.
# - `DEPENDS` declares hard requirements between components (rea needs node,
#   node needs mise). `use` pulls them in transitively, so a project only
#   names what it actually wants. Every dependency must also appear earlier in
#   COMPONENTS; that is checked at startup.
# - `project_<name>` functions declare what they want via `use`, listing every
#   component they need in full. Order inside a project does not matter.
#   A one-off package that does not deserve a component goes in `apt_extra`;
#   promote it to a component once a second project needs it. `npm_global` is
#   the same idea for npm packages installed with `npm install -g`, and pulls
#   in the `node` component.
# - The VM hostname is `omp-PROJECT`, so `omp-agentvm` picks `project_agentvm`.
#   AGENTVM_PROJECT overrides the detection.
#
# Secrets:
#   vm-provision pushes files into /dev/shm/secrets before this script runs.
#   A secret is required whenever a selected component consumes it. Components
#   read them with `secret_value VAR` (a value) or `take_secret` (a file
#   installed at SECRET_DEST). Anything left over at the end is reported and
#   removed.
#
# Git authentication:
#   The `git` component installs `github-token` at
#   ~/.config/git/tokens/github.com and configures a credential helper scoped
#   to https://github.com only. A second provider gets its own file and its
#   own scoped helper, e.g. credential.https://gitlab.com.helper reading
#   tokens/gitlab.com.
#
# AGENTVM_DRY_RUN=1 prints what would happen without touching the system.
# `--list` prints the components a project would run, marking ones that were
# only pulled in as dependencies.
# `--only COMPONENT...` applies named components (and their dependencies) and
# ignores the project, so a VM that is already built can gain one component.
# `--only` also works on a host that is not named omp-PROJECT. A targeted run
# does not sweep secrets: it cannot tell an unconsumed secret from one that a
# later run still needs.

GHIDRA_BASE=https://github.com/NationalSecurityAgency/ghidra/releases/download
GHIDRA_VERSION=Ghidra_12.2_build/ghidra_12.2_PUBLIC_20261016
GHIDRA_INSTALL_STR=ghidra_12.2_PUBLIC
NERDFONTS_BASE=https://github.com/ryanoasis/nerd-fonts/releases/download
NERDFONTS_VERSION=3.5.1
BASH_IT_REPO=https://github.com/Bash-it/bash-it
AGENTVM_REPO=https://github.com/mfinelli/agentvm.git
AGENTVM_LINK=${AGENTVM_LINK:-$HOME/.local/bin/agentvm}
# where component_agentvm keeps its checkout
AGENTVM_DIR=${AGENTVM_DIR:-$HOME/.agentvm}

# oh-my-pi settings, applied by component_omp. Values are the ones `omp config
# list` documents for each key; the composer shape is the "Pi" layout from the
# first-run picker, and the symbol preset picks the Nerd Font glyph set.
OMP_SYMBOL_PRESET=${AGENTVM_OMP_SYMBOL_PRESET:-nerd}
OMP_COMPOSER_SHAPE=${AGENTVM_OMP_COMPOSER_SHAPE:-pi}
# `system` would follow the terminal's light/dark mode, but omp's first-run
# picker stores a pair instead, so do the same and make the choice explicit.
OMP_THEME_DARK=${AGENTVM_OMP_THEME_DARK:-titanium}
OMP_THEME_LIGHT=${AGENTVM_OMP_THEME_LIGHT:-light}
OMP_MODEL=${AGENTVM_OMP_MODEL:-ollama-cloud/deepseek-v4.1-flash}

# omp-ntfy settings, applied by component_ntfy. The libvirt NAT gateway is the
# default because that is where a self-hosted ntfy usually listens from the
# guest's point of view.
NTFY_SERVER=${AGENTVM_NTFY_SERVER:-http://192.168.123.1:8081}
NTFY_TOPIC=${AGENTVM_NTFY_TOPIC:-omp}

COMPONENTS=(
  base
  editor
  git
  bash
  screen
  fonts
  java
  ghidra
  buildtools
  re
  rust
  dosbox
  mise
  go
  node
  docker
  omp
  ntfy
  rea
  agentvm
  repos
)

declare -A KNOWN=() WANTED=() DECLARED=()
# packages a single project needs that are not worth their own component
EXTRA_PKGS=()
# npm packages installed globally, in node's mise prefix
NPM_GLOBAL=()
# mise tools installed globally, for anything no apt suite carries
MISE_GLOBAL=()
# repositories this project works on, cloned into ~/src by component_repos
REPOS=()

# ---------------------------------------------------------------------------
# secrets
#
# vm-provision (on the operator's machine) pushes files into SECRET_DIR.
# Components consume them with `take_secret` / `secret_value`, and anything
# left over at the end is reported and removed.
#
# SECRET_DEST maps a secret name to the file it is installed as. An empty
# value means the secret is a value to read (see `secret_value`) and not a
# file. A name absent from this map has no destination and is reported as
# unknown when left over.
#
# SECRET_USERS maps a secret name to the components that consume it. Selecting
# any of those components makes the secret required. Two components sharing
# one secret both appear here.
# ---------------------------------------------------------------------------

SECRET_DIR=${AGENTVM_SECRET_DIR:-/dev/shm/secrets}

declare -A SECRET_DEST=(
  ["git-name"]=""
  ["git-email"]=""
  # Tokens are installed per host under ~/.config/git/tokens/<host>, so a
  # second provider (gitlab, ...) gets its own file. The host is part of the
  # path, so the credential helper can be scoped to exactly that host.
  ["github-token"]="$HOME/.config/git/tokens/github.com"
  ["ollama-token"]=""
)

declare -A SECRET_USERS=(
  ["git-name"]='git'
  ["git-email"]='git'
  ["github-token"]='git'
  ["ollama-token"]='omp'
)

REQUIRED_SECRETS=()
# names consumed during this run, so the sweep does not re-report them
CONSUMED_SECRETS=()

# DEPENDS[c] is the space separated list of components c requires. `use`
# pulls these in transitively, and COMPONENTS already runs them first, so
# declaring an edge never changes execution order.
declare -A DEPENDS=(
  [bash]='git'
  [ghidra]='java'
  [go]='mise'
  [node]='mise'
  [ntfy]='omp'
  [rea]='node re'
)

for c in "${COMPONENTS[@]}"; do KNOWN[$c]=1; done

# An edge is only meaningful if the dependency actually runs first, otherwise
# the dependent would use a tool that is not installed yet.
declare -A POS=()
for i in "${!COMPONENTS[@]}"; do POS[${COMPONENTS[$i]}]=$i; done

for c in "${!DEPENDS[@]}"; do
  for d in ${DEPENDS[$c]}; do
    if [[ -z ${KNOWN[$d]:-} ]]; then
      echo "component $c depends on unknown $d" >&2
      exit 2
    fi
    if [[ $d == "$c" ]]; then
      echo "component $c depends on itself" >&2
      exit 2
    fi
    if ((POS[$d] > POS[$c])); then
      echo "component $c depends on $d, but $d runs after $c in COMPONENTS" >&2
      exit 2
    fi
  done
done

# Every secret must have a destination, and each consumer it names must be a
# real component.
for s in "${!SECRET_DEST[@]}"; do
  if [[ -z ${SECRET_USERS[$s]+set} ]]; then
    echo "secret $s has no consumer in SECRET_USERS" >&2
    exit 2
  fi
done
for s in "${!SECRET_USERS[@]}"; do
  if [[ -z ${SECRET_DEST[$s]+set} ]]; then
    echo "secret $s is used but has no SECRET_DEST entry" >&2
    exit 2
  fi
  for c in ${SECRET_USERS[$s]}; do
    if [[ -z ${KNOWN[$c]:-} ]]; then
      echo "secret $s names unknown component $c" >&2
      exit 2
    fi
  done
done

# ---------------------------------------------------------------------------
# project definitions: what a given `omp-PROJECT` box needs
#
# Most projects want the same baseline; that lives in `use_standard` so a new
# baseline component is added in one place. A project then lists only what it
# adds on top. Projects generally do not call each other, but they can if it
# is useful. Order here does not matter: COMPONENTS decides execution order.
# ---------------------------------------------------------------------------

# The baseline every VM gets.
use_standard() {
  use base editor git bash screen fonts mise omp ntfy agentvm
}

project_agentvm() {
  use_standard
  apt_extra bats shellcheck shfmt
  npm_global prettier@3
  mise_global "aqua:rhysd/actionlint@1"
  repo mfinelli/agentvm mfinelli/dotfiles
}

project_opentower() {
  use_standard
  use buildtools rust
  use ghidra dosbox rea
  apt_extra libasound2-dev
}

# recueil: Go service, Svelte frontend and a compose stack to develop against.
project_recueil() {
  use_standard
  use buildtools go node docker
  mise_global sqlc@1
  repo mfinelli/recueil
}

# Anything unrecognised gets everything.
project_default() {
  use "${COMPONENTS[@]}"
}

# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

HOST=${HOSTNAME%%.*}
DRY_RUN=${AGENTVM_DRY_RUN:-0}

log() { printf '\n==> %s\n' "$*"; }
usage() {
  cat << 'EOF'
Usage: agentvm.bash [--list] [--only COMPONENT...]
       agentvm.bash --help

Runs the project for this VM's hostname (omp-PROJECT) and applies every
component it selects.

  --list              print what the run would apply, then exit
  --only COMPONENT... apply just these components (and their dependencies),
                      ignoring the project. Works on any hostname.
  --update            git pull the checkout at ~/.agentvm and exit
  -h, --help          show this help

  COMPONENT may be repeated, separated by spaces, or comma separated.

Environment:
  AGENTVM_PROJECT     override hostname detection
  AGENTVM_SECRET_DIR  directory vm-provision pushed secrets to
  AGENTVM_DIR         checkout location (default: ~/.agentvm)
  AGENTVM_LINK        symlink to the script (default: ~/.local/bin/agentvm)
  AGENTVM_DRY_RUN=1   print the commands instead of running them
EOF
}
run() {
  log "+ $*"
  ((DRY_RUN)) || "$@"
}
# for `curl | sh` installers, which are fine here: this is a throwaway VM
run_sh() {
  log "+ sh -c '$1'"
  ((DRY_RUN)) || bash -c "$1"
}
apt_install() {
  run sudo apt-get install -y "$@"
}
# Put a directory on PATH for the rest of this run. Components cannot rely on
# ~/.bashrc: it is written for interactive shells, and sourcing it under
# `set -e` is unsafe (see component_mise).
path_add() {
  local dir=$1
  ((DRY_RUN)) || [[ -d $dir ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) return 0 ;;
  esac
  log "+ PATH=$dir:\$PATH"
  ((DRY_RUN)) || export PATH="$dir:$PATH"
}

# append a line to ~/.bashrc once, so re-running the script stays clean
bashrc_add() {
  local line=$1
  if grep -qxF -- "$line" "$HOME/.bashrc" 2> /dev/null; then
    return 0
  fi
  log "+ ~/.bashrc += $line"
  ((DRY_RUN)) || printf '%s\n' "$line" >> "$HOME/.bashrc"
}

# Write a config file from stdin, replacing it only when the content differs.
# Comparing first keeps a re-run from rewriting the file and losing the mtime
# (and, for a dotfile the operator edits, from clobbering it silently).
install_config() {
  local dest=$1 content
  content=$(cat)
  if [[ -f $dest ]] && [[ $(< "$dest") == "$content" ]]; then
    return 0
  fi
  log "+ $dest"
  ((DRY_RUN)) && return 0
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest"
}

use() {
  local c d
  for c in "$@"; do
    _want "$c"
    # only the outermost call marks components as explicitly requested
    DECLARED[$c]=1
  done
}

_want() {
  local c=$1 d
  if [[ -z ${KNOWN[$c]:-} ]]; then
    echo "unknown component: $c" >&2
    exit 2
  fi
  # already wanted: its dependencies were resolved on the first pass
  if [[ -n ${WANTED[$c]:-} ]]; then
    return 0
  fi
  WANTED[$c]=1
  # shellcheck disable=SC2086 # DEPENDS holds a space separated list
  for d in ${DEPENDS[$c]:-}; do
    _want "$d"
  done
}

# Declare packages for this project only, installed with one apt call.
# Same idea as `use`, but for things that do not deserve a component yet.
apt_extra() {
  EXTRA_PKGS+=("$@")
}

# Declare npm packages this project needs globally, installed with one
# `npm install -g` once every component has run.
#
# This is `apt_extra` for npm, and it is the right place for a tool a project
# needs but no component should own.
#
# It selects `node`, because a global install has nowhere to go without it.
# mise's node prefix is user-writable, so the install needs no sudo and the
# binaries land in ~/.local/share/mise/shims, which component_node puts on
# PATH. Entries go to npm verbatim, so pin inline (`prettier@3`) when
# necessary.
npm_global() {
  # `_want`, not `use`: node is a requirement of these packages, so `--list`
  # should show it as a dependency rather than something the project named.
  _want node
  NPM_GLOBAL+=("$@")
}

# Declare mise-managed tools this project needs, installed with one
# `mise use -g` after every component has run.
#
# This is `npm_global` for anything mise can install. It exists for tools that
# are in no apt suite, where the alternative is a pinned download and a
# checksum.
#
# The version is passed through verbatim, so pin it the same way you would for
# npm_global (`actionlint@1` follows the 1.x line). `mise use -g` writes the
# pin to the global config and is idempotent, so a re-run is a no-op rather
# than an upgrade.
mise_global() {
  # `_want`, not `use`: mise is a requirement of these tools, so `--list`
  # should show it as a dependency rather than something the project named.
  _want mise
  MISE_GLOBAL+=("$@")
}

# Declare repositories this project works on, cloned into ~/src by
# component_repos.
#
# Either a full URL (https or ssh) or an `owner/name` shorthand, which expands
# to https://github.com/owner/name.git.
repo() {
  # `_want`, not `use`: the component and git are requirements of the
  # declaration, so `--list` shows them as dependencies rather than things the
  # project named. `_want git` is deliberate -- a repository you branch, commit
  # and push to needs an identity, so it pulls in the git component (and its
  # secrets) rather than just the package.
  _want repos
  _want git
  REPOS+=("$@")
}

# Fill REQUIRED_SECRETS from the components that are actually selected. Called
# after the project function has run, before anything is installed.
resolve_secrets() {
  local s users c
  for s in "${!SECRET_USERS[@]}"; do
    # shellcheck disable=SC2086 # SECRET_USERS holds a space separated list
    for users in ${SECRET_USERS[$s]}; do
      if [[ -n ${WANTED[$users]:-} ]]; then
        REQUIRED_SECRETS+=("$s")
        break
      fi
    done
  done
}

_secret_check() {
  local s=$1
  if [[ -z ${SECRET_DEST[$s]+set} ]]; then
    echo "unknown secret: $s (add it to SECRET_DEST)" >&2
    exit 2
  fi
  if [[ ! -f $SECRET_DIR/$s ]]; then
    echo "missing secret: $s (re-run vm-provision)" >&2
    exit 3
  fi
}

# Install a file-secret at its destination, 0600, then drop the original.
take_secret() {
  local s=$1 dest=${SECRET_DEST[$1]}
  _secret_check "$s"
  if [[ -z $dest ]]; then
    echo "secret $s has no destination; use secret_value" >&2
    exit 2
  fi
  CONSUMED_SECRETS+=("$s")
  if ((DRY_RUN)); then
    log "would install secret $s -> $dest"
    return 0
  fi
  # install sets the mode regardless of umask, but does not create parents
  run mkdir -p "$(dirname "$dest")"
  install -m 600 "$SECRET_DIR/$s" "$dest"
  rm -f "$SECRET_DIR/$s"
  log "consumed secret $s"
}

# Read a value-secret and drop the original, storing it in the named variable.
# Uses a nameref rather than stdout: a command substitution runs in a subshell,
# where the consumed-secret tracking would be lost.
secret_value() {
  local s=$1 var=$2
  _secret_check "$s"
  if [[ -n ${SECRET_DEST[$s]} ]]; then
    echo "secret $s has a destination; use take_secret" >&2
    exit 2
  fi
  # Reject an empty secret before deleting it. Consuming first would delete the
  # evidence, so a retry would fail at the preflight instead of showing the same
  # error, and the operator would have no file left to inspect.
  if ((DRY_RUN == 0)) && [[ ! -s $SECRET_DIR/$s ]]; then
    echo "secret $s is empty" >&2
    exit 3
  fi
  CONSUMED_SECRETS+=("$s")
  if ((DRY_RUN)); then
    log "would consume secret $s" >&2
    return 0
  fi
  local -n out=$var
  # shellcheck disable=SC2034 # assigned through the nameref, read by caller
  out=$(< "$SECRET_DIR/$s")
  rm -f "$SECRET_DIR/$s"
  log "consumed secret $s" >&2
}

# ---------------------------------------------------------------------------
# components
# ---------------------------------------------------------------------------

component_base() {
  apt_install curl rsync wget
  apt_install bat htop jq
  apt_install python3 python3-pip
  apt_install magic-wormhole
  apt_install imagemagick
  apt_install 7zip libarchive-tools unzip
  apt_install just
}

component_editor() {
  apt_install vim
  bashrc_add 'export EDITOR=vim'
}

component_git() {
  apt_install git

  local git_name git_email token
  secret_value git-name git_name
  secret_value git-email git_email
  token=${SECRET_DEST["github-token"]}
  take_secret github-token
  ((DRY_RUN)) && return 0

  run git config --global user.name "$git_name"
  run git config --global user.email "$git_email"

  # Read-only PAT over https. The helper is configured for github.com only,
  # so another provider (gitlab, ...) can add its own scoped helper.
  run git config --global --unset-all credential.helper || true
  run git config --global "credential.https://github.com.helper" \
    "!f() { [ \"\$1\" = get ] && { echo username=x-access-token; echo \"password=\$(cat $token)\"; }; }; f"
}

component_fonts() {
  local dir=$HOME/.local/share/fonts
  if [[ -e $dir/AdwaitaMonoNerdFont-Regular.ttf ]]; then
    return 0
  fi
  run mkdir -p "$dir"
  run wget -O "$dir/AdwaitaMono.zip" \
    "${NERDFONTS_BASE}/v${NERDFONTS_VERSION}/AdwaitaMono.zip"
  run bsdtar -xf "$dir/AdwaitaMono.zip" -C "$dir"
  run rm "$dir/AdwaitaMono.zip"
  run fc-cache -fv
}

component_java() {
  apt_install openjdk-25-jdk
}

component_ghidra() {
  local zip
  zip=$(basename "$GHIDRA_VERSION.zip")
  run mkdir -p "$HOME/Downloads"
  run wget -O "$HOME/Downloads/$zip" "$GHIDRA_BASE/$GHIDRA_VERSION.zip"
  run bsdtar -xf "$HOME/Downloads/$zip" -C "$HOME/Downloads"
  bashrc_add "export GHIDRA_INSTALL_DIR=~/Downloads/$GHIDRA_INSTALL_STR"
}

component_bash() {
  # bash-it, sourced from ~/.bashrc rather than via its install script: the
  # installer rewrites ~/.bashrc itself, and these settings would have to be
  # applied afterwards anyway.
  local dir=$HOME/.bashit
  if [[ ! -d $dir/.git ]]; then
    run git clone --depth 1 "$BASH_IT_REPO" "$dir"
  fi

  # A place for work, referenced by BASH_IT_PROJECT_PATHS below.
  run mkdir -p "$HOME/src"

  bashrc_add "export BASH_IT=\"$dir\""
  bashrc_add "export BASH_IT_THEME='minimal'"
  bashrc_add "export BASH_IT_PROJECT_PATHS=\"$HOME/src\""
  bashrc_add 'export BASH_IT_COMMAND_DURATION=true'
  bashrc_add 'export COMMAND_DURATION_MIN_SECONDS=1'
  # last, so every setting above is in scope when bash-it loads
  # shellcheck disable=SC2016 # literal text for ~/.bashrc, expanded at login
  bashrc_add 'source "${BASH_IT?}/bash_it.sh"'
}

component_screen() {
  apt_install screen

  # The status line is the point of this file, so spell out what each block is:
  #
  #   [host][current][session UTC]         [other windows]
  #
  # The fixed part comes first on purpose. screen truncates a hardstatus that
  # does not fit, and eats it from the right: with the session/UTC block on the
  # right, a ten-window list pushed it off an 80-column terminal entirely.
  # Anchoring it left means narrow terminals lose window entries instead.
  #
  # '%n %t' repeats the selected window on purpose: the '%W' list only shows
  # the *other* windows, so without this block a narrow terminal would show a
  # list with no indication of which entry is current. '%W' (not '%-Lw'/'%+Lw')
  # is what keeps the current window out of the list, so it is not printed
  # twice.
  #
  # '%E' is true while the command character has been pressed and screen is
  # waiting for the rest of a command, which is what makes '[CMD]' appear.
  #
  # There is no UTC escape: '%c' is local time, so a backtick runs date(1).
  # The two 60s numbers are the output lifespan and the redraw interval.
  #
  # 'so'/'se' are remapped to italic because screen 4.9 (Debian trixie) has no
  # italic attribute: ansi.c's rendition table maps SGR 3 onto standout, and
  # standout is then emitted with the *outer* terminal's 'smso', which for
  # xterm-256color is '\E[7m'. Italic text therefore came out as reverse video
  # -- grey background, black foreground. Pointing 'so' at '\E[3m' is what makes
  # SGR 3 reach the terminal as italic. Only the outer terminal is affected:
  # SGR 7 (genuine reverse video) still goes through 'mr'.
  #
  # Truecolor is not fixable here. 4.9 stores colour as an 8-bit pair and only
  # parses '38;5;N'; '38;2;r;g;b' matches no case and is dropped, and the
  # 'truecolor' command does not exist before screen 5.0. See the README.
  install_config "$HOME/.screenrc" << 'EOF'
startup_message off
vbell off
defscrollback 10000
altscreen on
defutf8 on
term screen-256color

# no UTC escape in screen; '%c' is local time
backtick 1 60 60 /bin/date -u +%H:%MZ

hardstatus alwayslastline
hardstatus string '%{= kG}[%{G}%H%{g}][%{= rW}%n %t%{= kG}][%{B}%S %{W}UTC %1`%{g}]%?%E%{= rW}[CMD]%{= kG}%:%=%{= kw}[%W]%{k}'

# 'so' is what screen 4.9 emits for SGR 3 (its rendition table maps italic onto
# standout); pointing it at '\E[3m' is what makes italic text actually italic
# instead of reverse video. Genuine reverse video (SGR 7) uses 'mr' and is
# unaffected.
termcapinfo * so=\E[3m:se=\E[23m

# A shell in every window: omp may not be installed (or may be broken), and
# the point is to choose what runs in each window anyway.
#
# The last window created is the one screen selects when you attach, and a
# `select' line in a detached start does not change that. Listing shell first
# is therefore what makes the agent window the one you land in.
screen -t shell 1
screen -t agent 0
EOF
}

component_buildtools() {
  apt_install gcc make pkg-config
}

# Reverse engineering tooling shared by ghidra and rea.
component_re() {
  apt_install binutils binwalk
}

component_rust() {
  apt_install rustup
  run rustup default stable
}

component_dosbox() {
  apt_install dosbox-x
}

component_mise() {
  run_sh 'curl -fsSL https://mise.run/bash | sh'
  # The installer drops the binary in ~/.local/bin and appends its `activate`
  # line to ~/.bashrc, which only helps interactive shells. Put the directory
  # on PATH here rather than sourcing ~/.bashrc: Debian's stock rc opens with
  # `case $- in *i*) ;; *) return;; esac`, and that bare `return` inherits the
  # status of whatever ran before it. Under `set -e` the source then aborts the
  # whole run, which is what used to kill every component after mise.
  path_add "$HOME/.local/bin"
}

# Go comes from mise rather than apt: trixie's golang-go is 1.24, and a project
# whose go.mod says `go 1.27.3` would make every build download a toolchain
# anyway. Pinning the minor line lets the patch float, while a go.mod that
# demands something newer is still handled by GOTOOLCHAIN, which is on by
# default.
component_go() {
  run mise use -g go@1.27
  # mise's shims are not on PATH in this non-interactive shell
  path_add "$HOME/.local/share/mise/shims"
  # `go install` writes here, which is how a Go project's lint tools are
  # normally fetched (errcheck, staticcheck, ...) -- there is no package
  # manager involved.
  # shellcheck disable=SC2016 # literal text for ~/.bashrc, expanded at login
  bashrc_add 'export PATH=$HOME/go/bin:$PATH'
  path_add "$HOME/go/bin"
}

component_node() {
  # mise is on PATH thanks to its own component
  run mise use -g node@lts
  # pnpm is the package manager for the workspaces under ~/src; node bundles
  # corepack for it, but corepack is no longer distributed from Node 25 and is
  # experimental besides. A major pin, like every other mise_global entry.
  run mise use -g pnpm@12
  # mise's shims are not on PATH in this non-interactive shell
  path_add "$HOME/.local/share/mise/shims"
}

# The daemon, the client and the compose plugin are three packages in Debian:
# docker.io (dockerd, containerd, the systemd units), docker-cli (/usr/bin/
# docker) and docker-compose, which installs into
# /usr/libexec/docker/cli-plugins and is therefore what `docker compose`
# resolves. docker-cli is only a Recommends of docker.io, so it is named here
# explicitly.
component_docker() {
  apt_install docker.io docker-cli docker-compose

  # Working through sudo is not the point of a dev VM. docker.io's postinst
  # creates the group; the membership only takes effect in a new login session,
  # so say that instead of letting the next `docker` call fail with a socket
  # permission error.
  local user
  user=$(id -un)
  if ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
    run sudo usermod -aG docker "$user"
    log "note: docker group membership applies from the next login (or: newgrp docker)"
  fi

  # docker.io's postinst starts the daemon through deb-systemd-invoke when
  # systemd is running, which it is on the VM. Enabling it explicitly is what
  # makes a rebuilt box work without a manual `systemctl start`, and the guard
  # is for the CI container, where there is no init to start anything.
  if [[ -d /run/systemd/system ]]; then
    run sudo systemctl enable --now docker
  fi
}

component_omp() {
  run_sh 'curl -fsSL https://omp.sh/install | sh'
  # Literal text for ~/.bashrc: a login shell expands $PATH, not this script.
  # shellcheck disable=SC2016
  bashrc_add 'export PATH=~/.local/bin:$PATH'
  path_add "$HOME/.local/bin"

  local token creds
  secret_value ollama-token token
  ((DRY_RUN)) && return 0

  # The secret is the bare token. `omp auth import` wants a JSON envelope, and
  # pasting that envelope into the secret file would otherwise be accepted
  # silently and stored as the key -- failing later at the first request, far
  # from the mistake. Reject it here, where the file still exists to inspect.
  if [[ $token == \{* ]]; then
    echo "ollama-token looks like an auth export, not a token;" >&2
    echo "put only the literal API key in it (see: omp auth export)" >&2
    exit 3
  fi

  # `omp auth import` takes a versioned envelope, not a bare key=value map, and
  # merges into the store rather than replacing it. The key goes in on stdin: an
  # argument would be visible in /proc/<pid>/cmdline to every user on the box.
  # The envelope is built in python so a key containing a quote or backslash
  # cannot break the JSON.
  creds=$(AGENTVM_TOKEN=$token python3 -c 'import json,os
print(json.dumps({"version":1,"credentials":[{"provider":"ollama-cloud",
  "credential":{"type":"api_key","key":os.environ["AGENTVM_TOKEN"]}}]}))')
  unset token
  log "+ omp auth import -"
  if ((DRY_RUN == 0)); then
    printf '%s' "$creds" | omp auth import -
  fi
  unset creds

  omp_configure
}

# Settings that are normally chosen by hand on first start. `omp config set`
# writes config.yml itself and is idempotent, so this is safe to run on a VM
# that is already configured: the last value wins.
omp_configure() {
  # The composer/status-line/theme keys are plain strings.
  local key
  for key in \
    "symbolPreset $OMP_SYMBOL_PRESET" \
    "composer.shape $OMP_COMPOSER_SHAPE" \
    "theme.dark $OMP_THEME_DARK" \
    "theme.light $OMP_THEME_LIGHT"; do
    # shellcheck disable=SC2086 # split into key and value
    run omp config set $key
  done

  # modelRoles is a record, so it cannot be set key-by-key ("Unknown setting:
  # modelRoles.default"). Merge to keep the other roles (smol, slow, plan) that
  # the operator or a previous run may have pinned.
  local current merged
  current=$(omp config get modelRoles --json 2> /dev/null |
    python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["value"]))' 2> /dev/null) ||
    current='{}'
  merged=$(
    python3 - "$current" "$OMP_MODEL" << 'PY'
import json, sys
roles = json.loads(sys.argv[1] or '{}')
roles['default'] = sys.argv[2]
print(json.dumps(roles))
PY
  )
  run omp config set modelRoles "$merged"
}

component_ntfy() {
  # https://github.com/hakkm/omp-ntfy
  #
  # The settings go in the plugin's config file, not just ~/.bashrc. omp-ntfy
  # resolves its config as `{...env defaults, ...saved}` -- the file wins over
  # NTFY_TOPIC/NTFY_SERVER, and the plugin writes that file with a *random*
  # topic and https://ntfy.sh the first time it runs without one. So exporting
  # the variables only worked for a login shell whose first /ntfy had not
  # happened yet; after that the file shadowed them, and a non-interactive omp
  # (which never reads ~/.bashrc) fell back to a generated topic entirely.
  # Seeding the file is what makes the setting authoritative and independent of
  # how omp was started. The file is not something to edit by hand: the plugin
  # owns it and /ntfy topic rewrites it with the operator's choice, which this
  # correctly leaves alone only if they agree -- a re-run restores these values,
  # so an operator wanting different ones sets AGENTVM_NTFY_TOPIC/SERVER.
  install_config "$HOME/.omp/agent/omp-ntfy.json" << EOF
{
  "topic": "$NTFY_TOPIC",
  "server": "$NTFY_SERVER",
  "maxTextLength": 350
}
EOF

  # Still exported: the plugin reads NTFY_TOPIC/NTFY_SERVER as its defaults, so
  # a shell started after this run works even before the file is read.
  bashrc_add "export NTFY_SERVER=$NTFY_SERVER"
  bashrc_add "export NTFY_TOPIC=$NTFY_TOPIC"
  run omp install npm:omp-ntfy
}

component_rea() {
  run npx rea-agents setup
}

# Keep a checkout of this repo in the guest, so a component that shipped after
# this VM was built can still be applied without re-provisioning.
#
# It is in use_standard, so every VM ends up with the checkout that makes
# `git pull` + `--only <new component>` possible. Cloning only needs the git
# *package*, not the `git` component: that one also consumes the identity and
# token secrets, and requiring a token just to fetch a public repo would make a
# targeted apply unusable on a VM that was never provisioned. Hence the apt
# call here rather than a DEPENDS edge.
component_agentvm() {
  local dir=$AGENTVM_DIR link=$AGENTVM_LINK

  command -v git > /dev/null || apt_install git

  if [[ -d $dir/.git ]]; then
    # An existing checkout is the operator's: update it, never delete and
    # re-clone over local changes.
    run git -C "$dir" pull --ff-only
  elif [[ -d $dir ]] && [[ -n $(ls -A "$dir") ]]; then
    # Something is there but it is not a checkout. Deleting it would throw away
    # whatever the operator left there, so stop and say what to do.
    echo "$dir exists but is not a git checkout; move it aside or set AGENTVM_DIR" >&2
    exit 1
  else
    run git clone "$AGENTVM_REPO" "$dir"
  fi

  # ~/.local/bin is already on PATH (component_omp and component_mise put it
  # there, and ~/.bashrc exports it), so this is the whole point: `agentvm`
  # works from anywhere without knowing the checkout path.
  if [[ -L $link ]] && [[ $(readlink "$link") == "$dir/agentvm.bash" ]]; then
    return 0
  fi
  log "+ $link -> $dir/agentvm.bash"
  ((DRY_RUN)) && return 0
  mkdir -p "$(dirname "$link")"
  # Replace a stale link, but do not clobber a real file someone put there.
  if [[ -e $link ]] && [[ ! -L $link ]]; then
    echo "$link exists and is not a symlink; move it aside or set AGENTVM_LINK" >&2
    exit 1
  fi
  ln -sfn "$dir/agentvm.bash" "$link"
}

# Clone the repositories a project declared with `repo` into ~/src.
component_repos() {
  local spec url name dir

  # git comes from DEPENDS via `repo`, but a targeted `--only repos` on a VM
  # that never ran the git component still needs the binary. Same trade as
  # component_agentvm: the package, not the component, because the component
  # also consumes the identity and token secrets.
  command -v git > /dev/null || apt_install git
  run mkdir -p "$HOME/src"

  for spec in "${REPOS[@]}"; do
    case $spec in
      # anything with a scheme or a scp-style host is a URL already
      *://* | *@*:*) url=$spec ;;
      # owner/name is the common case for GitHub, so make it the shorthand
      *) url="https://github.com/$spec.git" ;;
    esac

    # Owner/name.git -> name. Also copes with a trailing slash or a bare
    # https URL without the .git suffix.
    name=${url%/}
    name=${name##*/}
    name=${name%.git}

    dir=$HOME/src/$name

    if [[ -d $dir/.git ]]; then
      # Existing checkout: update --ff-only so a local branch
      # the operator is working on isn't merged or rebased under them.
      run git -C "$dir" pull --ff-only
      # A VM built before a submodule was added has an empty submodule
      # directory, and `pull` does not fill it in.
      run git -C "$dir" submodule update --init --recursive
    elif [[ -d $dir ]] && [[ -n $(ls -A "$dir") ]]; then
      echo "$dir exists but is not a git checkout; move it aside to re-clone" >&2
      exit 1
    else
      run git clone --recurse-submodules "$url" "$dir"
    fi
  done
}

# Re-point an existing checkout at the tip of the branch. `--update` is for the
# case where the VM was built from an older revision and you want the script
# that is on disk to be the current one, without re-running a component.
update_agentvm() {
  local dir=$AGENTVM_DIR before after

  if [[ ! -d $dir/.git ]]; then
    echo "no checkout at $dir; run: agentvm --only agentvm" >&2
    exit 1
  fi

  before=$(git -C "$dir" rev-parse HEAD 2> /dev/null || true)
  run git -C "$dir" pull --ff-only
  after=$(git -C "$dir" rev-parse HEAD 2> /dev/null || true)

  # The running copy is this file, which the pull just changed underneath us.
  # Say so only when it actually moved, so a no-op `--update` stays quiet.
  if [[ $before != "$after" ]] && ((DRY_RUN == 0)) &&
    [[ $(readlink -f "$0") == "$(readlink -f "$dir/agentvm.bash")" ]]; then
    log "note: $dir/agentvm.bash moved to $after; the new version runs next time" >&2
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

resolved() {
  local c
  for c in "${COMPONENTS[@]}"; do
    if [[ -n ${WANTED[$c]:-} ]]; then
      echo "$c"
    fi
  done
}

# Every required secret must be on disk before anything is installed.
preflight_secrets() {
  if ((${#REQUIRED_SECRETS[@]} == 0)); then
    return 0
  fi
  local s missing=()
  for s in "${REQUIRED_SECRETS[@]}"; do
    [[ -f $SECRET_DIR/$s ]] || missing+=("$s")
  done
  if ((${#missing[@]})); then
    echo "missing required secrets: ${missing[*]}" >&2
    if [[ $PROJECT == '(only)' ]]; then
      echo "re-run vm-provision for this host" >&2
    else
      echo "re-run vm-provision for $PROJECT" >&2
    fi
    exit 3
  fi
}

# Report anything left behind, then remove the directory. vm-provision pushes a
# fixed set, so leftovers are expected; they are only warned about.
sweep_secrets() {
  if [[ ! -d $SECRET_DIR ]]; then
    return 0
  fi
  local f n leftover=()
  for f in "$SECRET_DIR"/*; do
    [[ -e $f ]] || continue
    n=${f##*/}
    [[ " ${CONSUMED_SECRETS[*]} " == *" $n "* ]] && continue
    if [[ -z ${SECRET_DEST[$n]+set} ]]; then
      leftover+=("$n (unknown)")
    else
      leftover+=("$n")
    fi
  done
  if ((${#leftover[@]})); then
    log "warning: unused secrets removed: ${leftover[*]}" >&2
  fi
  if ((DRY_RUN)); then
    log "would remove $SECRET_DIR"
    return 0
  fi
  rm -rf "$SECRET_DIR"
}

main() {
  local c order=() only=() list=0

  while (($#)); do
    case $1 in
      --list)
        list=1
        shift
        ;;
      --only)
        shift
        # take everything up to the next flag, so `--only a b` works too
        while (($#)) && [[ $1 != --* ]]; do
          only+=("$1")
          shift
        done
        ;;
      --only=*)
        IFS=, read -r -a _names <<< "${1#*=}"
        only+=("${_names[@]}")
        shift
        ;;
      --update)
        # Handled before anything else and exits: it changes the script on
        # disk, and everything below is about what that script should apply.
        update_agentvm
        return 0
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  # `--only a,b`, `--only a b` and `--only=a,b` all mean the same thing.
  if ((${#only[@]})); then
    local -a split=() parts=()
    local name
    for name in "${only[@]}"; do
      IFS=, read -r -a parts <<< "$name"
      split+=("${parts[@]}")
    done
    only=()
    for name in "${split[@]}"; do
      [[ -n $name ]] && only+=("$name")
    done
  fi

  if ((${#only[@]})); then
    # A targeted apply ignores the project, but not the dependency graph: the
    # point is to get one component and everything it needs, not to reimplement
    # DEPENDS by hand.
    use "${only[@]}"
    PROJECT='(only)'
  else
    # A project is picked from the hostname; `--only` is what makes a run work
    # on a host that does not follow the convention.
    if [[ -z ${AGENTVM_PROJECT:-} && $HOST != omp-* ]]; then
      echo "hostname '$HOST' is not omp-PROJECT; set AGENTVM_PROJECT or use --only" >&2
      exit 2
    fi
    PROJECT=${AGENTVM_PROJECT:-${HOST#omp-}}
    local fn=project_$PROJECT
    if ! declare -F "$fn" > /dev/null; then
      echo "no definition for project '$PROJECT', using project_default" >&2
      fn=project_default
    fi
    # project bodies declare with `use`, whose dependencies land in WANTED only
    "$fn"
  fi

  # array, not `while read`: components may prompt on stdin
  mapfile -t order < <(resolved)
  resolve_secrets

  if ((list)); then
    if [[ $PROJECT == '(only)' ]]; then
      echo "components: ${only[*]}"
    else
      echo "project: $PROJECT"
    fi
    for c in "${order[@]}"; do
      if [[ -n ${DECLARED[$c]:-} ]]; then
        echo "$c"
      else
        echo "  $c (dependency)"
      fi
    done
    if ((${#EXTRA_PKGS[@]})); then
      echo "extra packages: ${EXTRA_PKGS[*]}"
    fi
    if ((${#NPM_GLOBAL[@]})); then
      echo "npm packages: ${NPM_GLOBAL[*]}"
    fi
    if ((${#MISE_GLOBAL[@]})); then
      echo "mise tools: ${MISE_GLOBAL[*]}"
    fi
    if ((${#REPOS[@]})); then
      echo "repos: ${REPOS[*]}"
    fi
    if ((${#REQUIRED_SECRETS[@]})); then
      echo "secrets: ${REQUIRED_SECRETS[*]}"
    fi
    return 0
  fi

  preflight_secrets

  if [[ $PROJECT == '(only)' ]]; then
    log "components: ${order[*]}"
  else
    log "project $PROJECT: ${order[*]}"
  fi
  for c in "${order[@]}"; do
    "component_$c"
  done

  # npm_global packages come last: npm only exists once component_node has run,
  # and mise's shims (where the binaries land) only exist after that too.
  if ((${#NPM_GLOBAL[@]})); then
    run npm install -g "${NPM_GLOBAL[@]}"
  fi

  # mise_global tools likewise: component_mise is what puts mise on PATH and
  # puts its shims directory, where these binaries land, on PATH.
  if ((${#MISE_GLOBAL[@]})); then
    run mise use -g "${MISE_GLOBAL[@]}"
  fi

  if ((${#EXTRA_PKGS[@]})); then
    apt_install "${EXTRA_PKGS[@]}"
  fi

  # Only sweep when this run was provisioned for. A targeted apply of a
  # component that needs no secret must not delete secrets left behind by an
  # earlier run that failed before consuming them (or pushed by an operator
  # who never ran anything else).
  if [[ -d $SECRET_DIR ]] && ((${#CONSUMED_SECRETS[@]})); then
    sweep_secrets
  fi

  # A run is mostly apt/get output, so success looks like whatever the last
  # installer happened to print. Say it explicitly, and say it on stdout: a
  # human and a wrapper script both want to see it. `DRY_RUN` gets its own
  # wording so a rehearsal is never mistaken for a provisioned VM.
  local summary
  if [[ $PROJECT == '(only)' ]]; then
    summary="applied ${#order[@]} component(s): ${order[*]}"
  else
    summary="provisioned project $PROJECT: ${#order[@]} component(s)"
  fi
  if ((DRY_RUN)); then
    log "dry run complete, nothing was changed: $summary"
  else
    log "done: $summary"
  fi
}

# Sourcing this file defines the components without running anything, which is
# what the bats suites under tests/ do. Only execute when invoked as a script.
#
# The obvious guard, `[[ ${BASH_SOURCE[0]} == "$0" ]]`, fails the other way
# round: under the documented `bash -c "$(curl ...)"` install, BASH_SOURCE is
# *unset*, which `set -u` turns into an immediate abort, and `$0` is just
# `bash`, so the comparison would skip main even without `set -u`. A piped
# `curl ... | bash` is worse still: BASH_SOURCE[0] becomes a synthetic `main`.
#
# `return` succeeds only when the file is being sourced, so the subshell is the
# test: it runs this line in a copy of the current context and the file is
# executed rather than sourced in every other case (plain run, symlink such as
# ~/.local/bin/agentvm, `bash -c "$(curl ...)"`, `curl ... | bash`). The
# subshell keeps the non-source `return` from reaching the caller, which under
# `set -e` would abort a sourcing shell, and keeps shellcheck from reading main
# as unreachable. `2> /dev/null` swallows "can only `return' from a function or
# sourced script" for the executed case.
if ! (return 0 2> /dev/null); then
  main "$@"
fi
