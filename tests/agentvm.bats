#!/usr/bin/env bats
#
# Unit tests for the pure parts of agentvm.bash: argument handling, the
# dependency graph, secret lifecycle and URL normalisation.
#
# The end-to-end behaviour lives in the `integration` CI job, which runs the
# whole script in a trixie container. Do not add component tests here that
# install things -- they belong there.
#
# Two bats specifics drive the shape of every file here:
#
#   1. `load` sources the script *inside a function*, so its `declare -A` at top
#      level become function-local and vanish. That is why the maps are
#      re-declared with `declare -gA` in setup() rather than reused.
#   2. The script defines its own `run`, which would shadow bats' `run`. It is
#      saved before the load and put back after, so `run` still captures status
#      and output.

# bats runs every test in a subshell, so shellcheck's subshell warnings are all
# noise here (SC2030/SC2031), and the arrays below are filled by the sourced
# code rather than in the file shellcheck can see (SC2034).
# shellcheck disable=SC2030,SC2031,SC2034,SC2154

bats_require_minimum_version 1.5.0

__bats_run=$(declare -f run)
load ../agentvm.bash
# The script defines its own `run`. Keep a copy under a distinct name so tests
# can exercise it directly, then put bats' `run` back: wrapping the script's
# helper in bats' `run` does not work, because the inner call re-resolves `run`
# inside the subshell and finds bats' version again.
eval "$(declare -f run | sed '1s/^run/agentvm_run/')"
unset -f run
eval "$__bats_run"
unset __bats_run

setup() {
  # The script sets -euo at the top; unterminated tests would otherwise abort
  # on the first non-zero status.
  set +eu

  # These are mutated by the sourced functions under test.
  declare -gA KNOWN=() WANTED=() DECLARED=()
  declare -gA DEPENDS=()
  declare -gA SECRET_DEST=() SECRET_USERS=()
  declare -ga COMPONENTS=() REQUIRED_SECRETS=() CONSUMED_SECRETS=()
  declare -ga EXTRA_PKGS=() NPM_GLOBAL=() MISE_GLOBAL=() REPOS=()

  DRY_RUN=0
  SECRET_DIR="$BATS_TEST_TMPDIR/secrets"
  mkdir -p "$SECRET_DIR"
}

# ---------------------------------------------------------------- dependencies

# A three level chain, plus a diamond, so `_want` has something to walk.
seed_depends() {
  COMPONENTS=(a b c d)
  KNOWN=([a]=1 [b]=1 [c]=1 [d]=1)
  DEPENDS=([b]='a' [c]='b')
}

@test "_want pulls in transitive dependencies" {
  set -e
  seed_depends
  _want c
  [ -n "${WANTED[c]:-}" ]
  [ -n "${WANTED[b]:-}" ]
  [ -n "${WANTED[a]:-}" ]
  [ -z "${WANTED[d]:-}" ]
}

@test "_want rejects an unknown component with exit 2" {
  set -e
  COMPONENTS=(a)
  KNOWN=([a]=1)
  run _want nope
  [ "$status" -eq 2 ]
  [[ $output == *"unknown component: nope"* ]]
}

@test "_want is idempotent for a diamond dependency" {
  set -e
  COMPONENTS=(a b c)
  KNOWN=([a]=1 [b]=1 [c]=1)
  # both b and c depend on a; a must still be wanted exactly once
  DEPENDS=([b]='a' [c]='a')
  _want b
  _want c
  [ -n "${WANTED[a]:-}" ]
  # a dependency of a dependency is not re-resolved: no infinite loop and no
  # duplicate entries if the graph repeats itself
  ((WANTED[a] == 1))
}

@test "resolved emits components in COMPONENTS order, not declaration order" {
  set -e
  COMPONENTS=(a b c)
  KNOWN=([a]=1 [b]=1 [c]=1)
  WANTED=([c]=1 [a]=1)
  run resolved
  [ "$output" = "$(printf 'a\nc')" ]
}

@test "resolved emits nothing when nothing is wanted" {
  set -e
  COMPONENTS=(a b)
  KNOWN=([a]=1 [b]=1)
  run resolved
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --------------------------------------------------------------------- secrets

@test "_secret_check rejects a name with no SECRET_DEST entry" {
  set -e
  declare -gA SECRET_DEST=(["known"]="")
  run _secret_check unknown
  [ "$status" -eq 2 ]
  [[ $output == *"unknown secret: unknown"* ]]
}

@test "_secret_check reports a missing file with exit 3" {
  set -e
  declare -gA SECRET_DEST=(["value-key"]="")
  run _secret_check value-key
  [ "$status" -eq 3 ]
  [[ $output == *"missing secret: value-key"* ]]
}

@test "_secret_check accepts a file that exists" {
  set -e
  declare -gA SECRET_DEST=(["value-key"]="")
  printf 'x\n' > "$SECRET_DIR/value-key"
  run _secret_check value-key
  [ "$status" -eq 0 ]
}

@test "secret_value stores the trimmed value and deletes the file" {
  set -e
  declare -gA SECRET_DEST=(["value-key"]="")
  printf 'sekret\n' > "$SECRET_DIR/value-key"
  secret_value value-key out
  # $(< file) strips the trailing newline, which is what lets both
  # `echo KEY > f` and `printf KEY > f` work. $out is assigned by
  # secret_value through a nameref, which shellcheck cannot follow.
  [ "$out" = sekret ]
  [ ! -f "$SECRET_DIR/value-key" ]
  [ "${CONSUMED_SECRETS[*]}" = value-key ]
}

@test "secret_value refuses a secret that has a file destination" {
  set -e
  declare -gA SECRET_DEST=(["github-token"]="$BATS_TEST_TMPDIR/out")
  printf 'tok\n' > "$SECRET_DIR/github-token"
  run secret_value github-token out
  [ "$status" -eq 2 ]
  [[ $output == *"has a destination"* ]]
}

@test "secret_value rejects an empty secret before deleting it" {
  set -e
  declare -gA SECRET_DEST=(["value-key"]="")
  : > "$SECRET_DIR/value-key"
  run secret_value value-key out
  [ "$status" -eq 3 ]
  [[ $output == *"is empty"* ]]
  # the evidence must survive so a retry reports the same error
  [ -f "$SECRET_DIR/value-key" ]
}

@test "take_secret installs the file 0600 and deletes the original" {
  set -e
  declare -gA SECRET_DEST=(["github-token"]="$BATS_TEST_TMPDIR/tokens/github.com")
  printf 'tok\n' > "$SECRET_DIR/github-token"
  take_secret github-token
  [ -f "$BATS_TEST_TMPDIR/tokens/github.com" ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/tokens/github.com")" = 600 ]
  [ ! -f "$SECRET_DIR/github-token" ]
  [ "${CONSUMED_SECRETS[*]}" = github-token ]
}

@test "take_secret refuses a value-only secret" {
  set -e
  declare -gA SECRET_DEST=(["value-key"]="")
  printf 'x\n' > "$SECRET_DIR/value-key"
  run take_secret value-key
  [ "$status" -eq 2 ]
  [[ $output == *"has no destination"* ]]
}

@test "resolve_secrets requires only secrets whose consumer is selected" {
  set -e
  declare -gA SECRET_USERS=([git-name]='git' [ollama-token]='omp')
  declare -gA WANTED=([git]=1)
  resolve_secrets
  [ "${REQUIRED_SECRETS[*]}" = git-name ]
}

@test "resolve_secrets requires nothing when no consumer is selected" {
  set -e
  declare -gA SECRET_USERS=([git-name]='git')
  resolve_secrets
  [ "${#REQUIRED_SECRETS[@]}" -eq 0 ]
}

# ----------------------------------------------------------------- the dry run

@test "run does not execute when DRY_RUN is set" {
  set -e
  DRY_RUN=1
  agentvm_run touch "$BATS_TEST_TMPDIR/should-not-exist"
  [ ! -e "$BATS_TEST_TMPDIR/should-not-exist" ]
}

@test "run executes and reports the command when not dry" {
  set -e
  DRY_RUN=0
  agentvm_run touch "$BATS_TEST_TMPDIR/created"
  [ -e "$BATS_TEST_TMPDIR/created" ]
}

@test "run prints the command it would run" {
  set -e
  DRY_RUN=0
  run agentvm_run echo hello
  [[ $output == *"+ echo hello"* ]]
}

# ------------------------------------------------------------ config install

@test "install_config writes the file once and is idempotent" {
  set -e
  local dest="$BATS_TEST_TMPDIR/rc"
  printf 'line\n' | install_config "$dest"
  [ "$(cat "$dest")" = line ]

  # a second identical write must not touch the file: capture the inode and
  # mtime, since rewriting an unchanged dotfile is the bug this guards
  local before
  before=$(stat -c '%i %Y' "$dest")
  sleep 1
  printf 'line\n' | install_config "$dest"
  [ "$(stat -c '%i %Y' "$dest")" = "$before" ]
}

@test "install_config replaces content that differs" {
  set -e
  local dest="$BATS_TEST_TMPDIR/rc"
  printf 'old\n' | install_config "$dest"
  printf 'new\n' | install_config "$dest"
  [ "$(cat "$dest")" = new ]
}

@test "install_config creates missing parent directories" {
  set -e
  local dest="$BATS_TEST_TMPDIR/a/b/rc"
  printf 'x\n' | install_config "$dest"
  [ -f "$dest" ]
}

@test "install_config writes nothing in a dry run" {
  set -e
  DRY_RUN=1
  local dest="$BATS_TEST_TMPDIR/rc"
  printf 'x\n' | install_config "$dest"
  [ ! -e "$dest" ]
}

@test "bashrc_add appends a line once" {
  set -e
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  bashrc_add 'export FOO=1'
  bashrc_add 'export FOO=1'
  [ "$(grep -c 'export FOO=1' "$HOME/.bashrc")" -eq 1 ]
}

# ----------------------------------------------------------------- repositories

@test "repo records specs and selects the component and git" {
  set -e
  COMPONENTS=(git repos)
  KNOWN=([git]=1 [repos]=1)
  repo mfinelli/agentvm mfinelli/dotfiles
  [ "${REPOS[*]}" = "mfinelli/agentvm mfinelli/dotfiles" ]
  [ -n "${WANTED[repos]:-}" ]
  [ -n "${WANTED[git]:-}" ]
}

@test "repo accepts several specs on one line" {
  set -e
  COMPONENTS=(git repos)
  KNOWN=([git]=1 [repos]=1)
  repo a/b
  repo c/d
  [ "${#REPOS[@]}" -eq 2 ]
}

# component_repos is driven with a stub git so the URL and directory rules can be
# checked without cloning anything.
stub_git() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/git" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_LOG"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  : > "$GIT_LOG"
}

# component_ntfy's only external step is `omp install`, so the binary is stubbed
# the same way as git. A shell function would work too, but shellcheck sees a
# function defined here and never called (the component lives in the sourced
# script) as dead code -- SC2317 before 0.11, SC2329 after -- so a fake binary
# keeps the suite clean on any shellcheck version.
stub_omp() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/omp" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OMP_LOG"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/omp"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export OMP_LOG="$BATS_TEST_TMPDIR/omp.log"
  : > "$OMP_LOG"
}

@test "component_repos expands owner/name to a github https url" {
  set -e
  stub_git
  export HOME="$BATS_TEST_TMPDIR/home"
  declare -ga REPOS=(mfinelli/agentvm)
  component_repos
  [[ $(cat "$GIT_LOG") == *"clone --recurse-submodules https://github.com/mfinelli/agentvm.git $HOME/src/agentvm"* ]]
}

@test "component_repos keeps an explicit https url and derives the name" {
  set -e
  stub_git
  export HOME="$BATS_TEST_TMPDIR/home"
  declare -ga REPOS=(https://gitlab.com/g/sub/thing.git)
  component_repos
  [[ $(cat "$GIT_LOG") == *"clone --recurse-submodules https://gitlab.com/g/sub/thing.git $HOME/src/thing"* ]]
}

@test "component_repos keeps an ssh url" {
  set -e
  stub_git
  export HOME="$BATS_TEST_TMPDIR/home"
  declare -ga REPOS=('git@github.com:o/r.git')
  component_repos
  [[ $(cat "$GIT_LOG") == *'clone --recurse-submodules git@github.com:o/r.git'* ]]
  [[ $(cat "$GIT_LOG") == *"$HOME/src/r"* ]]
}

@test "component_repos pulls an existing checkout instead of cloning" {
  set -e
  stub_git
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/src/agentvm/.git"
  declare -ga REPOS=(mfinelli/agentvm)
  component_repos
  [[ $(cat "$GIT_LOG") == *"pull --ff-only"* ]]
  [[ $(cat "$GIT_LOG") != *clone* ]]
  # a checkout made before a submodule existed has it empty, and pull does not
  # fill it in
  [[ $(cat "$GIT_LOG") == *"submodule update --init --recursive"* ]]
}

@test "component_repos refuses to clobber a directory that is not a checkout" {
  set -e
  stub_git
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/src/agentvm"
  printf 'work\n' > "$HOME/src/agentvm/file"
  declare -ga REPOS=(mfinelli/agentvm)
  run component_repos
  [ "$status" -eq 1 ]
  [[ $output == *"is not a git checkout"* ]]
  # the operator's file must still be there
  [ -f "$HOME/src/agentvm/file" ]
}

@test "component_repos clones nothing when no repo is declared" {
  set -e
  stub_git
  export HOME="$BATS_TEST_TMPDIR/home"
  declare -ga REPOS=()
  component_repos
  [ ! -s "$GIT_LOG" ]
}

# ----------------------------------------------------------- invocation modes

# The file is both a script and a library: bats `load`s it, provisioning runs it
# as `bash -c "$(curl ...)"`, and ~/.local/bin/agentvm is a symlink to it. The
# guard at the bottom has to tell those apart without reading BASH_SOURCE, which
# is unset under `bash -c` (a `set -u` abort) and a synthetic `main` when piped.
# `--list` is the probe: it needs no secrets and touches nothing.
@test "the script runs main when executed, symlinked, piped and via bash -c" {
  set -e
  local script="$BATS_TEST_DIRNAME/../agentvm.bash"
  ln -sfn "$script" "$BATS_TEST_TMPDIR/agentvm"

  run env AGENTVM_PROJECT=default bash "$script" --list
  [ "$status" -eq 0 ]
  [[ $output == *"project: default"* ]]

  # ~/.local/bin/agentvm is exactly this case
  run env AGENTVM_PROJECT=default "$BATS_TEST_TMPDIR/agentvm" --list
  [ "$status" -eq 0 ]
  [[ $output == *"project: default"* ]]

  # the documented install: bash -c "$(curl -fsSL https://mfgo.link/agentvm)"
  run env AGENTVM_PROJECT=default bash -c "$(cat "$script")" agentvm --list
  [ "$status" -eq 0 ]
  [[ $output == *"project: default"* ]]

  # and the piped variant, where BASH_SOURCE[0] is the synthetic `main`
  run env AGENTVM_PROJECT=default bash -s -- --list < "$script"
  [ "$status" -eq 0 ]
  [[ $output == *"project: default"* ]]
}

@test "the script only defines its functions when sourced" {
  set -e
  # A sourced file must not start provisioning, and its `return` must not abort
  # the sourcing shell either: this caller runs under `set -euo pipefail`.
  run bash -c 'set -euo pipefail; . "$1"; declare -F main > /dev/null; echo sourced' _ \
    "$BATS_TEST_DIRNAME/../agentvm.bash"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
}

@test "main reports success instead of ending on installer output" {
  set -e
  # A one-component registry, with the component stubbed out: this checks
  # main's closing message, not apt. `base` consumes no secret, so the
  # preflight passes and the sweep is skipped.
  COMPONENTS=(base)
  KNOWN=([base]=1)
  component_base() { :; }

  run main --only base
  [ "$status" -eq 0 ]
  [[ $output == *"done: applied 1 component(s): base"* ]]

  # A rehearsal must never read as a provisioned VM.
  DRY_RUN=1
  run main --only base
  [ "$status" -eq 0 ]
  [[ $output == *"dry run complete, nothing was changed"* ]]
  [[ $output != *"done: applied"* ]]
}

# ---------------------------------------------------------------- ntfy config

# omp-ntfy resolves `{...env defaults, ...saved}`: the saved file wins over
# NTFY_TOPIC/NTFY_SERVER, and the plugin writes a *random* topic plus
# https://ntfy.sh the first time it runs without one. Exporting the variables
# alone therefore stopped taking effect as soon as the plugin had run once.
@test "component_ntfy seeds the plugin config file the plugin actually reads" {
  set -e
  export HOME="$BATS_TEST_TMPDIR/home"
  NTFY_SERVER=http://192.168.123.1:8081
  NTFY_TOPIC=omp
  stub_omp

  component_ntfy

  local cfg="$HOME/.omp/agent/omp-ntfy.json"
  [ -f "$cfg" ]
  # the plugin parses this as JSON and spreads it over its defaults, so the keys
  # and their types matter, not just the text
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["topic"])' "$cfg")" = omp ]
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"])' "$cfg")" = http://192.168.123.1:8081 ]
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["maxTextLength"])' "$cfg")" = 350 ]

  # the exports stay, for a shell whose omp has not read the file yet
  grep -qxF 'export NTFY_TOPIC=omp' "$HOME/.bashrc"
  grep -qxF 'export NTFY_SERVER=http://192.168.123.1:8081' "$HOME/.bashrc"
  grep -q 'install npm:omp-ntfy' "$OMP_LOG"
}

@test "component_ntfy leaves an unchanged config file alone on a re-run" {
  set -e
  export HOME="$BATS_TEST_TMPDIR/home"
  NTFY_SERVER=http://192.168.123.1:8081
  NTFY_TOPIC=omp
  stub_omp

  component_ntfy
  local cfg="$HOME/.omp/agent/omp-ntfy.json" before
  before=$(stat -c '%i %Y' "$cfg")
  sleep 1
  component_ntfy
  # install_config compares first, so a re-run must not rewrite the file
  [ "$(stat -c '%i %Y' "$cfg")" = "$before" ]
}

@test "AGENTVM_NTFY_TOPIC and _SERVER override the defaults" {
  set -e
  export HOME="$BATS_TEST_TMPDIR/home"
  NTFY_SERVER=https://ntfy.example.com
  NTFY_TOPIC=omp-ci-7f3a91
  stub_omp

  component_ntfy

  local cfg="$HOME/.omp/agent/omp-ntfy.json"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["topic"])' "$cfg")" = omp-ci-7f3a91 ]
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"])' "$cfg")" = https://ntfy.example.com ]
}
