#!/usr/bin/env bash

set -euo pipefail;

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
#   promote it to a component once a second project needs it.
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

GHIDRA_BASE=https://github.com/NationalSecurityAgency/ghidra/releases/download
GHIDRA_VERSION=Ghidra_12.2_build/ghidra_12.2_PUBLIC_20261016
GHIDRA_INSTALL_STR=ghidra_12.2_PUBLIC
NERDFONTS_BASE=https://github.com/ryanoasis/nerd-fonts/releases/download
NERDFONTS_VERSION=3.5.1
BASH_IT_REPO=https://github.com/Bash-it/bash-it

COMPONENTS=(
  base
  editor
  git
  bash
  fonts
  java
  ghidra
  buildtools
  re
  rust
  dosbox
  mise
  node
  omp
  ntfy
  rea
)

declare -A KNOWN=() WANTED=() DECLARED=()
# packages a single project needs that are not worth their own component
EXTRA_PKGS=()

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
  [git-name]=""
  [git-email]=""
  # Tokens are installed per host under ~/.config/git/tokens/<host>, so a
  # second provider (gitlab, ...) gets its own file. The host is part of the
  # path, so the credential helper can be scoped to exactly that host.
  [github-token]="$HOME/.config/git/tokens/github.com"
)

declare -A SECRET_USERS=(
  [git-name]='git'
  [git-email]='git'
  [github-token]='git'
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
    if (( POS[$d] > POS[$c] )); then
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
  use base editor git bash fonts mise omp ntfy
}

project_agentvm() {
  use_standard
}

project_opentower() {
  use_standard
  use buildtools rust
  use ghidra dosbox rea
  apt_extra libasound2-dev
}

# Anything unrecognised gets everything.
project_default() {
  use "${COMPONENTS[@]}"
}

# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

HOST=${HOSTNAME%%.*}
if [[ -z ${AGENTVM_PROJECT:-} && $HOST != omp-* ]]; then
  echo "hostname '$HOST' is not omp-PROJECT; set AGENTVM_PROJECT" >&2
  exit 2
fi
PROJECT=${AGENTVM_PROJECT:-${HOST#omp-}}
DRY_RUN=${AGENTVM_DRY_RUN:-0}

log() { printf '\n==> %s\n' "$*"; }
run() {
  log "+ $*"
  (( DRY_RUN )) || "$@"
}
# for `curl | sh` installers, which are fine here: this is a throwaway VM
run_sh() {
  log "+ sh -c '$1'"
  (( DRY_RUN )) || bash -c "$1"
}
sudo_v() {
  (( DRY_RUN )) || sudo -v
}
apt_install() {
  run sudo apt-get install -y "$@"
}
# append a line to ~/.bashrc once, so re-running the script stays clean
bashrc_add() {
  local line=$1
  if grep -qxF -- "$line" "$HOME/.bashrc" 2>/dev/null; then
    return 0
  fi
  log "+ ~/.bashrc += $line"
  (( DRY_RUN )) || printf '%s\n' "$line" >> "$HOME/.bashrc"
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
  if (( DRY_RUN )); then
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
  CONSUMED_SECRETS+=("$s")
  if (( DRY_RUN )); then
    log "would consume secret $s" >&2
    return 0
  fi
  local -n out=$var
  out=$(<"$SECRET_DIR/$s")
  rm -f "$SECRET_DIR/$s"
  log "consumed secret $s" >&2
}

# ---------------------------------------------------------------------------
# components
# ---------------------------------------------------------------------------

component_base() {
  apt_install curl wget
  apt_install htop bat
  apt_install python3 python3-pip
  apt_install magic-wormhole
  apt_install imagemagick
  apt_install 7zip libarchive-tools unzip
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
  token=${SECRET_DEST[github-token]}
  take_secret github-token
  (( DRY_RUN )) && return 0

  if [[ -z $git_name || -z $git_email ]]; then
    echo "git-name and git-email secrets are empty" >&2
    exit 3
  fi

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
  bashrc_add "export BASH_IT_THEME='barbuk'"
  bashrc_add "export BASH_IT_PROJECT_PATHS=\"$HOME/src\""
  bashrc_add 'export BASH_IT_COMMAND_DURATION=true'
  bashrc_add 'export COMMAND_DURATION_MIN_SECONDS=1'
  # last, so every setting above is in scope when bash-it loads
  bashrc_add "source \"\${BASH_IT?}/bash_it.sh\""
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
  # Debian's stock ~/.bashrc returns early for non-interactive shells, so this
  # source is usually a no-op; put the install dir on PATH explicitly.
  (( DRY_RUN )) || source "$HOME/.bashrc"
  export PATH="$HOME/.local/bin:$PATH"
}

component_node() {
  # mise is on PATH thanks to its own component
  run mise use -g node@lts
  # mise's shims are not on PATH in this non-interactive shell
  if ! (( DRY_RUN )); then
    export PATH="$HOME/.local/share/mise/shims:$PATH"
  fi
}

component_omp() {
  run_sh 'curl -fsSL https://omp.sh/install | sh'
  bashrc_add 'export PATH=~/.local/bin:$PATH'
  export PATH="$HOME/.local/bin:$PATH"
}

component_ntfy() {
  # https://github.com/hakkm/omp-ntfy
  bashrc_add 'export NTFY_SERVER=http://192.168.123.1:8081'
  bashrc_add 'export NTFY_TOPIC=omp'
  run omp install npm:omp-ntfy
}

component_rea() {
  run npx rea-agents setup
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
  if (( ! ${#REQUIRED_SECRETS[@]} )); then
    return 0
  fi
  local s missing=()
  for s in "${REQUIRED_SECRETS[@]}"; do
    [[ -f $SECRET_DIR/$s ]] || missing+=("$s")
  done
  if (( ${#missing[@]} )); then
    echo "missing required secrets: ${missing[*]}" >&2
    echo "re-run vm-provision for $PROJECT" >&2
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
  if (( ${#leftover[@]} )); then
    log "warning: unused secrets removed: ${leftover[*]}" >&2
  fi
  if (( DRY_RUN )); then
    log "would remove $SECRET_DIR"
    return 0
  fi
  rm -rf "$SECRET_DIR"
}

main() {
  local fn=project_$PROJECT c order=()

  if ! declare -F "$fn" > /dev/null; then
    echo "no definition for project '$PROJECT', using project_default" >&2
    fn=project_default
  fi
  # project bodies declare with `use`, whose dependencies land in WANTED only
  "$fn"

  # array, not `while read`: components may prompt on stdin
  mapfile -t order < <(resolved)
  resolve_secrets

  if [[ ${1:-} == --list ]]; then
    echo "project: $PROJECT"
    for c in "${order[@]}"; do
      if [[ -n ${DECLARED[$c]:-} ]]; then
        echo "$c"
      else
        echo "  $c (dependency)"
      fi
    done
    if (( ${#EXTRA_PKGS[@]} )); then
      echo "extra packages: ${EXTRA_PKGS[*]}"
    fi
    if (( ${#REQUIRED_SECRETS[@]} )); then
      echo "secrets: ${REQUIRED_SECRETS[*]}"
    fi
    return 0
  fi

  preflight_secrets

  log "project $PROJECT: ${order[*]}"
  sudo_v
  for c in "${order[@]}"; do
    component_$c
  done

  if (( ${#EXTRA_PKGS[@]} )); then
    apt_install "${EXTRA_PKGS[@]}"
  fi

  sweep_secrets
}

main "$@"

exit 0
