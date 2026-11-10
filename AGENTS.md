# AGENTS.md

Guide for AI coding agents working in this repository. Replace the project section with your own; keep the security rules.

## Project

A repository template. Its content is security configuration: git hooks (`Scripts/githooks/`), CI workflows (`.github/workflows/`), Dependabot, and reviewer configs. There is no application code.

## Security rules

- How the setup works, and why: `docs/security-setup.md`. Read it before changing `Scripts/githooks/`, `.github/`, `.npmrc`, `.coderabbit.yaml` or `.greptile/config.json`.
- Never commit secrets. Keep them in a gitignored `.env` file and commit an `.env.example` with placeholders.
- Never use `git commit --no-verify` or `GITLEAKS_DEGRADED_OK=1` without telling the human why.
- Never add a suppression (`.gitleaksignore` entry, `gitleaks:allow` comment, osv-scanner ignore, `.snyk` ignore) to make a check pass. Report the finding instead.
- Never use the `pull_request_target` trigger. Pin every action to a full commit SHA.
- When a vulnerability with a fixed version is reported, apply the lowest version that fixes it, even if that version is newer than the 7-day package-age floor.

## Checks

- Hook changes: `sh Scripts/githooks/test-pre-commit.sh`, then `shellcheck -s sh -x --severity=warning` on the changed scripts.
- The hooks must stay POSIX `sh`, and work on Linux, WSL and Git Bash.
