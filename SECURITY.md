# Security policy

Claude Swap for macOS manages accounts through the upstream `cswap` CLI and handles credentials indirectly. Please report security problems privately.

## Supported versions

This project is experimental and has no long-term support branches. Security fixes target the `main` branch and the most recent published release.

## Reporting a vulnerability

Use GitHub private vulnerability reporting: **Security → Report a vulnerability** on the repository page.

Do **not** open a public issue for a suspected vulnerability.

Include:

- The app version (from **About**) and the macOS version and chip.
- The `cswap` version you used and how you installed it.
- Steps to reproduce, and what you expected and observed.
- Whether credentials or account data could have been exposed.

**Never send** any of the following, through any channel:

- Tokens, API keys, setup tokens, passwords, or PINs.
- Export files created by the CLI or the app.
- Unsanitized logs, diagnostics, or screenshots that show account emails, organization names, or your home directory path.

If a report needs such data to make sense, describe the shape of the data and say that you have removed the values. The maintainer will ask for more only through a private channel, and only if necessary.

## If you think a credential leaked

Revoke or rotate the credential with the service that issued it, then remove the account in the app or with `cswap remove`. Do not wait for a fix from this project.

## Scope

In scope: the wrapper's code, its scripts and release artifacts, how it passes data to the CLI, its logs and diagnostics, and its LaunchAgent handling.

Out of scope: the upstream `claude-swap` CLI and Claude Code themselves. Those are maintained by their own projects. This project does not forward reports to them.
