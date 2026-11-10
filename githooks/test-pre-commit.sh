#!/bin/sh
# Self-test for the pre-commit hook: the dependency-delta logic, the Snyk Code
# source gate, and the secret gate. Runs the CANONICAL hook next to this script
# (not the installed copy) in a throwaway repo. No Snyk quota is spent: most
# cases use SNYK_HOOK_MODE=off, and the end-to-end cases put a stub `snyk`
# first on PATH. Needs git, node, and gitleaks on PATH.
#
#   sh githooks/test-pre-commit.sh
#
# Exit 0 when every case passes, 1 otherwise. Add a case here before changing
# deps_changed(), staged_files(), or code_staged().
#
# reset_tree() restores the worktree and the index between cases, but NOT the
# COMMITS. A case that commits a path leaves it in HEAD for every case after
# it, so reusing a path another case has committed can leave nothing to stage
# and make a case pass vacuously -- that has cost three cases here (T33k,
# T33m2, and a draft of T33i). Give a new case its own path, and make it FAIL
# rather than skip when its setup did not produce the state it names. The helpers are tested by
# extracting the hook text between `DEPS_JS=` and `# ---- 1. Open Source`, so
# any new helper must be defined inside that window.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/pre-commit"
T=$(mktemp -d)
F=$(mktemp)   # extracted hook functions live OUTSIDE the temp repo: reset_tree runs git clean
trap 'rm -rf "$T" "$F"' EXIT INT TERM
FAIL=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=1; }
g() { git -C "$T" "$@"; }
# Run deps_changed from the hook against the temp repo; echoes its exit code.
# shellcheck source=/dev/null  # $F is extracted at runtime
deps() { ( cd "$T" && . "$F" && deps_changed "$1" >/dev/null 2>&1; echo $? ); }
# Run code_staged from the hook against the temp repo; echoes its exit code.
# shellcheck source=/dev/null  # $F is extracted at runtime
code() { ( cd "$T" && . "$F" && code_staged >/dev/null 2>&1; echo $? ); }
# Does staged_files list this exact path, unquoted? Echoes grep's exit code.
# shellcheck source=/dev/null  # $F is extracted at runtime
lists() { ( cd "$T" && . "$F" && staged_files | grep -qxF "$1"; echo $? ); }
expect() { # expect <label> <got> <want>
  if [ "$2" = "$3" ]; then pass "$1 (rc=$2)"; else fail "$1 (rc=$2, want $3)"; fi
}
reset_tree() { g checkout -q -- . 2>/dev/null; g reset -q; g clean -qfd; }

for bin in git node gitleaks; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing: $bin"; exit 1; }
done

git init -q "$T"
g config user.email t@t.local
g config user.name t
g config core.hooksPath "$HERE"

# Fixtures: an npm manifest + lockfile, a Ruby manifest + lockfile, a pip manifest.
printf '{"name":"t","version":"1.0.0","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.1"}}\n' > "$T/package.json"
printf '{"name":"t","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"t","version":"1.0.0","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.1"}},"node_modules/left-pad":{"version":"1.0.0","resolved":"x"},"node_modules/is-odd":{"version":"3.0.1","resolved":"y"}}}\n' > "$T/package-lock.json"
printf 'source "https://rubygems.org"\ngem "rake"\n' > "$T/Gemfile"
printf 'GEM\n  specs:\n    rake (13.0.0)\n' > "$T/Gemfile.lock"
printf 'requests==2.0.0\n' > "$T/requirements.txt"
g add -A
g commit -q --no-verify -m fixtures

# The hook's helper functions, extracted verbatim.
awk '/^DEPS_JS=/,/^# ---- 1\. Open Source/' "$HOOK" | awk '!/^# ---- 1/' > "$F"

# --- deps_changed ---------------------------------------------------------
printf '{"name":"t","version":"1.0.1","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.1"}}\n' > "$T/package.json"; g add package.json
expect "T1 package.json: version only -> unchanged" "$(deps package.json)" 1; reset_tree

printf '{"name":"t","version":"1.0.0","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.1","ms":"2.1.3"}}\n' > "$T/package.json"; g add package.json
expect "T2 package.json: dependency added -> changed" "$(deps package.json)" 0; reset_tree

printf '{"name":"t","version":"1.0.0","dependencies":{"is-odd":"3.0.1","left-pad":"1.0.0"}}\n' > "$T/package.json"; g add package.json
expect "T3 package.json: keys reordered -> unchanged" "$(deps package.json)" 1; reset_tree

printf '{"name":"t","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"t","version":"1.0.0","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.1"}},"node_modules/left-pad":{"version":"1.0.1","resolved":"x"},"node_modules/is-odd":{"version":"3.0.1","resolved":"y"}}}\n' > "$T/package-lock.json"; g add package-lock.json
expect "T4 package-lock.json only: transitive bump -> changed" "$(deps package.json)" 0; reset_tree

printf '{"name":"t","version":"1.0.1","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.1"}}\n' > "$T/package.json"
printf '{"name":"t","version":"1.0.1","lockfileVersion":3,"packages":{"":{"name":"t","version":"1.0.1","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.1"}},"node_modules/left-pad":{"version":"1.0.0","resolved":"x"},"node_modules/is-odd":{"version":"3.0.1","resolved":"y"}}}\n' > "$T/package-lock.json"
g add package.json package-lock.json
expect "T5 manifest + lockfile: root version only -> unchanged" "$(deps package.json)" 1; reset_tree

printf 'GEM\n  specs:\n    rake (13.0.1)\n' > "$T/Gemfile.lock"; g add Gemfile.lock
expect "T6 Gemfile.lock only -> changed" "$(deps Gemfile)" 0; reset_tree

printf 'requests==2.0.0\n-r extra.txt\n' > "$T/requirements.txt"; g add requirements.txt
expect "T7 requirements.txt: added -r line -> changed" "$(deps requirements.txt)" 0; reset_tree

# --- secret gate -----------------------------------------------------------
tok="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
printf 'token = "%s"\n' "$tok" > "$T/leak.txt"; g add leak.txt
SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; rc=$?
expect "T8 staged fake GitHub PAT -> blocked" "$rc" 1

SNYK_SKIP=1 SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; rc=$?
expect "T9 same, with SNYK_SKIP=1 -> still blocked (no env bypass)" "$rc" 1
reset_tree

printf 'hello\n' > "$T/ok.txt"; g add ok.txt
SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; rc=$?
expect "T10 clean stage -> passes" "$rc" 0
reset_tree

# --- secret gate: fail-closed paths ---------------------------
# Two environments are needed. S is a stub dir placed FIRST on PATH, so the
# stub shadows the real binary: that covers "the scan errored". NOGL is PATH
# with every directory holding a gitleaks executable removed: that covers "no
# binary at all". Removing the directories, not one entry, handles a second
# install. Both live outside $T, which reset_tree cleans. SNYK_SKIP=1 makes the
# hook exit right after step 0, so these cases need nothing but git.
S=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$S/gitleaks"; chmod +x "$S/gitleaks"
trap 'rm -rf "$T" "$F" "$S"' EXIT INT TERM
NOGL=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -x "$d/gitleaks" ] || [ -x "$d/gitleaks.exe" ] || printf '%s\n' "$d"
done | paste -sd: -)

# Every case below asserts the hook's own message, not just the exit code.
# Exit code alone is not enough: if NOGL were missing git, or still had a
# gitleaks, the hook would exit non-zero or zero for an unrelated reason and
# T21/T23 would pass for the wrong reason. The message names the code path.
saw() { # saw <label> <output> <needle>
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in output)" ;; esac
}

printf 'hello\n' > "$T/ok.txt"; g add ok.txt

# HOME for the absent-cases. The hook falls back to $HOME/.local/bin before
# declaring the binary missing, and on many machines that path exists -- so
# "absent" has to mean absent from PATH *and* from the fallback, or T21-T23
# would silently stop exercising the fail-closed branch.
BAREHOME=$(mktemp -d)
trap 'rm -rf "$T" "$F" "$S" "$BAREHOME"' EXIT INT TERM

# Guard: NOGL must really be "git yes, gitleaks no", or these three cannot run.
if ! ( PATH="$NOGL"; export PATH; command -v git >/dev/null 2>&1 ); then
  fail "T21-T23 unrunnable: removing the gitleaks directory also removed git"
elif ( PATH="$NOGL"; export PATH; command -v gitleaks >/dev/null 2>&1 ); then
  fail "T21-T23 unrunnable: a gitleaks is still on PATH after filtering"
else
  out=$( PATH="$NOGL"; HOME="$BAREHOME"; export PATH HOME; SNYK_SKIP=1 g hook run pre-commit 2>&1 ); rc=$?
  expect "T21 gitleaks absent -> blocked (fail closed)" "$rc" 1
  saw   "T21a ... and says so" "$out" "not on PATH and not at"

  out=$( PATH="$NOGL"; HOME="$BAREHOME"; export PATH HOME; GITLEAKS_DEGRADED_OK=1 SNYK_SKIP=1 g hook run pre-commit 2>&1 ); rc=$?
  expect "T22 gitleaks absent + GITLEAKS_DEGRADED_OK=1 -> passes unscanned" "$rc" 0
  saw   "T22a ... and warns it is unscanned" "$out" "committing UNSCANNED"

  out=$( PATH="$NOGL"; HOME="$BAREHOME"; export PATH HOME; GITLEAKS_DEGRADED_OK=false SNYK_SKIP=1 g hook run pre-commit 2>&1 ); rc=$?
  expect "T23 gitleaks absent + GITLEAKS_DEGRADED_OK=false -> blocked (only 1 enables)" "$rc" 1
  saw   "T23a ... and does not claim the override" "$out" "commit blocked"
fi

out=$( PATH="$S:$PATH"; export PATH; SNYK_SKIP=1 g hook run pre-commit 2>&1 ); rc=$?
expect "T24 scan errors (exit 1) -> blocked" "$rc" 1
saw   "T24a ... as a scan error, not a finding" "$out" "could not complete the scan"

out=$( PATH="$S:$PATH"; export PATH; GITLEAKS_DEGRADED_OK=1 SNYK_SKIP=1 g hook run pre-commit 2>&1 ); rc=$?
expect "T25 scan errors + GITLEAKS_DEGRADED_OK=1 -> passes unscanned" "$rc" 0
saw   "T25a ... and warns it is unscanned" "$out" "committing UNSCANNED"
reset_tree

# T27-T28: gitleaks reachable ONLY via $HOME/.local/bin. That is the
# long-running-service case: a systemd user unit keeps the PATH it started with, which has no
# ~/.local/bin, while the binary is installed there. Before the fallback the
# hook called that "absent" and fail-closed blocked the commit.
FAKEHOME=$(mktemp -d)
trap 'rm -rf "$T" "$F" "$S" "$BAREHOME" "$FAKEHOME"' EXIT INT TERM
mkdir -p "$FAKEHOME/.local/bin"
GLREAL=$(command -v gitleaks || true)
if [ -z "$GLREAL" ] && [ -x "$HOME/.local/bin/gitleaks" ]; then
  GLREAL="$HOME/.local/bin/gitleaks"
fi
if [ -z "$GLREAL" ]; then
  fail "T27-T28 unrunnable: no real gitleaks to place in the fallback"
else
  cp "$GLREAL" "$FAKEHOME/.local/bin/gitleaks"
  chmod +x "$FAKEHOME/.local/bin/gitleaks"

  printf 'hello\n' > "$T/ok2.txt"; g add ok2.txt
  out=$( PATH="$NOGL"; HOME="$FAKEHOME"; export PATH HOME; SNYK_SKIP=1 g hook run pre-commit 2>&1 ); rc=$?
  expect "T27 gitleaks only in \$HOME/.local/bin -> scan runs, clean stage passes" "$rc" 0
  saw   "T27a ... and actually scanned (not treated as absent)" "$out" "no leaks found"
  # Assert the PHRASE, not the absolute path. The hook prints "gitleaks not on
  # PATH; using ..." only inside the fallback branch, so the phrase alone proves
  # this case's claim. The path prefix proved nothing extra and made the verdict
  # depend on `mktemp -d`: with TMPDIR unset it returns /tmp/tmp.X, and with
  # TMPDIR exported it returns /c/Users/.../Temp/tmp.X, while git hands the hook
  # the /tmp spelling either way. So this case passed or failed on whether the
  # CALLER had TMPDIR set -- ambient state it does not control -- and the two
  # strings were the same directory spelled differently, never a real defect.
  saw   "T27b ... via the fallback, not something left on PATH" "$out" "gitleaks not on PATH; using "
  # Compare the FILE, not the path text. Extract the path the hook named and
  # test it with -ef (same device and inode): immune to the two spellings that
  # broke the old assertion, AND it proves the binary is this fixture's. A
  # suffix match would accept any other .local/bin/gitleaks, so it could not
  # tell the fixture HOME from a real one. Verified that -ef sees /tmp/tmp.X/f
  # and /c/Users/.../Temp/tmp.X/f as one file.
  gl_named=$(printf '%s\n' "$out" | sed -n 's/.*gitleaks not on PATH; using //p' | head -1)
  if [ -n "$gl_named" ] && [ "$gl_named" -ef "$FAKEHOME/.local/bin/gitleaks" ]; then
    p=0
  else
    p=1
  fi
  expect "T27c ... and that binary IS the fixture, not another .local/bin/gitleaks" "$p" 0
  reset_tree

  tok3="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
  printf 'token = "%s"\n' "$tok3" > "$T/leak3.txt"; g add leak3.txt
  out=$( PATH="$NOGL"; HOME="$FAKEHOME"; export PATH HOME; SNYK_SKIP=1 g hook run pre-commit 2>&1 ); rc=$?
  expect "T28 same, staged PAT -> blocked as a finding" "$rc" 1
  saw   "T28a ... as a finding, not a degraded scan" "$out" "found a secret"
  reset_tree
fi
rm -rf "$FAKEHOME"

# A finding exits 3 under --exit-code 3, and no override passes it.
tok2="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
printf 'token = "%s"\n' "$tok2" > "$T/leak2.txt"; g add leak2.txt
out=$(GITLEAKS_DEGRADED_OK=1 SNYK_SKIP=1 g hook run pre-commit 2>&1); rc=$?
expect "T26 staged PAT + GITLEAKS_DEGRADED_OK=1 -> still blocked (a finding is never overridable)" "$rc" 1
saw   "T26a ... as a finding, not a degraded scan" "$out" "found a secret"
reset_tree

# --- code_staged: Snyk Code runs only when source is staged ---------------
printf '# docs\n' > "$T/README.md"; printf 'a: 1\n' > "$T/c.yml"; g add README.md c.yml
expect "T11 docs + config only -> no source staged" "$(code)" 1; reset_tree
printf 'export const x = 1\n' > "$T/a.ts"; g add a.ts
expect "T12 a .ts file staged -> source staged" "$(code)" 0; reset_tree
printf '# docs\n' > "$T/README.md"; printf 'x = 1\n' > "$T/b.py"; g add README.md b.py
expect "T13 docs + a .py file -> source staged" "$(code)" 0; reset_tree
printf 'class A {}\n' > "$T/A.JAVA"; g add A.JAVA
expect "T14 upper-case extension -> source staged" "$(code)" 0; reset_tree
printf '1\n' > "$T/gone.js"; g add gone.js; g commit -q --no-verify -m gone; g rm -q gone.js
expect "T15 only a deletion staged -> no source staged" "$(code)" 1; reset_tree
g reset -q --hard HEAD~1
printf '{"name":"t","version":"1.0.2","dependencies":{"left-pad":"1.0.0","is-odd":"3.0.1"}}\n' > "$T/package.json"; g add package.json
expect "T16 release-style package.json bump -> no source staged" "$(code)" 1; reset_tree

# --- staged_files: non-ASCII paths come through unquoted (core.quotePath) ---
mkdir -p "$T/src"; printf 'export const y = 2\n' > "$T/src/café.ts"; g add src
expect "T17 non-ASCII .ts path -> source staged" "$(code)" 0; reset_tree
mkdir -p "$T/café"; printf '{"name":"c","version":"1.0.0"}\n' > "$T/café/package.json"; g add café
expect "T18 non-ASCII manifest dir -> listed unquoted for the manifest scan" "$(lists 'café/package.json')" 0; reset_tree

# --- end to end: the daily stamp, with a stub snyk (no quota spent) --------
# A copy of the hook runs from a temp dir: the usage counters write next to
# the hook, and the canonical tree must stay clean.
HK=$(mktemp -d); STUB=$(mktemp -d); LOG="$STUB/calls"
cp "$HOOK" "$HERE/_lib.sh" "$HK/"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$LOG" > "$STUB/snyk"; chmod +x "$STUB/snyk"; : > "$LOG"
g config core.hooksPath "$HK"
STAMPF="$(g rev-parse --absolute-git-dir)/snyk-code-stamp"; rm -f "$STAMPF"
printf '# docs\n' > "$T/README.md"; g add README.md
PATH="$STUB:$PATH" SNYK_HOOK_MODE=warn g hook run pre-commit >/dev/null 2>&1
ran=$(grep -c '^code test' "$LOG" 2>/dev/null); [ -f "$STAMPF" ] && st=1 || st=0
expect "T19 docs-only commit -> no Code run, no stamp" "$ran$st" 00; reset_tree
: > "$LOG"   # count only this case's calls
printf 'export const z = 3\n' > "$T/z.ts"; g add z.ts
PATH="$STUB:$PATH" SNYK_HOOK_MODE=warn g hook run pre-commit >/dev/null 2>&1
ran=$(grep -c '^code test' "$LOG" 2>/dev/null); [ -f "$STAMPF" ] && st=1 || st=0
expect "T20 then a source commit -> Code runs once, stamp written" "$ran$st" 11; reset_tree

# --- the stamp carries the day's VERDICT, not just the date ---------------
# Stamping the date alone lost a block: a finding stamped the day, the retry an
# hour later took the once-a-day skip, FAIL started at 0, and in block mode the
# second attempt at the same commit passed with the finding unfixed.
printf '#!/bin/sh\necho "$*" >> "%s"\ncase "$1" in code) exit 1 ;; esac\nexit 0\n' "$LOG" > "$STUB/snyk"
chmod +x "$STUB/snyk"
: > "$LOG"; rm -f "$STAMPF"
printf 'export const s = 1\n' > "$T/s1.ts"; g add s1.ts
rc=$( PATH="$STUB:$PATH" SNYK_HOOK_MODE=block g hook run pre-commit >/dev/null 2>&1; echo $? )
expect "T29 Snyk Code finding, block mode -> blocked" "$rc" 1
grep -q ':fail' "$STAMPF" 2>/dev/null && v=1 || v=0
expect "T29a ... and the stamp records the verdict, not just the date" "$v" 1
: > "$LOG"
out=$( PATH="$STUB:$PATH" SNYK_HOOK_MODE=block g hook run pre-commit 2>&1 ); rc=$?
ran=$(grep -c '^code test' "$LOG" 2>/dev/null)
expect "T29b same-day retry -> still blocked, and the metered test not re-spent" "$rc$ran" 10
saw   "T29c ... and says the standing verdict is why" "$out" "that verdict still stands"
rm -f "$STAMPF"; reset_tree

# A forced retry whose scan does not COMPLETE must not drop the saved failure.
# SNYK_CODE_FORCE=1 skips the re-assert above, so the verdict has to be seeded
# before the scan and only replaced by a completed one -- otherwise a capped or
# errored scan leaves FAIL at 0 and block mode passes a known finding.
printf '%s:fail\n' "$(date +%Y-%m-%d)" > "$STAMPF"
printf '#!/bin/sh\necho "$*" >> "%s"\ncase "$1" in code) exit 7 ;; esac\nexit 0\n' "$LOG" > "$STUB/snyk"
chmod +x "$STUB/snyk"
: > "$LOG"
printf 'export const f = 1\n' > "$T/f1.ts"; g add f1.ts
out=$( PATH="$STUB:$PATH" SNYK_CODE_FORCE=1 SNYK_HOOK_MODE=block g hook run pre-commit 2>&1 ); rc=$?
expect "T32 forced retry, scan errors -> today's saved failure still blocks" "$rc" 1
saw   "T32a ... and says the saved verdict is what held" "$out" "it stands unless this scan completes"
rm -f "$STAMPF"; reset_tree
# restore the always-clean stub for anything after this
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$LOG" > "$STUB/snyk"; chmod +x "$STUB/snyk"

# --- a chained repo-local hook runs under its OWN interpreter -------------
# Forcing `sh` broke every hook written for bash, node or python, which is most
# of them: Husky and the pre-commit framework both generate non-sh hooks, and
# preserving those is the entire reason chaining exists. node is already a hard
# requirement of this harness, so it is the portable discriminator -- a JS body
# runs under its shebang and is a syntax error under sh.
# The discriminator is the EXIT CODE, not a file. `chain_local_hook` propagates
# the local hook's status, so a node hook exiting 42 shows up as the whole
# hook's 42. Writing a marker file was the first attempt and it failed for a
# reason worth recording: a Git-Bash `/tmp` path handed to native Windows node
# is unwritable, so the hook ran correctly and the test reported otherwise.
# Nothing crosses that boundary now.
#
# T30a uses a SEPARATE, plain-sh fixture exiting 43 rather than reading a
# status out of the node one. Asserting what `sh` does with JS means asserting
# a shell's error convention: `process.exit(42);` is a syntax error, which is
# exit 2 here, not the 127 that "command not found" would give -- and that
# number is the shell's to change, not ours. A fixture that exits 43 on purpose
# says the same thing (the fallback RAN, rather than nothing happening) without
# depending on how any shell reports a parse failure.
LOCALHOOKS="$(g rev-parse --absolute-git-dir)/hooks"; mkdir -p "$LOCALHOOKS"
printf '#!/usr/bin/env node\nprocess.exit(42);\n' > "$LOCALHOOKS/pre-commit"
chmod +x "$LOCALHOOKS/pre-commit"
printf 'export const c = 1\n' > "$T/c1.ts"; g add c1.ts
rc=$( PATH="$STUB:$PATH" SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $? )
expect "T30 executable repo-local hook -> run via its shebang, not forced through sh" "$rc" 42
# Without the execute bit git could not run it either, so `sh` is the right
# fallback -- a Windows checkout cannot store the mode. 43 proves the fallback
# ran: direct execution of a non-executable file is 126. Skip rather than
# assert on a filesystem that will not clear the bit, where the two paths are
# indistinguishable.
printf '#!/bin/sh\nexit 43\n' > "$LOCALHOOKS/pre-commit"
chmod -x "$LOCALHOOKS/pre-commit" 2>/dev/null
if [ -x "$LOCALHOOKS/pre-commit" ]; then
  pass "T30a skipped: this filesystem will not clear the execute bit"
else
  rc=$( PATH="$STUB:$PATH" SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $? )
  expect "T30a non-executable repo-local hook -> still chained, via the sh fallback" "$rc" 43
fi
rm -rf "$LOCALHOOKS"; reset_tree

# Stub the Python side before the pip cases below, because those cases exist to
# prove that no package build happens -- so when one FAILS it must not perform
# the build in order to report it. Only `snyk` was stubbed, so with the `:-` bug
# restored T31b and T31c reached a real `python -m venv` and a real
# `pip install`, downloading and building packages on the developer's machine:
# the regression test doing the exact thing it forbids. `-m venv` here
# fabricates a venv whose interpreter is another stub, so the hook still takes
# its success path and the pip call is recorded instead of run.
# PYLOG is exported, and the stubs reference it at RUNTIME through a QUOTED
# heredoc. An unquoted heredoc bakes the path in at generation time, so a temp
# path containing a dollar sign would be re-expanded when the stub ran: the
# append would go nowhere, the stub would still exit 0, and no_py would read an
# empty log and report ok. Verified -- /tmp/has$dollar/pycalls bakes down to
# /tmp/has/pycalls. Quoting the heredoc removes the escaping problem outright
# rather than managing it.
export PYLOG="$STUB/pycalls"; : > "$PYLOG"
for _py in python python3; do
  cat > "$STUB/$_py" <<'PYSTUB'
#!/bin/sh
# A stub that cannot record is worse than no stub: the log reads empty and the
# assertion reports ok. Fail loudly rather than silently.
[ -n "$PYLOG" ] || { echo "PYSTUB-ERROR: PYLOG unset" >&2; exit 97; }
echo "$*" >> "$PYLOG" || { echo "PYSTUB-ERROR: cannot write PYLOG" >&2; exit 97; }
if [ "$1" = -m ] && [ "$2" = venv ] && [ -n "$3" ]; then
  mkdir -p "$3/bin" || exit 1
  printf '#!/bin/sh\n[ -n "$PYLOG" ] || { echo "PYSTUB-ERROR: PYLOG unset" >&2; exit 97; }\necho "venv-python $*" >> "$PYLOG" || { echo "PYSTUB-ERROR: cannot write PYLOG" >&2; exit 97; }\nexit 0\n' > "$3/bin/python"
  chmod +x "$3/bin/python"
fi
exit 0
PYSTUB
  chmod +x "$STUB/$_py"
done
no_py() { # no_py <label> <output> -- assert Python was not invoked at all
  n=$(wc -c < "$PYLOG" 2>/dev/null | tr -d ' ')
  # The call log is the primary detector, but an empty log is NOT sufficient on
  # its own, because it cannot tell "nothing ran" from "something ran that we
  # could not see". The hook invokes both `python -m venv` and `pip install`
  # with >/dev/null 2>&1, so the stub's PYSTUB-ERROR on stderr never reaches
  # this output; what surfaces instead is the hook's OWN fallback message,
  # because the stub's exit 97 makes the venv step fail. Those messages are
  # therefore positive evidence that Python was invoked. The old T31a assertion
  # already detected them and I dropped that signal when I replaced it -- the
  # replacement was right about the backwards shape and wrong to discard the
  # coverage. (Note the hook logs NOTHING on the
  # success path, so for a successful install the log is the only detector,
  # which is why both checks have to stay.)
  case "$2" in
    *PYSTUB-ERROR*|*"could not create a temp venv"*|*"pip install into a temp venv failed"*)
      fail "$1 (the hook reached its venv/pip fallback, so Python ran; an empty log proves nothing)"
      : > "$PYLOG"; return ;;
  esac
  if [ "${n:-0}" = 0 ]; then pass "$1"; else fail "$1 (ran: $(tr '\n' ';' < "$PYLOG"))"; fi
  : > "$PYLOG"
}

# --- pip install is opt-in -----------------------------------------------
# `pip install -r` BUILDS packages, and a source distribution's build runs
# arbitrary code as you. That must not be a side effect of `git commit`.
#
# The opt-in is isolated deliberately, because this case asserts the DEFAULT and
# the hook reads it from two places it does not own:
# `${SNYK_HOOK_PIP_INSTALL:-$(git config --get hook.snykPipInstall)}`. On the
# machine of a developer who has opted in -- exported env var, or the setting in
# their global config -- this case would attempt a real `pip install`, fail its
# own assertion, AND install packages as a side effect of running the suite. So
# unset the variable in a subshell and pin the setting to 0 in the throwaway
# repo, where local config beats global for `git config --get`.
g config hook.snykPipInstall 0
: > "$LOG"
printf 'requests==2.31.0\nurllib3==2.0.7\n' > "$T/requirements.txt"; g add requirements.txt
# SNYK_HOOK_OS_CAP is pinned in every case below. All three share one hook copy
# and therefore one monthly Open Source usage counter, which each run
# increments, and the hook reads `${SNYK_HOOK_OS_CAP:-180}`. So a low cap
# exported in the caller's environment -- or simply enough accumulated runs --
# would make a later case reach the cap and SKIP the manifest before the opt-in
# is ever read, reporting ok without having tested its subject.
out=$( unset SNYK_HOOK_PIP_INSTALL; PATH="$STUB:$PATH" SNYK_HOOK_OS_CAP=999 SNYK_HOOK_MODE=warn g hook run pre-commit 2>&1 )
saw "T31 changed requirements -> no pip install by default" "$out" "not installing it to test it"
# T31a used to assert that the output LACKED "pip install into a temp venv
# failed", which passes when the forbidden install SUCCEEDS: the name promised
# "no venv was attempted at all" while the code tested "no venv attempt
# failed". Assert on the recorded calls instead.
no_py "T31a ... and no venv or pip call was attempted at all" "$out"

# An EMPTY switch means off, and must not fall through to the git setting.
# `${VAR:-default}` substitutes on empty as well as unset, so with
# hook.snykPipInstall=1 the empty env var selected the enabled setting and ran
# the build -- contradicting both the documented precedence and the switch.
g config hook.snykPipInstall 1
# shellcheck disable=SC1007  # the EMPTY value is what this case asserts
out=$( SNYK_HOOK_PIP_INSTALL= PATH="$STUB:$PATH" SNYK_HOOK_OS_CAP=999 SNYK_HOOK_MODE=warn g hook run pre-commit 2>&1 )
saw "T31b empty switch beats an enabled git setting -> still no pip install" "$out" "not installing it to test it"
no_py "T31b ... and Python was never invoked" "$out"
g config hook.snykPipInstall 0

# A GLOBAL setting must not enable it either: the docs promise a PER-REPOSITORY
# opt-in, and plain `git config --get` reads local, then global, then system, so
# one global `hook.snykPipInstall=1` would have run package builds in every
# repo on the machine. GIT_CONFIG_GLOBAL points git at a throwaway file, so this
# case can prove the scoping without touching the developer's real ~/.gitconfig.
g config --unset hook.snykPipInstall 2>/dev/null
printf '[hook]
	snykPipInstall = 1
' > "$STUB/fakeglobal"
out=$( unset SNYK_HOOK_PIP_INSTALL; GIT_CONFIG_GLOBAL="$STUB/fakeglobal" PATH="$STUB:$PATH" SNYK_HOOK_OS_CAP=999 SNYK_HOOK_MODE=warn g hook run pre-commit 2>&1 )
saw "T31c a global setting does not enable it -> still no pip install" "$out" "not installing it to test it"
no_py "T31c ... and Python was never invoked" "$out"
g config hook.snykPipInstall 0
reset_tree
g config core.hooksPath "$HERE"; rm -rf "$HK" "$STUB"

# --- T33: staged files git cannot render as text --------------------------
# `git diff --cached` emits "Binary files ... differ" rather than a patch when
# an attribute or a textconv driver suppresses the diff, gitleaks skips it, and
# before 2026-11-02 the gate PASSED on a planted token (22 bytes scanned, "no
# leaks found", exit 0). `--log-opts=--text` does not fix it -- --pre-commit
# mode ignores log options -- so the hook asks `--numstat` which paths git
# could not render and scans those directly.
reset_tree
attrtok="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
mkdir -p "$T/notes"
printf 'notes/deploy.md -diff\n' > "$T/.gitattributes"
printf 'token = "%s"\n' "$attrtok" > "$T/notes/deploy.md"
g add .gitattributes notes/deploy.md
out=$(SNYK_HOOK_MODE=off g hook run pre-commit 2>&1); rc=$?
expect "T33 secret behind a \`-diff\` attribute -> blocked" "$rc" 1

# T33 alone could pass for the wrong reason -- any block satisfies it. This
# names the code path, so a regression that removes the guard but blocks for
# some other reason cannot be mistaken for coverage.
saw "T33a ... and the guard is what caught it" "$out" "could not render"

# No environment variable passes a FOUND secret. The guard shares
# gitleaks_degraded() for scan and export errors, so this proves a finding does
# not take that lenient path by accident.
rc=$(GITLEAKS_DEGRADED_OK=1 SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
expect "T33b same, with GITLEAKS_DEGRADED_OK=1 -> still blocked" "$rc" 1

# The guard must not block a clean file just because its diff is suppressed, or
# a `binary` attribute in a real .gitattributes would fail every commit.
reset_tree
mkdir -p "$T/notes"
printf 'notes/deploy.md -diff\n' > "$T/.gitattributes"
printf 'nothing secret here\n' > "$T/notes/deploy.md"
g add .gitattributes notes/deploy.md
rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
expect "T33c clean stage with a \`-diff\` attribute -> passes" "$rc" 0

# The attribute already committed, the secret added later -- the likelier
# accident than staging both together as T33 does.
reset_tree
printf 'notes/deploy.md -diff\n' > "$T/.gitattributes"
mkdir -p "$T/notes"; printf 'clean\n' > "$T/notes/deploy.md"
g add .gitattributes notes/deploy.md
SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1
g commit -q -m "attribute first" --no-verify
printf 'token = "%s"\n' "$attrtok" > "$T/notes/deploy.md"
g add notes/deploy.md
rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
expect "T33d attribute already committed, secret added later -> blocked" "$rc" 1

# T33e is the reason this guard is numstat-based rather than attribute-based,
# and it is a regression test for a real escape (found in review).
# `git diff --cached` resolves attributes from the WORKING TREE while
# `git check-attr --cached` reads the INDEX. With `-diff` edited into
# .gitattributes but NOT staged, the two disagree: the diff suppresses the file
# while the index says `unspecified`. The first version of this guard asked the
# index and skipped the file, so NEITHER scan read the token and the hook
# exited 0. Asking `--numstat` asks what git actually did, so both agree again.
reset_tree
printf '* text=auto\n' > "$T/.gitattributes"
mkdir -p "$T/notes"; printf 'clean\n' > "$T/notes/deploy.md"
g add .gitattributes notes/deploy.md
SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1
g commit -q -m "attrs without -diff" --no-verify
printf '* text=auto\nnotes/deploy.md -diff\n' > "$T/.gitattributes"   # NOT staged
printf 'token = "%s"\n' "$attrtok" > "$T/notes/deploy.md"
g add notes/deploy.md                                                 # only the secret
out=$(SNYK_HOOK_MODE=off g hook run pre-commit 2>&1); rc=$?
expect "T33e \`-diff\` in the worktree but UNSTAGED -> blocked" "$rc" 1
saw "T33e1 ... and it was the render check, not the attribute check" "$out" "could not render"

# T33f: the path list must stay NUL-separated. Converting it to newlines splits
# a filename CONTAINING a newline into nonexistent paths; `git checkout-index`
# then fails, and a scan of the empty directory reports clean -- a fail-open
# the first version had (found in review). Skipped where the filesystem
# refuses such a name, so the case cannot pass by not running.
reset_tree
nlname=$(printf 'notes/a\nb.md')
mkdir -p "$T/notes"
if printf 'token = "%s"\n' "$attrtok" > "$T/$nlname" 2>/dev/null && [ -f "$T/$nlname" ]; then
  printf '* -diff\n' > "$T/.gitattributes"
  g add -A
  rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
  expect "T33f secret in a filename containing a newline -> blocked" "$rc" 1
else
  pass "T33f skipped: this filesystem will not create a newline filename"
fi

# T33g: `binary` is `-diff -merge -text`, so an attribute alone -- on a file
# whose CONTENT is ordinary text -- must still be read.
reset_tree
mkdir -p "$T/notes"
printf 'notes/deploy.md binary\n' > "$T/.gitattributes"
printf 'token = "%s"\n' "$attrtok" > "$T/notes/deploy.md"
g add .gitattributes notes/deploy.md
rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
expect "T33g secret behind a \`binary\` attribute -> blocked" "$rc" 1

# T33h: a secret inside genuinely BINARY content. gitleaks will not read a file
# it has judged binary, in any mode -- measured 2026-11-02, `gitleaks dir`
# scanned 0 bytes of a 53-byte file holding a plaintext token after two NUL
# bytes, and passed. So a clean `gitleaks dir` is not proof the bytes were
# read. The bytes are scannable though: `tr -d '\0' | gitleaks stdin` read 52
# of them and found the token, so the guard runs that as a second pass rather
# than blocking every binary commit. This case asserted a PASS until
# 2026-11-02, when that pass was closed.
reset_tree
mkdir -p "$T/notes"
{ printf 'BIN'; printf '\000\001'; printf 'token = "%s"\n' "$attrtok"; } > "$T/notes/blob.bin"
g add notes/blob.bin
rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
expect "T33h secret in REAL binary content -> blocked by the NUL-stripped pass" "$rc" 1

# ...and a clean binary must still commit without an override, which is the
# whole reason the binary pass exists instead of blocking binaries outright.
reset_tree
mkdir -p "$T/notes"
{ printf 'BIN'; printf '\000\001\002'; printf 'nothing secret here\n'; } > "$T/notes/blob.bin"
g add notes/blob.bin
rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
expect "T33h1 clean binary -> passes, no override needed" "$rc" 0
reset_tree

# T33j: an empty "files git cannot diff" list must MEAN nothing to scan. When
# the detection itself fails the list is ALSO empty, and inferring "nothing to
# do" from that passed a secret the normal scan had not read either
# (found in review).
#
# This case stubs the PARSER, because that is the failure that actually
# happened. The first version parsed the NUL-separated list with
# `awk 'BEGIN{RS="\0"}'`, a GNU awk extension: it worked on a machine with GNU
# Awk 5.0.0 and mis-parsed under mawk, Ubuntu's default, which reads "\0" as
# the empty string. The githooks workflow caught it on its first CI run -- the
# mis-parse produced a bogus path whose export failed, and the degraded path
# then blocked every commit. So the hook now proves its parser works before
# trusting it, and a parser that cannot do the job must BLOCK rather than
# quietly read nothing. A stub `sed` that always fails stands in for any such
# sed; the gitleaks section runs first, so nothing else reaches this stub.
reset_tree
SEDSTUB=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$SEDSTUB/sed"; chmod +x "$SEDSTUB/sed"
mkdir -p "$T/notes"
printf 'notes/deploy.md -diff\n' > "$T/.gitattributes"
printf 'token = "%s"\n' "$attrtok" > "$T/notes/deploy.md"
g add .gitattributes notes/deploy.md
out=$( PATH="$SEDSTUB:$PATH" SNYK_HOOK_MODE=off g hook run pre-commit 2>&1 ); rc=$?
expect "T33j a parser that cannot read NUL records -> blocked, not read as nothing to scan" "$rc" 1
saw "T33j1 ... and it names the parser, not a finding" "$out" "cannot read NUL-separated records"
# The degraded override still applies to a broken SCAN, as everywhere else --
# and never to a finding (T33b).
rc=$( PATH="$SEDSTUB:$PATH" GITLEAKS_DEGRADED_OK=1 SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $? )
expect "T33j2 ... and GITLEAKS_DEGRADED_OK=1 passes that (a scan error, not a finding)" "$rc" 0
rm -rf "$SEDSTUB"
reset_tree

# T33i: a TYPE change -- a symlink replaced by a regular file -- is `T` in
# --diff-filter, and the first numstat version listed only ACMR. With the diff
# suppressed the file then skipped BOTH scans. Measured before the fix:
# name-status T, ACMR returned nothing, the token was absent from the staged
# diff, hook exit 0 (found in review). Staged through update-index so the
# case does not depend on this filesystem supporting symlinks, and it FAILS
# rather than skips if the setup did not actually produce a type change.
reset_tree
mkdir -p "$T/notes"
printf 'some/target\n' > "$T/tgt"
tlink=$( cd "$T" && git hash-object -w tgt )
g update-index --add --cacheinfo 120000,"$tlink",notes/deploy.md
printf '* text=auto\n' > "$T/.gitattributes"
g add .gitattributes
SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1
g commit -q -m "symlink committed" --no-verify
printf 'token = "%s"\n' "$attrtok" > "$T/notes/deploy.md"
tblob=$( cd "$T" && git hash-object -w notes/deploy.md )
g update-index --cacheinfo 100644,"$tblob",notes/deploy.md
printf '* text=auto\nnotes/deploy.md -diff\n' > "$T/.gitattributes"
g add .gitattributes
tstat=$(g diff --cached --name-status -- notes/deploy.md | cut -f1)
if [ "$tstat" = "T" ]; then
  rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
  expect "T33i type change + suppressed diff -> blocked" "$rc" 1
else
  fail "T33i unrunnable: staged '$tstat', not a type change"
fi
reset_tree

# T33k is T33i's mirror, and it is about a FALSE BLOCK rather than a miss. A
# committed regular file staged AS a symlink is also a type change, so it is
# selected here -- but `checkout-index` exports a symlink, and `find -type f`
# does not count one, so the exported count came up short of the requested
# count and the "some are unscanned" path blocked a legitimate commit. A secret
# gate that blocks ordinary work gets switched off, so this matters as much as
# the misses.
#
# Staged through update-index like T33i, not with a real `ln -s`: whether
# `git add` records a symlink as mode 120000 depends on the filesystem and on
# core.symlinks, and an earlier version of this case silently staged a plain
# modification instead of a type change. Constructing the index entry directly
# makes the case deterministic everywhere. The path is unique to this case:
# earlier cases commit notes/deploy.md AS a symlink, so reusing it left
# HEAD already at mode 120000 and there was no type change left to stage.
reset_tree
mkdir -p "$T/notes"
printf '* text=auto
' > "$T/.gitattributes"
printf 'regular content
' > "$T/notes/k33file.md"
g add .gitattributes notes/k33file.md
SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1
g commit -q -m "regular file committed" --no-verify
printf '../some/target
' > "$T/linktarget"
klink=$( cd "$T" && git hash-object -w linktarget )
g update-index --cacheinfo 120000,"$klink",notes/k33file.md
printf '* text=auto
notes/k33file.md -diff
' > "$T/.gitattributes"
g add .gitattributes
ktype=$(g diff --cached --name-status -- notes/k33file.md | cut -f1)
if [ "$ktype" = "T" ]; then
  rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
  expect "T33k regular file staged as a symlink -> passes, not a false block" "$rc" 0
else
  fail "T33k unrunnable: staged '$ktype', not a type change"
fi
reset_tree

# T33m: the cleanup trap must never remove a directory the hook did not create.
# BINDIR is assigned deep inside the "there are unrenderable files" branch, so
# on an ordinary text-only commit that assignment never runs -- and
# `${BINDIR:-}` guards against UNSET, not against INHERITED. With BINDIR
# exported by the caller the EXIT trap `rm -rf`'d it and the commit still
# exited 0: silent data loss, from the one hook whose entire job is to be
# careful, on the successful path. Reproduced before the fix (victim directory
# present, then GONE). Found in review, on code two other reviewers had
# already passed -- a destructive action on the happy
# path is not the kind of thing a diff reads as wrong.
reset_tree
victim=$(mktemp -d)
printf 'do not delete\n' > "$victim/keep.txt"
printf 'hello\n' > "$T/ok.txt"
g add ok.txt
rc=$( BINDIR="$victim" SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $? )
expect "T33m clean commit with BINDIR exported -> passes" "$rc" 0
if [ -d "$victim" ] && [ -f "$victim/keep.txt" ]; then
  pass "T33m1 ... and the inherited directory is untouched"
else
  fail "T33m1 the hook deleted a directory it never created"
fi
rm -rf "$victim"

# ...and the same must hold on the BLOCKING path, where the trap also fires.
# Its own path, for the reason in the header: reusing notes/deploy.md left
# nothing unrenderable to stage and the case passed vacuously.
reset_tree
victim2=$(mktemp -d)
printf 'do not delete\n' > "$victim2/keep.txt"
mkdir -p "$T/notes"
printf 'notes/m33file.md -diff\n' > "$T/.gitattributes"
printf 'token = "%s"\n' "$attrtok" > "$T/notes/m33file.md"
g add .gitattributes notes/m33file.md
rc=$( BINDIR="$victim2" SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $? )
expect "T33m2 blocked commit with BINDIR exported -> still blocked" "$rc" 1
if [ -d "$victim2" ] && [ -f "$victim2/keep.txt" ]; then
  pass "T33m3 ... and the inherited directory is still untouched"
else
  fail "T33m3 the hook deleted a directory it never created"
fi
rm -rf "$victim2"
reset_tree

# T33p: a smudge filter must not be able to hide the staged bytes. The guard
# used to materialise files with `git checkout-index`, which applies checkout
# conversions -- smudge filters among them -- so it could read transformed,
# secret-free bytes while the blob that actually gets committed kept the
# secret. Measured before the fix: checkout-index wrote "token = REDACTED" and
# gitleaks passed it, while the staged blob held the real token. It now reads
# the blob with `git cat-file blob`. A local filter definition is needed to set
# this up (.git/config, not the repo, so a PR cannot enable it alone), but
# git-lfs, git-crypt and templating setups all configure one.
reset_tree
mkdir -p "$T/notes"
g config filter.hide.smudge 'sed s/ghp_[A-Za-z0-9]*/REDACTED/'
g config filter.hide.clean cat
printf 'notes/p33file.md filter=hide -diff\n' > "$T/.gitattributes"
printf 'token = %s\n' "$attrtok" > "$T/notes/p33file.md"
g add .gitattributes notes/p33file.md
out=$(SNYK_HOOK_MODE=off g hook run pre-commit 2>&1); rc=$?
expect "T33p a smudge filter cannot hide the staged bytes -> blocked" "$rc" 1
# ...and assert it was a FINDING, not a degraded scan. T33p blocked under a
# mutation that merely broke the blob read -- the degraded path blocks too, so
# the exit code alone cannot tell "we read the real bytes and found the secret"
# from "we could not read anything". That distinction is the whole point here.
saw "T33p1 ... and as a finding, not a degraded scan" "$out" "found a secret"
g config --unset filter.hide.smudge
g config --unset filter.hide.clean
reset_tree

# T33q and T33r are a MATCHED PAIR, and each exists to stop the other's NUL
# representation being deleted as redundant. The supplemental scan reads the
# staged bytes in two forms because each hides what the other catches:
#   boundary IS a NUL byte   NUL-stripped -> MISSED      NUL-to-newline -> found
#   NULs inside the token    NUL-stripped -> found       NUL-to-newline -> MISSED
# Both fixtures use an `npm_` token because that rule requires a leading word
# boundary -- `ghp_` does not, and would pass either way, which is how the
# boundary class went unnoticed in the first place. No .gitattributes needed:
# a NUL in the content is enough for git to report the file as unrenderable.
reset_tree
nputok="npm_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
printf 'pad data abc\000%s\n' "$nputok" > "$T/q33.bin"
g add q33.bin
rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
expect "T33q token whose leading boundary is a NUL byte -> blocked" "$rc" 1
reset_tree

printf 'n\000p\000m\000_' > "$T/r33.bin"
printf '%s' "${nputok#npm_}" | sed 's/./&\x00/g' >> "$T/r33.bin"
printf '\n' >> "$T/r33.bin"
g add r33.bin
rc=$(SNYK_HOOK_MODE=off g hook run pre-commit >/dev/null 2>&1; echo $?)
expect "T33r token with NULs interleaved through it -> blocked" "$rc" 1
reset_tree

# T33s: the blob lookup must treat the staged name as a LITERAL path. A bare
# "$1" is a pathspec, so glob characters in a filename select other files --
# and the OID that comes back is then the wrong file. Measured before the fix:
# looking up [A].bin matched 2 entries and head -1 returned the OID of A.bin,
# the clean one, while the secret in [A].bin went unread; the hook exited 0.
# Both files are staged binary here so each reaches the supplemental scan, and
# A.bin sorts first (0x41) while [A].bin sorts after it (0x5B), which is what
# makes head -1 pick the wrong one. Deterministic: each path is looked up on
# its own, so there is no directory ordering involved.
reset_tree
stok="npm_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
printf 'CLEAN harmless\000\n' > "$T/A.bin"
printf '%s\000\n' "$stok" > "$T/[A].bin"
g add -A
if [ "$(g ls-files -- ':(literal)[A].bin' | wc -l)" = 1 ]; then
  out=$(SNYK_HOOK_MODE=off g hook run pre-commit 2>&1); rc=$?
  expect "T33s secret in a glob-named file -> blocked" "$rc" 1
  saw "T33s1 ... and as a finding, not a degraded scan" "$out" "found a secret"
else
  fail "T33s unrunnable: this filesystem did not stage a file named [A].bin"
fi
reset_tree

[ "$FAIL" -eq 0 ] && echo "all cases pass" || echo "FAILURES above"
exit "$FAIL"
