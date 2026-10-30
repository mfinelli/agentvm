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
# AGENTVM_DRY_RUN=1 prints what would happen without touching the system.
# `--list` prints the components a project would run, marking ones that were
# only pulled in as dependencies.

GHIDRA_BASE=https://github.com/NationalSecurityAgency/ghidra/releases/download
GHIDRA_VERSION=Ghidra_12.2_build/ghidra_12.2_PUBLIC_20261016
GHIDRA_INSTALL_STR=ghidra_12.2_PUBLIC
NERDFONTS_BASE=https://github.com/ryanoasis/nerd-fonts/releases/download
NERDFONTS_VERSION=3.5.1

COMPONENTS=(
  base
  editor
  git
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

# DEPENDS[c] is the space separated list of components c requires. `use`
# pulls these in transitively, and COMPONENTS already runs them first, so
# declaring an edge never changes execution order.
declare -A DEPENDS=(
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

# ---------------------------------------------------------------------------
# project definitions: what a given `omp-PROJECT` box needs
#
# Each project lists everything it wants, spelled out in full. A project may
# also call another project's function, but keeping the lists explicit means
# a project can be read top to bottom without chasing other definitions.
# Order here does not matter: COMPONENTS decides execution order.
# ---------------------------------------------------------------------------

project_agentvm() {
  use base editor git fonts mise omp ntfy
}

project_opentower() {
  use base editor git fonts mise omp ntfy
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

  local git_name git_email
  (( DRY_RUN )) && return 0
  read -r -p "Enter your Git name: " git_name
  read -r -p "Enter your Git email: " git_email

  if [[ -z "$git_name" || -z "$git_email" ]]; then
    echo "Name and email can't be empty." >&2
    exit 1
  fi

  run git config --global user.name "$git_name"
  run git config --global user.email "$git_email"
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
    return 0
  fi

  log "project $PROJECT: ${order[*]}"
  sudo_v
  for c in "${order[@]}"; do
    component_$c
  done

  if (( ${#EXTRA_PKGS[@]} )); then
    apt_install "${EXTRA_PKGS[@]}"
  fi
}

main "$@"

exit 0
