# secure-repo-template

Start a repository with the security basics already in place: a pre-commit hook that stops secrets before they reach history, free scanners in CI, Dependabot with a cooldown, a minimum package age for npm, and tuned settings for two AI pull-request reviewers.

Everything in the core setup is free. The optional parts (Snyk, Greptile, and CodeRabbit on private repos) are paid or metered, and the guide says which.

**Supported:** Linux, WSL, and Git Bash on Windows. macOS is not supported yet: the hooks use GNU `sed` and `xargs` options that macOS lacks.

## What's inside

| Path | What it does | Cost |
|---|---|---|
| `Scripts/githooks/pre-commit` | Runs gitleaks on staged changes and **fails closed**: a found secret blocks the commit, and so does a missing or broken scanner. Optional Snyk checks run only when a dependency actually changed. | Free (Snyk optional, metered) |
| `Scripts/githooks/install.sh` | Installs the hooks for all your repos (`~/.githooks`) or for one repo. | Free |
| `Scripts/githooks/test-pre-commit.sh` | Self-test for the hook, run in CI. | Free |
| `.github/workflows/security.yml` | gitleaks, osv-scanner, `npm audit` and `npm audit signatures` on every PR, every push to `main`, and weekly. | Free |
| `.github/workflows/githooks.yml` | Runs the hook tests and shellcheck. | Free |
| `.github/dependabot.yml` | Grouped updates with a 7-day cooldown. GitHub Actions on; npm and pip ready to uncomment. | Free |
| `.npmrc` | `min-release-age=7`: npm refuses package versions younger than a week. | Free |
| `.coderabbit.yaml` | Settings for the CodeRabbit reviewer, if you install it. | Free for public repos |
| `.greptile/config.json` | Settings for the Greptile reviewer, if you install it. Held to the cheapest review tier. | Paid |
| `.gitleaksignore` | Empty. Where reviewed false positives go. | — |
| `SECURITY.md`, `CONTRIBUTING.md`, `AGENTS.md` | Starting points for your own policy, contributor guide and AI-agent guide. | — |

## Quick start

1. Click **Use this template** at the top of this page, then **Create a new repository**.
2. Clone your new repo and install gitleaks ([docs/security-setup.md, step 2](docs/security-setup.md#2-pre-commit-hook-gitleaks-fails-closed)).
3. Install the hooks, either for this repo only:

   ```bash
   git config core.hooksPath Scripts/githooks
   ```

   or for every repo on this machine:

   ```bash
   sh Scripts/githooks/install.sh
   ```

4. In your new repo on GitHub, turn on the settings a template cannot copy: **Settings → Advanced Security** (called **Code security** on some accounts) → Dependabot alerts, Dependabot security updates, and Private vulnerability reporting.
5. Edit `SECURITY.md` and the copyright line in `LICENSE`, and replace `AGENTS.md` with your project's own guide. Delete `CHANGELOG.md`: it records this template's versions, not yours.

The full walkthrough, with what each step costs and how to undo it, is in [docs/security-setup.md](docs/security-setup.md).

## License

MIT. See [LICENSE](LICENSE).
