# Contributing

Thanks for helping. Code, bug reports and ideas are all welcome.

## Reporting a bug or asking for a feature

Open an issue. Say what you expected, what happened, and how to reproduce it. For anything security-related, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Install gitleaks and the hooks ([docs/security-setup.md, step 2](docs/security-setup.md#2-pre-commit-hook-gitleaks-fails-closed)):

   ```bash
   sh githooks/install.sh --repo
   ```

3. Make your change. Keep each pull request to one topic.
4. If you changed anything under `githooks/`, run the test suite and shellcheck:

   ```bash
   sh githooks/test-pre-commit.sh
   ```

   ```bash
   shellcheck -s sh -x --severity=warning githooks/_lib.sh githooks/install.sh githooks/pre-commit githooks/test-pre-commit.sh
   ```

5. Open a pull request against `main` and describe what changed and why.

CI runs the security scans, the hook tests and shellcheck on every pull request. AI reviewers may leave comments as well; a maintainer reads every PR before it merges.

## Ground rules

- Never commit a secret, even a test one that looks real. The pre-commit hook will stop most, not all.
- Don't use `git commit --no-verify`, and don't add a `.gitleaksignore` entry or `gitleaks:allow` comment just to get past a check. If you think a finding is a false positive, say so in the PR.
- Pin GitHub Actions to a full commit SHA with the version in a comment, as the existing workflows do.
- Never use the `pull_request_target` trigger ([why](docs/security-setup.md#8-never-pull_request_target)).
- The hooks must run under plain POSIX `sh` on Linux, WSL and Git Bash.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
