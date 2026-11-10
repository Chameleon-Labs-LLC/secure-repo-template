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
  if [ "$ACTION" = uninstall ]; then
    git -C "$TOP" config --local --unset core.hooksPath || true
    echo "Removed core.hooksPath from $TOP/.git/config"
    exit 0
  fi
  # A relative hooksPath resolves against the top of the working tree, so this
  # keeps working if the repository is moved or cloned elsewhere. Ask git for
  # the prefix rather than trimming paths: in Git Bash, pwd says /c/... while
  # git says C:/..., and the two never match.
  REL=$(git -C "$SRC" rev-parse --show-prefix)
  REL=${REL%/}
  # Executable bits matter on Linux and WSL. Record them in the index too, so a
  # fresh clone gets them even when this checkout came from Windows.
  for f in "$SRC"/*; do
    case "$(basename "$f")" in *.md) continue ;; esac
    chmod +x "$f" 2>/dev/null || true
  done
  git -C "$TOP" config --local core.hooksPath "$REL"
  echo "This repo: core.hooksPath = $(git -C "$TOP" config --local --get core.hooksPath)"
  exit 0
fi

if [ -n "${GITHUB_ROOT:-}" ]; then
  DEST="$GITHUB_ROOT/.githooks"
else
  DEST="$HOME/.githooks"
fi
DEST_CFG=$(native_path "$DEST")
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

mkdir -p "$DEST/usage"
for f in "$SRC"/*; do
  case "$(basename "$f")" in install.sh|test-pre-commit.sh|*.md) continue ;; esac
  cp "$f" "$DEST/"
  chmod +x "$DEST/$(basename "$f")"
done
git config --global core.hooksPath "$DEST_CFG"
echo "Global: core.hooksPath = $(git config --global --get core.hooksPath)"
echo "Installed to $DEST"
echo "Note: a repo with its OWN core.hooksPath (Husky sets one) overrides this global"
echo "      setting, so these hooks do not run there. 'git config --local --get core.hooksPath'"
echo "      shows it. Chaining covers .git/hooks only."
