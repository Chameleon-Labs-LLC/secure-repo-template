#!/bin/sh
# Install the git hooks in this directory.
#
#   sh Scripts/githooks/install.sh
#       Every repo on this machine: copies the hooks to ~/.githooks and sets
#       the GLOBAL core.hooksPath there.
#   sh Scripts/githooks/install.sh --repo
#       This repository only: sets its LOCAL core.hooksPath to
#       Scripts/githooks (no copy). Same as
#       `git config core.hooksPath Scripts/githooks`.
#   sh Scripts/githooks/install.sh --uninstall [--repo]
#       Undo. Same as `git config [--global] --unset core.hooksPath`, but
#       refuses to remove a global setting that is not this install's.
#
# Options:
#   --force          replace a global core.hooksPath that points somewhere else
#   GITHUB_ROOT=dir  install to <dir>/.githooks instead of ~/.githooks
#
# Supported: Linux, WSL, and Git Bash on Windows. WSL and Git Bash each have
# their own git and global config, so run the global install once in each
# environment you commit from.
#
# Re-run after editing a hook (global mode copies files). Idempotent.
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
MODE=global
ACTION=install
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --repo) MODE=repo ;;
    --uninstall) ACTION=uninstall ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

# Git for Windows is a native program: hand it a C:/... path, not /c/...
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

if ! command -v gitleaks >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/gitleaks" ]; then
  echo "NOTE: gitleaks is not installed. The pre-commit hook fails closed, so every"
  echo "      commit will be BLOCKED until it is. See docs/security-setup.md, step 2."
fi

if [ "$MODE" = repo ]; then
  TOP=$(git -C "$SRC" rev-parse --show-toplevel)
  # A relative hooksPath resolves against the top of the working tree, so this
  # keeps working if the repository is moved or cloned elsewhere. Ask git for
  # the prefix rather than trimming paths: in Git Bash, pwd says /c/... while
  # git says C:/..., and the two never match.
  REL=$(git -C "$SRC" rev-parse --show-prefix)
  REL=${REL%/}
  CURRENT=$(git -C "$TOP" config --local --get core.hooksPath 2>/dev/null || true)
  if [ "$ACTION" = uninstall ]; then
    if [ -z "$CURRENT" ]; then
      echo "This repo has no core.hooksPath; nothing to undo."
    elif [ "$CURRENT" = "$REL" ]; then
      git -C "$TOP" config --local --unset core.hooksPath
      echo "Removed core.hooksPath ($REL) from this repo."
    else
      echo "This repo's core.hooksPath is '$CURRENT', not this install ($REL). Left it alone." >&2
      exit 1
    fi
    exit 0
  fi
  # Another tool (Husky, for one) may own this setting. Replacing it silently
  # would switch that tool's hooks off, so ask for --force.
  if [ -n "$CURRENT" ] && [ "$CURRENT" != "$REL" ] && [ "$FORCE" != 1 ]; then
    echo "This repo's core.hooksPath is already '$CURRENT'." >&2
    echo "Re-run with --force to replace it. To restore it later:" >&2
    echo "  git config --local core.hooksPath '$CURRENT'" >&2
    exit 1
  fi
  # Executable bits matter on Linux and WSL.
  for f in "$SRC"/*; do
    case "$(basename "$f")" in *.md) continue ;; esac
    chmod +x "$f" 2>/dev/null || true
  done
  git -C "$TOP" config --local core.hooksPath "$REL"
  echo "This repo: core.hooksPath = $(git -C "$TOP" config --local --get core.hooksPath)"
  [ -z "$CURRENT" ] || [ "$CURRENT" = "$REL" ] || echo "Replaced '$CURRENT'. To restore it: git config --local core.hooksPath '$CURRENT'"
  exit 0
fi

if [ -n "${GITHUB_ROOT:-}" ]; then
  # Resolve to an absolute path. A relative value in the GLOBAL config would
  # be resolved against each repository's own root, where the hooks are not,
  # and commits would run with no secret scan at all.
  mkdir -p "$GITHUB_ROOT"
  ROOT_ABS=$(cd "$GITHUB_ROOT" && pwd)
  DEST="$ROOT_ABS/.githooks"
else
  DEST="$HOME/.githooks"
fi
DEST_CFG=$(native_path "$DEST")
# Marks a directory as this installer's, so it can tell its own files from
# hooks someone already keeps there.
MARKER=".installed-by-githooks-install"
CURRENT=$(git config --global --get core.hooksPath 2>/dev/null || true)

if [ "$ACTION" = uninstall ]; then
  if [ -z "$CURRENT" ]; then
    echo "No global core.hooksPath is set; nothing to undo."
  elif [ "$CURRENT" = "$DEST_CFG" ] || [ "$CURRENT" = "$DEST" ]; then
    git config --global --unset core.hooksPath
    echo "Removed global core.hooksPath. The files in $DEST were left in place; delete them if you like."
  else
    echo "Global core.hooksPath is '$CURRENT', not this install ($DEST_CFG). Left it alone." >&2
    exit 1
  fi
  exit 0
fi

if [ -n "$CURRENT" ] && [ "$CURRENT" != "$DEST_CFG" ] && [ "$CURRENT" != "$DEST" ] && [ "$FORCE" != 1 ]; then
  echo "Global core.hooksPath is already '$CURRENT'." >&2
  echo "Re-run with --force to replace it. To restore it later:" >&2
  echo "  git config --global core.hooksPath '$CURRENT'" >&2
  exit 1
fi

# The destination may already hold someone's own hooks. Only overwrite a
# directory this installer created (it carries the marker); otherwise stop,
# and with --force move the old directory aside instead of overwriting it.
# True when DEST holds anything besides the usage/ counters dir.
has_other_files() {
  for _p in "$DEST"/* "$DEST"/.[!.]* "$DEST"/..?*; do
    [ -e "$_p" ] || [ -L "$_p" ] || continue
    [ "$(basename "$_p")" = usage ] && continue
    return 0
  done
  return 1
}
if [ -d "$DEST" ] && [ ! -f "$DEST/$MARKER" ] && has_other_files; then
  if [ "$FORCE" != 1 ]; then
    echo "$DEST already holds files this installer did not put there." >&2
    echo "Re-run with --force to move them to a backup directory first, or set GITHUB_ROOT to install elsewhere." >&2
    exit 1
  fi
  BACKUP="$DEST.backup-$(date +%Y%m%d-%H%M%S)"
  mv "$DEST" "$BACKUP"
  echo "Moved the existing $DEST to $BACKUP"
fi

mkdir -p "$DEST/usage"
: > "$DEST/$MARKER"
for f in "$SRC"/*; do
  case "$(basename "$f")" in install.sh|test-pre-commit.sh|*.md) continue ;; esac
  cp "$f" "$DEST/"
  chmod +x "$DEST/$(basename "$f")"
done
git config --global core.hooksPath "$DEST_CFG"
echo "Global: core.hooksPath = $(git config --global --get core.hooksPath)"
echo "Installed to $DEST"
[ -z "$CURRENT" ] || [ "$CURRENT" = "$DEST_CFG" ] || [ "$CURRENT" = "$DEST" ] \
  || echo "Replaced '$CURRENT'. To restore it: git config --global core.hooksPath '$CURRENT'"
echo "Note: a repo with its OWN core.hooksPath (Husky sets one) overrides this global"
echo "      setting, so these hooks do not run there. 'git config --local --get core.hooksPath'"
echo "      shows it. Chaining covers .git/hooks only."
