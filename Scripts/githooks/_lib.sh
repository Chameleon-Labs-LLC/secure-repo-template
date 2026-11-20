#!/bin/sh
# Shared helpers for the git hooks in this directory.
# Runs under POSIX sh: Linux /bin/sh (dash or bash), WSL, and Git for Windows sh.exe.

# Run the repo-local hook of the same name, if the repo has one.
# Git ignores .git/hooks when core.hooksPath is set, so these hooks chain to it.
# Sets LOCAL_HOOK_RAN=1 when a local hook ran, 0 otherwise (push-to-checkout
# needs to know, because git skips its own default when the hook exists).
# shellcheck disable=SC2034  # LOCAL_HOOK_RAN is read by the hooks that source this
chain_local_hook() {
  _name=$1
  shift
  LOCAL_HOOK_RAN=0
  # Recursion guard, PER HOOK NAME. A local hook that asks git for its hooks dir
  # (`git rev-parse --git-path hooks/<name>`) gets core.hooksPath -- this dir --
  # and would call back into the wrapper it was chained from. So the wrapper
  # skips chaining only for a name already on the chain. A single on/off flag
  # was too broad: git's applypatch-msg sample calls hooks/commit-msg that way,
  # and a global flag made the commit-msg wrapper skip the local commit-msg,
  # silently dropping its validation from `git am`.
  case " ${GITHOOKS_CHAINED:-} " in *" $_name "*) return 0 ;; esac
  _common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$_common" in /*|[A-Za-z]:/*) ;; *) _common="$(git rev-parse --show-toplevel)/$_common" ;; esac
  _local="$_common/hooks"
  [ "$_local" = "$HOOK_DIR" ] && return 0
  [ -f "$_local/$_name" ] || return 0
  _chain="${GITHOOKS_CHAINED:+$GITHOOKS_CHAINED }$_name"
  # Run it the way git would: let its shebang choose the interpreter. Forcing
  # `sh` breaks any hook written for bash, node or python -- which is most of
  # them, since Husky and the pre-commit framework both generate non-sh hooks,
  # and preserving those is the whole point of chaining.
  if [ -x "$_local/$_name" ]; then
    LOCAL_HOOK_RAN=1
    GITHOOKS_CHAINED=$_chain "$_local/$_name" "$@" || return $?
    return 0
  fi
  # No executable bit. On Linux, WSL and macOS git treats that as DISABLED --
  # `chmod -x` is the documented way to switch a hook off -- so running it
  # anyway would revive a hook the user turned off. Git for Windows cannot
  # store the mode and runs hooks regardless of it, so there, and only there,
  # `sh` is the fallback that matches what git itself would do.
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      LOCAL_HOOK_RAN=1
      GITHOOKS_CHAINED=$_chain sh "$_local/$_name" "$@" || return $?
      ;;
    *) log "$_local/$_name is not executable, so git would not run it; skipped (chmod +x to enable it)" ;;
  esac
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
