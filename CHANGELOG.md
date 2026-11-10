# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
