# Contributing

Thanks for looking at Claude Swap for macOS. This is an experimental, independently maintained companion app for the upstream [claude-swap](https://github.com/realiti4/claude-swap) CLI. Please read this file and the [README](README.md) first.

## Ground rules

- **Account engine stays upstream.** Do not reimplement switching, token refresh, or credential locking in Swift. Call the public CLI commands and map their output.
- **No secrets in the repository.** Never commit tokens, export files, `.env` files, real account data, or screenshots of real accounts. Test data must be synthetic and must live in `ClaudeSwapTests/Fixtures/` or in the fake executables used by tests.
- **No personal paths.** Do not hard-code home directories, checkout locations, or machine-specific settings.
- **Docs change with code.** If behavior, a command, a setting, a path, or a version changes, update the README, the relevant `docs/` page, and `CHANGELOG.md` in the same commit.
- **Credentials go only through stdin** to the CLI. Never pass them in argv, environment variables, `UserDefaults`, logs, or diagnostics.
- **Cover new behavior with tests** that run without network access, Keychain access, or a real `cswap`.

## Set up

Requirements: macOS 14 or later, the Xcode version used by `.github/workflows/ci.yml`, and Homebrew (for shellcheck, optional).

```sh
./scripts/bootstrap.sh                                  # installs XcodeGen if needed and generates the project
open ClaudeSwap.xcodeproj
```

`ClaudeSwap.xcodeproj` is generated from `project.yml`. Do not hand-edit the `.pbxproj`. Change `project.yml` and regenerate. The version lives only in `project.yml` (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`).

## Build and test

```sh
./scripts/build-app.sh --config Debug --action build    # unsigned build, the same as CI
./scripts/build-app.sh --config Debug --action test     # unit tests (scheme ClaudeSwap)
(cd scripts && shellcheck -x ./*.sh ./lib/*.sh)         # shell lint, the same as CI
```

- The unit tests run with fake executables, temporary directories, and an injected launchctl. They do not use the network, the real Keychain, or a real `cswap`.
- `HOME` overrides do **not** isolate the macOS Keychain. Do not rely on them to keep tests away from real credentials.
- UI tests are a separate scheme, `ClaudeSwapUITests`. They need a logged-in GUI session and Accessibility permission for the process that runs `xcodebuild`.

UI tests run with `./scripts/build-app.sh --config Debug --action ui-test`. The metadata checks run with `./scripts/verify-metadata.sh --check-xcodegen`.

## Working with the CLI

- Use only public `cswap` commands and their documented JSON output.
- A new CLI behavior is accepted only after it is recorded in [`docs/CLI_COMPATIBILITY.md`](docs/CLI_COMPATIBILITY.md). Fake-executable tests alone do not make a CLI version "verified".
- Do not add a CLI version to `ClaudeSwap/Resources/CLICompatibility.json` `verifiedVersions` in a feature PR. That change belongs to a contract run.
- The developer-only NDJSON bridge (`CLAUDE_SWAP_BACKEND=bridge`) is not a supported user path. Do not add user-facing features that depend on it.

## Pull requests

1. Branch from `main`.
2. Keep the change focused. One concern per PR.
3. Make sure `build-app.sh --action build` and `--action test` pass, and that `shellcheck` is clean if you touched `scripts/`.
4. Update the docs and the changelog in the same PR.
5. Fill in the pull request template, including the checklist.

Merging, tagging, and publishing are done by the maintainer.

## Commit messages

Short imperative subjects that explain *why*, for example `Stop auto-switch LaunchAgent on disable` rather than `Update AutoSwitchDaemonService`. Keep the body short when it adds context.

## Reporting bugs and security issues

- Bugs in the wrapper: open an issue in this repository with the bug report template. Attach only sanitized diagnostics.
- Security issues: follow [`SECURITY.md`](SECURITY.md). Do not open a public issue.
- Never attach tokens, export files, or unsanitized logs to any issue or pull request.
