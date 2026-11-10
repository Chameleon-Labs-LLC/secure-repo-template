# Security setup

This is the setup we use on our own repositories, in the order we'd add it. Each step says what it does, what it costs, where it works, and how to undo it.

**Supported:** Linux, WSL, and Git Bash on Windows. macOS is not supported yet (the hooks use GNU `sed -z`, `sed -i` and `xargs -r`).

| Step | Cost |
|---|---|
| 1. Start from the template | Free |
| 2. Pre-commit hook (gitleaks) | Free |
| 3. CI security workflow | Free |
| 4. Dependabot | Free |
| 5. Minimum package age | Free |
| 6. AI pull-request reviewers | CodeRabbit free for public repos; Greptile paid |
| 7. Snyk (optional) | Free plan with monthly limits; paid above that |
| 8. Never `pull_request_target` | Free |
| 9. For AI coding agents | Free |

Prices change. Check each vendor's pricing page before you rely on a number here.

## 1. Start from the template

**New repo:** on the template's GitHub page, click **Use this template → Create a new repository**.

**Existing repo:** copy these paths into it: `githooks/`, `.github/workflows/security.yml`, `.github/workflows/githooks.yml`, `.github/dependabot.yml`, `.npmrc`, `.gitattributes`, `.gitleaksignore`, and, if you'll use them, `.coderabbit.yaml` and `.greptile/config.json`. If you already have a `.nvmrc`, keep yours; the workflows read it. Merge `.gitignore` by hand.

A template copies **files only**. Repository settings, rulesets and installed apps do not come along. Steps 3, 4 and 6 cover the ones that matter.

**Undo:** delete the files.

## 2. Pre-commit hook: gitleaks, fails closed

`githooks/pre-commit` scans every commit's staged changes with [gitleaks](https://github.com/gitleaks/gitleaks) before the commit is made. CI scans too, but only after a push, when the secret is already in history. The hook is the only gate that stops it first.

It **fails closed**:

- A found secret blocks the commit. No environment variable passes a finding.
- A missing `gitleaks`, or a scan that errors, also blocks. An unscanned commit is not a clean commit.
- It also scans the staged bytes of files git cannot show as a text diff (binary files, or files marked `-diff` in `.gitattributes`), which a plain `gitleaks --staged` run skips.

**Install gitleaks.**

Linux and WSL, from the checksum-verified release (no `sudo` needed; the hook also looks in `~/.local/bin`):

```bash
V=8.30.1
B="https://github.com/gitleaks/gitleaks/releases/download/v${V}"
curl -fsSLO "${B}/gitleaks_${V}_linux_x64.tar.gz"
curl -fsSLO "${B}/gitleaks_${V}_checksums.txt"
grep " gitleaks_${V}_linux_x64.tar.gz$" "gitleaks_${V}_checksums.txt" | sha256sum -c -
mkdir -p ~/.local/bin && tar -xzf "gitleaks_${V}_linux_x64.tar.gz" -C ~/.local/bin gitleaks
```

Git Bash on Windows (then open a new Git Bash window):

```bash
winget install --id Gitleaks.Gitleaks --scope user
```

**Install the hooks.** Pick one.

For this repository only (points its `core.hooksPath` at `githooks/`; edits to the hooks apply at once):

```bash
sh githooks/install.sh --repo
```

For every repository on this machine (copies the hooks to `~/.githooks` and sets the global `core.hooksPath`; re-run after you change a hook). Set `GITHUB_ROOT=<dir>` to install to `<dir>/.githooks` instead:

```bash
sh githooks/install.sh
```

WSL and Git Bash each have their own git and global config, so run the global install once in each one you commit from. If a global `core.hooksPath` is already set, the installer stops and prints it; add `--force` to replace it.

Two things to know:

- The hooks run a repo's own `.git/hooks/<name>` after their own checks, so existing local hooks keep working.
- A repo with its **own** `core.hooksPath` (Husky sets one) overrides the global setting, and these hooks do not run there. `git config --local --get core.hooksPath` shows it.

**When it blocks you.**

| Situation | What to do |
|---|---|
| A real secret | Remove it from the staged change. If it was ever pushed anywhere, rotate it. |
| A false positive | Add a `gitleaks:allow` comment on the line, or add the fingerprint gitleaks prints to `.gitleaksignore`. CI ignores `gitleaks:allow`, and on a pull request it uses the base branch's `.gitleaksignore`, so merge the `.gitleaksignore` entry first, in its own PR. |
| gitleaks missing or broken | Fix the install. For one commit only, `GITLEAKS_DEGRADED_OK=1 git commit ...` passes a scan that could not run (never a found secret). Say why in the commit message. |

`git commit --no-verify` skips every hook. Treat needing it as a problem to fix, not a habit.

**Test the hook** (needs `git` 2.36+, `node` and `gitleaks`; spends no Snyk quota):

```bash
sh githooks/test-pre-commit.sh
```

**Undo:** `sh githooks/install.sh --uninstall --repo` or `sh githooks/install.sh --uninstall`.

## 3. CI security workflow

`.github/workflows/security.yml` runs on every pull request, every push to `main`, weekly on a timer (new advisories land against code that hasn't changed), and on demand.

| Job | What it checks |
|---|---|
| `gitleaks` | Secrets in the commits the event introduced; full history on the timer. Includes merge commits and files marked `-diff`. |
| `osv-scanner` | Known vulnerabilities in every lockfile and manifest, **and** in the GitHub Actions your workflows use. |
| `npm audit` | High and critical advisories in `package-lock.json`. |
| `npm audit signatures` | Every installed npm package has a valid registry signature. |

The two npm jobs skip, with a notice, when there is no `package-lock.json` at the repo root.

How it's hardened:

- Actions are pinned to commit SHAs, not tags. A tag can be moved to different code; a SHA cannot.
- Scanner binaries are downloaded at a pinned version and checked against the release's checksums.
- The token is read-only, and checkout does not keep credentials.
- A pull request cannot suppress its own findings: gitleaks ignores `gitleaks:allow` comments and uses the base branch's suppression files, and osv-scanner reads an empty config from outside the checkout.
- A scanner error fails the job with a message that says it's an error, so an outage never looks like a clean scan.

`.github/workflows/githooks.yml` runs the hook's test suite and shellcheck on every change.

**Make the checks required.** A workflow that fails but does not block a merge is only a warning. In **Settings → Rules → Rulesets → New branch ruleset**, target the default branch, turn on **Require a pull request before merging** and **Require status checks to pass**, and add `gitleaks`, `osv-scanner`, `npm audit`, `npm audit signatures`, `hook test suite` and `shellcheck`. A check that has never run in the repo won't appear in the list until it has run once.

**Undo:** delete the workflow files, and remove the checks from the ruleset first.

## 4. Dependabot

`.github/dependabot.yml` keeps dependencies current:

- Security updates are grouped into one PR per ecosystem.
- Version updates run weekly, minor and patch only, grouped. Majors are left for you to do by hand with the changelog read. That `ignore` applies to version updates only; a security fix in a new major still arrives.
- A 7-day `cooldown` before Dependabot proposes a new version, matching step 5. Security updates are not delayed.
- GitHub Actions is on. The npm and pip blocks are written but commented out; uncomment the ones your project uses and set `directory`.

Turn on the two settings a config file can't: **Settings → Advanced Security** (called **Code security** on some accounts) → **Dependabot alerts** and **Dependabot security updates**.

Two habits that matter more than the config:

- **"No PR" never means "no vulnerability."** Transitive dependencies in some lockfiles and advisories with no fixed version show up only as alerts. Read the alerts, not just the PRs.
- **Take the lowest fixed version.** Dependabot proposes the newest release; the advisory names the first one that's fixed. The lower one fixes the hole without bringing in unrelated changes.

**Undo:** delete the file and turn the settings off.

## 5. Minimum package age

`.npmrc` sets `min-release-age=7`, so `npm install` refuses any package version published in the last 7 days. Most malicious releases are found and pulled within days, and a week's wait avoids most of them. It needs npm 11.10 or later; older npm warns and ignores it. `npm ci` installs the lockfile as written and is unaffected.

**When a security fix overrides it:** if a vulnerability is reported and the fix is younger than 7 days, apply the fix now. Waiting is not safer than a known hole.

```bash
npm install <package>@<fixed-version> --min-release-age=0
```

**Undo:** delete the line from `.npmrc`.

## 6. AI pull-request reviewers

Two reviewers, because each catches different kinds of mistakes. Both are GitHub Apps you install yourself; the config files in this template only tune them.

**[CodeRabbit](https://www.coderabbit.ai/)** (`.coderabbit.yaml`). Free for public repositories; paid for private ones.

- `profile: chill`, so it reports real problems without nitpicking style.
- Re-reviews every push (`auto_incremental_review: true` **and** `auto_pause_after_reviewed_commits: 0`; without the second it stops after five pushes).
- On Markdown it reports only contradictions between files, claims nothing enforces, and steps that can't be followed. No rewording.
- Skips drafts and Dependabot PRs.

**[Greptile](https://www.greptile.com/)** (`.greptile/config.json`). Paid, billed per review.

- `effort: base` holds every review to the cheapest tier.
- Reviews when a PR **opens**, not on every push. After you push more commits, trigger a fresh review from Greptile if those commits matter.
- Skips drafts and bot authors.

Things that are easy to get wrong:

- **A green check doesn't mean "no findings."** Both post findings as inline comments. Read the comments.
- **A green check doesn't always mean it reviewed.** A rate-limited or skipped CodeRabbit review also passes. The check's title says `Finished` only when it actually reviewed.
- **Skip both on one PR** with the `no-ai-review` label. It must be on the PR when it opens (`gh pr create --label no-ai-review`), and the label has to exist in the repo first:

  ```bash
  gh label create no-ai-review -c ededed -d "Skip all automated AI code review on this PR" --force
  ```

**Undo:** uninstall the app and delete its config file.

## 7. Snyk (optional, metered)

[Snyk](https://snyk.io/) adds a second opinion on dependencies (`snyk test`) and on your own code (`snyk code test`). The free plan has monthly test limits.

Before opening a PR, run `snyk test` if the PR changes dependencies and `snyk code test` if it changes source code.

If the `snyk` CLI is installed and signed in (`snyk auth`), the pre-commit hook runs it for you, carefully:

- A dependency test runs only when a manifest's dependencies or its lockfile actually changed. A version bump in `package.json` doesn't count.
- A code test runs at most once per repo per day, and only when source files are staged.
- Soft monthly caps stop it before your plan's limit.
- It never runs `pip install` unless you opt in, because installing a package can run that package's build code.

| Variable | Effect |
|---|---|
| `SNYK_HOOK_MODE` | `warn` (default): report only. `block`: also block on findings that have a fix. `off`: skip Snyk; gitleaks still runs. |
| `SNYK_HOOK_SEVERITY` | Lowest severity reported (default `high`). |
| `SNYK_ORG` | Snyk org to test in (default: the CLI's default org). |
| `SNYK_HOOK_OS_CAP`, `SNYK_HOOK_CODE_CAP` | Monthly soft caps (default 180 and 90). Set them below your plan's limits. |
| `SNYK_SKIP=1` | Skip Snyk for one commit. gitleaks still runs. |
| `SNYK_CODE_FORCE=1` | Run the code test now, even if it already ran today. |
| `SNYK_HOOK_PIP_INSTALL=1` | Opt in to installing Python requirements in a temporary venv for a more accurate test. Per repo: `git config --local hook.snykPipInstall 1`. |

Every switch turns on only with the exact value `1`.

**Undo:** uninstall the CLI, or set `SNYK_HOOK_MODE=off`.

## 8. Never `pull_request_target`

Every workflow here uses the `pull_request` trigger. Never use `pull_request_target`.

`pull_request_target` runs in the context of the **base** repository, with a write token and access to its secrets, and it's often paired with a checkout of the pull request's code. A stranger's fork can then run their code with your secrets. Many real supply-chain compromises of GitHub Actions started this way.

If a workflow really does need secrets to act on a fork's pull request (posting a comment, say), split it in two: a `pull_request` workflow that builds an artifact with no secrets, and a `workflow_run` workflow that reads the artifact and uses the secrets, without ever checking out the pull request's code.

## 9. For AI coding agents

If AI coding agents work in your repo, give them the rules in writing. `AGENTS.md` is read by most agent tools; this template's version points at this guide and lists the rules an agent must not break (no `--no-verify`, no suppressions to make a check pass, no `pull_request_target`).

Our agent configuration and plugins are open source too. They're listed at [chameleonlabs.ai/open-source](https://chameleonlabs.ai/open-source).
