#!/bin/sh
# The secret gate: gitleaks over the INDEX, failing closed. Shared by every
# hook that runs just before git writes a commit from the index:
#   pre-commit        git commit (and a conflicted merge, committed by hand)
#   pre-merge-commit  an automatic merge commit -- git does NOT run pre-commit
#   pre-applypatch    git am, and git rebase --apply (it replays via am) --
#                     git does NOT run pre-commit either
# Before this file existed only pre-commit scanned, so a merge of a branch
# holding a secret, or a mailed patch holding one, entered history unscanned.
#
# Run it in a subshell from the hook's top level:
#   ( . "$HOOK_DIR/_secret_gate.sh" ) || exit $?
# It ends the subshell with exit 1 to block; returning normally means pass.
# Needs HOOK_DIR set and _lib.sh sourced (for `log`).
# What `pre-commit`'s header says about gitleaks, the exit codes, and
# GITLEAKS_DEGRADED_OK applies here unchanged.
#
# Not covered by any client-side hook, by git's design: cherry-pick, revert,
# the default (merge-backend) rebase and stash replay commits without running
# these hooks. CI's gitleaks
# job is the gate there. `--no-verify` on commit, merge or am skips this file.

TOP=$(git rev-parse --show-toplevel)

# ---- 0. gitleaks: staged changes, always, fails closed -------------------
# Fails closed: a secret blocks, and so does a scan we cannot trust (missing
# binary, or an errored scan). GITLEAKS_DEGRADED_OK=1 passes a degraded scan
# only -- never a found secret.
gitleaks_degraded() {
  if [ "${GITLEAKS_DEGRADED_OK:-0}" = 1 ]; then
    log "$1; GITLEAKS_DEGRADED_OK set, committing UNSCANNED -- say why in the commit message"
    return 0
  fi
  log "$1; commit blocked. $2, or set GITLEAKS_DEGRADED_OK=1 for this commit and explain it in the message"
  exit 1
}

# Resolve the binary, do not just ask PATH. A long-running process keeps the
# PATH it was started with: a systemd user unit whose PATH predates the install
# cannot see ~/.local/bin, and fail-closed would turn that into a blocked
# commit on a machine where gitleaks is in fact installed. So fall back to the
# conventional user-local bin before concluding it is absent.
GITLEAKS=
if command -v gitleaks >/dev/null 2>&1; then
  GITLEAKS=gitleaks
elif [ -f "$HOME/.local/bin/gitleaks" ] && [ -x "$HOME/.local/bin/gitleaks" ]; then
  GITLEAKS="$HOME/.local/bin/gitleaks"
  # Say which binary scanned. Operationally this is the line that tells you a
  # host is running on the fallback, and it is what lets T27 prove it took
  # this branch rather than finding something on PATH after all.
  log "gitleaks not on PATH; using $GITLEAKS"
fi

if [ -n "$GITLEAKS" ]; then
  # --exit-code 3 reserves 3 for findings, so any other non-zero is a scan
  # error and can be told apart from a real secret.
  ( cd "$TOP" && "$GITLEAKS" git --pre-commit --staged --redact -v --no-banner --exit-code 3 )
  rc=$?
  case $rc in
    0) ;;
    3) log "gitleaks found a secret in the staged changes; commit blocked. Remove it, or mark a false positive with a 'gitleaks:allow' comment / .gitleaksignore. No environment variable passes a finding"
       exit 1 ;;
    *) gitleaks_degraded "gitleaks could not complete the scan (exit $rc), so the staged changes are unscanned" "Fix the scan (a bad .gitleaks.toml exits 1)" ;;
  esac

  # The scan above is `git diff --cached`, and it does not produce a patch for
  # every staged file. A `-diff` or `binary` attribute, or a textconv driver,
  # makes git print "Binary files ... differ" instead; gitleaks skips the
  # non-archive binary diff, and the gate PASSES having read nothing. Measured
  # 2026-11-02: a planted ghp_ token in such a file scanned 22 bytes and
  # reported "no leaks found", exit 0. Deleting .gitleaks.toml does not help --
  # different mechanism -- and neither does `--log-opts=--text`, because
  # --pre-commit mode ignores log options, so the `--text` fix used in CI has
  # no equivalent here.
  #
  # ASK GIT WHAT IT ACTUALLY RENDERED, not what the attributes say. `--numstat`
  # prints "-" for added and deleted on exactly the paths it could not render
  # as text. The difference is the whole point: `git diff --cached` resolves
  # attributes from the WORKING TREE, while `git check-attr --cached` reads the
  # INDEX, so a .gitattributes carrying `-diff` that is edited but NOT STAGED
  # makes the two disagree -- the diff suppresses the file while an
  # attribute-based guard reports `unspecified` and skips it, and neither reads
  # the secret. That was this guard's first version; it was reproduced
  # (worktree `unset`, index `unspecified`, hook exit 0) before being replaced.
  #
  # --no-renames keeps the -z records uniform at one per file: with rename
  # detection a rename emits an EMPTY path followed by two more NUL-terminated
  # paths, which a one-record-per-file parser silently mis-reads.
  #
  # The list stays NUL-separated end to end. Converting it to newlines means a
  # filename CONTAINING a newline splits into nonexistent paths, the export
  # fails, and a scan of the empty directory reports clean -- and newline
  # filenames are creatable here, so that is reachable rather than theoretical.
  #
  # The normal scan above is deliberately left alone. Switching the whole gate
  # to `gitleaks stdin` or to a temp materialisation also closes the hole, but
  # stdin reports no file path and a temp scan makes every fingerprint
  # temp-dir-relative, which would silently break the .gitleaksignore escape
  # hatch this hook documents for false positives.
  # Initialized BEFORE anything can trap on them. They are all assigned from
  # mktemp just below, so an inherited value is always overwritten anyway --
  # the explicit list is here because of what happened when one of them WAS
  # NOT. This guard used to materialise files into a temp DIRECTORY, whose name
  # was assigned deep inside the "there are unrenderable files" branch; on an
  # ordinary text-only commit that assignment never ran, so if the calling
  # environment exported that name the EXIT trap `rm -rf`'d a directory the
  # hook never created. `${VAR:-}` guards against UNSET, not against INHERITED.
  # Measured: a clean commit deleted the directory and still exited 0 -- silent
  # data loss on the successful path. Reading staged blobs removed the temp
  # directory entirely, so the bug has no home now; this list keeps a
  # conditionally-assigned name from ever reaching a trap again.
  UNRENDERED=
  NUMSTAT=
  NULS=
  BINRAW=
  BINTXT=
  STAGED=
  TCATTR=
  UNRENDERED=$(mktemp 2>/dev/null) || UNRENDERED=
  NUMSTAT=$(mktemp 2>/dev/null) || NUMSTAT=
  NULS=$(mktemp 2>/dev/null) || NULS=
  BINRAW=$(mktemp 2>/dev/null) || BINRAW=
  BINTXT=$(mktemp 2>/dev/null) || BINTXT=
  STAGED=$(mktemp 2>/dev/null) || STAGED=
  TCATTR=$(mktemp 2>/dev/null) || TCATTR=
  if [ -z "$UNRENDERED" ] || [ -z "$NUMSTAT" ] || [ -z "$NULS" ] \
     || [ -z "$BINRAW" ] || [ -z "$BINTXT" ] || [ -z "$STAGED" ] || [ -z "$TCATTR" ]; then
    gitleaks_degraded "could not create the temp files needed to find the staged files git cannot diff, so they are unscanned" "Free up TMPDIR"
  else
    # No other trap is set in this hook; these remove only these paths.
    #
    # Cleanup on EXIT, and a SEPARATE handler for signals. A POSIX trap on INT
    # or TERM that merely cleans up RETURNS to where it was interrupted, so a
    # Ctrl-C mid-scan would tidy the temp files and then carry straight on
    # through the rest of the hook -- a fail-open on the one path that exists
    # to fail closed. The signal handler exits, and the EXIT trap still fires
    # after it, so nothing is left behind either way.
    #
    # The EXIT handler ends in `:` on purpose. It is belt-and-braces now that
    # the last real command is an `rm -f` that returns 0 even on a missing
    # file, but it used to end in `[ -n "${VAR:-}" ] && rm -rf ...`, which
    # returns 1 whenever the variable is unset -- the common case -- and a
    # trap's final status can surface as the script's own. Keep the `:` so the
    # handler's exit status never depends on what its last command happens to
    # be.
    trap 'rm -f "$UNRENDERED" "$NUMSTAT" "$NULS" "$BINRAW" "$BINTXT" "$STAGED" "$TCATTR"; :' EXIT
    trap 'log "interrupted during the secret scan, so the staged changes are not fully scanned; commit blocked"; exit 1' INT TERM
    # ACMRT, not ACMR: T is a TYPE change (symlink <-> regular file), and
    # omitting it let a symlink replaced by a diff-suppressed regular file skip
    # BOTH scans. Measured 2026-11-02: name-status T, ACMR returned nothing, the
    # token was absent from the staged diff, hook exit 0. D stays excluded: a
    # deleted path has no content and would only make checkout-index fail.
    #
    # Every step is checked. An empty list has to MEAN "nothing to scan" -- if
    # git or awk fails the list is ALSO empty, and inferring "nothing to do"
    # from that passed a secret the normal scan had not read either.
    # PROVE the NUL parser works in this shell before trusting it. The first
    # version used `awk 'BEGIN{RS="\0"}'`, which is a GNU awk extension: it
    # worked on a machine with GNU Awk 5.0.0 and mis-parsed under mawk, which
    # is Ubuntu's default awk and reads "\0" as the empty string, i.e.
    # paragraph mode. The githooks workflow caught it on its first CI run --
    # the mis-parse produced a bogus path, its export failed, and the degraded
    # path then blocked EVERY commit. A parser that silently mis-reads is the
    # worst outcome here, so this one is tested rather than assumed.
    if [ "$(printf 'x\0' | sed -z -n 's/^x$/ok/p' 2>/dev/null | tr -d '\0')" != "ok" ]; then
      gitleaks_degraded "this sed cannot read NUL-separated records, so the staged files git cannot diff are unscanned" "Install GNU sed (its -z is what reads a NUL-separated list safely)"
    fi
    git diff --cached --numstat -z --no-renames --diff-filter=ACMRT > "$NUMSTAT" 2>/dev/null
    gitrc=$?
    sed -z -n 's/^-\t-\t//p' < "$NUMSTAT" > "$UNRENDERED" 2>/dev/null
    sedrc=$?
    # Paths git diffs THROUGH A TEXTCONV DRIVER join the raw scan too. The scan
    # above reads the converted text, and a driver that leaves a credential out
    # of its output hides it while --numstat still prints real counts, so the
    # render check alone never selects the file. Like the smudge case below,
    # this needs a driver in local config, not just the repo -- but a gate
    # must read what it is gating. Only drivers that HAVE a textconv count: a
    # funcname-only `diff=python` changes nothing about what gitleaks reads.
    # check-attr without --cached reads the worktree .gitattributes, which is
    # what `git diff --cached` itself uses (see the render-check note above).
    # Each step goes through a file, for the reason given at `tr` below.
    git diff --cached --name-only -z --no-renames --diff-filter=ACMRT > "$STAGED" 2>/dev/null
    namerc=$?
    git check-attr -z --stdin diff < "$STAGED" > "$NULS" 2>/dev/null
    attrrc=$?
    # -z triples (path, attr, value) become one "value<TAB>path" record each.
    # Under -z, G joins with the record separator -- a NUL, not a newline --
    # so the first NUL is the join point; a path cannot contain one.
    sed -z -n 'h;n;n;G;s/\x00/\t/p' < "$NULS" > "$TCATTR" 2>/dev/null
    tcrc=$?
    while IFS= read -r tckey; do
      [ -n "$tckey" ] || continue
      tcdrv=${tckey#diff.}; tcdrv=${tcdrv%.textconv}
      tcre=$(printf '%s' "$tcdrv" | sed 's/[]\/$*.^[]/\\&/g')
      sed -z -n "s/^$tcre\t//p" < "$TCATTR" >> "$UNRENDERED" 2>/dev/null || tcrc=$?
    done <<TCDRIVERS
$(git config --name-only --get-regexp '^diff\..*\.textconv$' 2>/dev/null)
TCDRIVERS
    # A file can be both unrenderable and textconv'd; scan it once.
    sort -z -u -o "$UNRENDERED" "$UNRENDERED" 2>/dev/null || tcrc=$?
    # Through a file, because a pipeline reports only its LAST command: a first
    # `tr` that failed to read the list left `wc` counting empty input and
    # printing 0, the numeric check accepted it, and the scan was skipped --
    # the same "an empty result is not a clean result" bug as the detection
    # step, one layer down.
    tr -dc '\0' < "$UNRENDERED" > "$NULS" 2>/dev/null
    trrc=$?
    WANT=$(wc -c < "$NULS" 2>/dev/null | tr -d ' \t')
    if [ "$trrc" -ne 0 ]; then
      gitleaks_degraded "could not count the staged files git cannot diff (tr exit $trrc), so any such file is unscanned" "Check that tr works"
    elif [ "$gitrc" -ne 0 ]; then
      gitleaks_degraded "git could not list which staged files it cannot diff (exit $gitrc), so any such file is unscanned" "Fix the git error"
    elif [ "$namerc" -ne 0 ] || [ "$attrrc" -ne 0 ]; then
      gitleaks_degraded "git could not list which staged files use a textconv driver (exit $namerc/$attrrc), so any such file is not scanned as staged bytes" "Fix the git error"
    elif [ "$tcrc" -ne 0 ]; then
      gitleaks_degraded "could not select the staged files that use a textconv driver (exit $tcrc), so any such file is not scanned as staged bytes" "Make sure GNU sed and sort are on PATH"
    elif [ "$sedrc" -ne 0 ]; then
      gitleaks_degraded "could not select the staged files git cannot diff (sed exit $sedrc), so any such file is unscanned" "Make sure GNU sed is on PATH"
    else
      case "${WANT:-x}" in
        '' | *[!0-9]*)
          gitleaks_degraded "could not count the staged files git cannot diff (got '${WANT:-}'), so any such file is unscanned" "Check that tr and wc work" ;;
        *) ;;
      esac
    fi
    if [ "${WANT:-0}" -gt 0 ]; then
      log "git could not render $WANT staged file(s) as text, or renders them through a textconv filter, so the scan above did not read their real bytes; scanning their staged bytes directly:"
      tr '\0' '\n' < "$UNRENDERED" | sed 's/^/          /' >&2
      # Read the STAGED BLOBS, never a checkout. `git checkout-index` applies
      # checkout conversions, smudge filters among them, so it can hand back
      # transformed bytes while the blob that will actually be committed still
      # holds the secret. Measured with `filter.hide.smudge` configured:
      # checkout-index wrote "token = REDACTED" and gitleaks passed it, while
      # the staged blob held the real token and gitleaks found it. A local
      # filter definition is needed for that (`.git/config`, not the repo, so a
      # PR cannot enable it alone) -- but git-lfs, git-crypt and templating
      # setups all configure one, and a gate must read what it is gating.
      #
      # This also deletes the machinery that caused three earlier defects here:
      # no temp directory (so the trap has no inherited path to delete), no
      # export (so no exported-count check and no symlink false block), and no
      # `gitleaks dir` over converted bytes. `gitleaks dir` did give per-file
      # paths in findings, which is why it was used -- but it was reading the
      # wrong bytes, and its fingerprints were temp-dir relative, so
      # `.gitleaksignore` never applied on this path either way.
      #
      # The `printf` after each blob keeps a separator between files: with
      # nothing between them one file's last byte runs into the next file's
      # first and a rule needing a leading word boundary stops matching
      # (measured: `npm_<36>` fires alone, not when prefixed by a word char).
      if ! xargs -0 -r -n1 sh -c '
             # :(literal) -- a bare "$1" is a PATHSPEC, so glob characters in
             # a filename select OTHER files. Measured: looking up [A].bin
             # matched 2 entries and head -1 returned the OID of A.bin, the
             # clean file, while the secret in [A].bin went unread. With
             # :(literal) it matches exactly 1 entry, the right one.
             # NOTE: this whole script is single-quoted for sh -c, so no
             # apostrophes here -- one of them closed the quote and broke the
             # hook while writing this very comment.
             oid=$(git ls-files -s -- ":(literal)$1" | cut -d" " -f2 | head -1)
             [ -n "$oid" ] || exit 1
             git cat-file blob "$oid" || exit 1
             printf "\n"
           ' _ < "$UNRENDERED" > "$BINRAW" 2>/dev/null; then
        gitleaks_degraded "could not read the staged bytes of the $WANT file(s) git cannot diff, so they are unscanned" "Fix the git error above"
      else
        # TWO representations, because each hides what the other catches.
        # Stripping NULs keeps a token that has NULs interleaved through it, but
        # loses the word boundary when the boundary IS a NUL byte; translating
        # NULs to newlines is the exact opposite. Measured both ways:
        #   boundary is a NUL      tr -d  -> clean (MISSED)   tr NUL->\n -> found
        #   NULs inside the token  tr -d  -> found            tr NUL->\n -> clean
        # So the second pass runs whenever the first comes back clean.
        rc=0
        for xlate in strip newline; do
          case "$xlate" in
            strip)   tr -d '\0' < "$BINRAW" > "$BINTXT" 2>/dev/null ;;
            newline) tr '\0' '\n' < "$BINRAW" > "$BINTXT" 2>/dev/null ;;
          esac
          if [ $? -ne 0 ]; then
            gitleaks_degraded "could not build the $xlate representation of the staged bytes, so the $WANT file(s) git cannot diff are unscanned" "Fix the tr error"
            break
          fi
          ( "$GITLEAKS" stdin --redact --no-banner --exit-code 3 ) < "$BINTXT"
          rc=$?
          [ "$rc" -eq 0 ] || break
        done
        case $rc in
          0) ;;
          3) log "gitleaks found a secret in the staged bytes of a file git cannot diff as text; commit blocked. The real file is one of those listed above -- a finding from this pass carries no path. No environment variable passes a finding"
             exit 1 ;;
          *) gitleaks_degraded "gitleaks could not scan the staged bytes of the $WANT file(s) git cannot diff (exit $rc)" "Fix the scan, or drop the attribute so the normal staged scan covers them" ;;
        esac
      fi
    fi
  fi

else
  gitleaks_degraded "gitleaks is not on PATH and not at ~/.local/bin/gitleaks, so the staged changes are unscanned" "Install it (winget install --id Gitleaks.Gitleaks --scope user, or the release tarball to ~/.local/bin)"
fi
