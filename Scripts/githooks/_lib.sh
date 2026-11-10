#!/bin/sh
# Shared helpers for the git hooks in this directory.
# Runs under POSIX sh: Linux /bin/sh (dash or bash), WSL, and Git for Windows sh.exe.

# Run the repo-local hook of the same name, if the repo has one.
# Git ignores .git/hooks when core.hooksPath is set, so these hooks chain to it.
chain_local_hook() {
  _name=$1
  shift
  # Recursion guard: git rev-parse --git-path hooks returns core.hooksPath (this dir),
  # so resolve the repo's own hooks dir from the common git dir instead.
  [ "${GITHOOKS_CHAINED:-0}" = 0 ] || return 0
  _common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$_common" in /*|[A-Za-z]:/*) ;; *) _common="$(git rev-parse --show-toplevel)/$_common" ;; esac
  _local="$_common/hooks"
  [ "$_local" = "$HOOK_DIR" ] && return 0
  if [ -f "$_local/$_name" ]; then
    # Run it the way git would: let its shebang choose the interpreter. Forcing
    # `sh` breaks any hook written for bash, node or python -- which is most of
    # them, since Husky and the pre-commit framework both generate non-sh hooks,
    # and preserving those is the whole point of chaining. `sh` stays as the
    # fallback for a hook with no executable bit, common on Windows checkouts
    # where git cannot store the mode.
    if [ -x "$_local/$_name" ]; then
      GITHOOKS_CHAINED=1 "$_local/$_name" "$@" || return $?
    else
      GITHOOKS_CHAINED=1 sh "$_local/$_name" "$@" || return $?
    fi
  fi
  return 0
}

log() { printf 'githooks: %s\n' "$*" >&2; }

# Monthly soft counter for metered Snyk tests, one file per org per month.
# It lives next to the installed hooks, so WSL and Git Bash keep separate
# counts unless they share one install directory.
usage_file() {
  _dir="$HOOK_DIR/usage"
  mkdir -p "$_dir"
  printf '%s/%s-%s.txt' "$_dir" "$(date +%Y-%m)" "$1"
}
usage_get() { # usage_get <org> <key>
  _f=$(usage_file "$1")
  [ -f "$_f" ] || { echo 0; return; }
  _v=$(grep "^$2=" "$_f" | tail -n1 | cut -d= -f2)
  echo "${_v:-0}"
}
usage_inc() { # usage_inc <org> <key>
  _f=$(usage_file "$1")
  _n=$(( $(usage_get "$1" "$2") + 1 ))
  if [ -f "$_f" ] && grep -q "^$2=" "$_f"; then
    sed -i "s/^$2=.*/$2=$_n/" "$_f"
  else
    printf '%s=%s\n' "$2" "$_n" >> "$_f"
  fi
}
