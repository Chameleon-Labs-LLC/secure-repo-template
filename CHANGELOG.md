# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-11-20

- Automatic merge commits and `git am` now run the same fail-closed gitleaks scan as `git commit`.
- `push-to-checkout` no longer leaves the receiving worktree behind with `updateInstead`; disabled (non-executable) local hooks stay disabled on Linux and WSL; `applypatch-msg` delegating to `commit-msg` works again.
- Snyk hook fixes: type changes count as staged source, interpreter paths with spaces, and a failed Snyk Code verdict survives an "unsupported project" retry.
- Docs: one `--no-verify` rule for agents, accurate coverage claims, runnable shellcheck command.

## [0.1.1] - 2026-11-14

- New agent guide (`docs/agent-guide.md`) for applying and running this setup with an AI coding agent.
- The setup guide now explains what the setup protects against, what each part costs (prices as of 2026-11-14), and how to run it at zero cost.

### Changed
- The action-advisory step reports an exhausted `GITHUB_TOKEN` rate limit (HTTP 403 or 429 with no quota left) with its own message instead of a generic HTTP error. The check still fails. Raised by CodeRabbit on lelandg/command-center#5.
- `npm audit signatures` retries when the registry answers without a signing key (`EMISSINGSIGNATUREKEY`): up to 3 attempts, 15 s apart, with `--prefer-online` on the retries. Any other failure, including an invalid signature, fails on the first attempt. Ported from ChameleonLabs #465.

### Fixed
- The full-history gitleaks scan (weekly timer, manual runs, new branches and force-push fallbacks) now includes type changes. It used gitleaks' default `--diff-filter=tuxdb`, where the lowercase `t` excludes them, so a secret in a file that replaced a symlink was never scanned. The filter is now `uxdb`.

## [0.1.0] - 2026-11-09

### Added
- Pre-commit hook (`Scripts/githooks/`) that runs gitleaks on staged changes and fails closed: a found secret, a missing scanner or an errored scan blocks the commit. Optional Snyk checks: Snyk Open Source runs only when dependencies change, and Snyk Code at most once a day per repo, when source files are staged.
- `install.sh` for a global install (`~/.githooks`, or `GITHUB_ROOT`) or a per-repo one, with uninstall. It will not replace another tool's hooks setup without `--force`.
- CI security workflow: gitleaks, osv-scanner (including GitHub Actions and `pyproject.toml` dependencies), `npm audit` and `npm audit signatures`. A pull request's own suppression files and `.npmrc` are not used.
- CI workflow for the hook test suite and shellcheck.
- Dependabot with grouped updates and a 7-day cooldown, `.npmrc` minimum package age, CodeRabbit and Greptile configs.
- README, SECURITY, CONTRIBUTING, AGENTS.md and a step-by-step security setup guide. Supported: Linux, WSL and Git Bash.

## [0.0.1] - 2026-11-09

### Changed
- Address CodeRabbit review on #1
- Download scanners outside the checkout; scan pyproject.toml dependencies
- Close the gaps found in review: suppression symlinks, npm coverage, installer ownership
- Move hooks to Scripts/githooks to match the published setup guide
- Add the security setup: hooks, CI scans, Dependabot, reviewer configs, docs
- Initial commit: MIT license and README stub
