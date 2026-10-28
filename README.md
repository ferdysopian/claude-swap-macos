# Claude Swap for macOS

A native macOS companion for [claude-swap](https://github.com/realiti4/claude-swap) by realiti4. Account management is powered by the separately installed upstream CLI. This wrapper is maintained independently.

> **Unofficial.** Claude Swap is an independent app. It is not affiliated with, endorsed by, or sponsored by Anthropic or realiti4, and it is not an official app of either. "Claude" is a trademark of Anthropic; it is used only to describe compatibility.

**Status: experimental, pre-release.** Release 1 is wrapper-only: you install the upstream CLI yourself, and the app drives it. No CLI version has passed the wrapper's contract checklist yet (see [Compatibility](#compatibility)). Publishing the source and publishing a binary are separate milestones; see [`docs/DEFINITION_OF_DONE.md`](docs/DEFINITION_OF_DONE.md).

Repository: https://github.com/ferdysopian/claude-swap-macos

## What it does

- **Menu bar popover and dashboard** for your managed accounts, with usage and reset times from the CLI.
- **Switch** the active account; aliases; disable and enable accounts; remove an account after confirmation.
- **Add an account** from the login Claude Code is using right now, or from a pasted setup token or API key. Tokens are passed to the CLI through stdin.
- **Auto-switch automation** through one per-user LaunchAgent that runs the CLI's own `auto` command. The CLI's `autoswitch.*` settings are the single source of configuration; the switching decisions belong to the CLI.
- **Activity timeline** of actions the app took.
- **Export and import** through the CLI's own file format, using Save and Open panels.
- **Diagnostics** that are sanitized and shown as a preview before you copy them.

The wrapper has no switching algorithm of its own.

## Install

### 1. Install the upstream CLI

Claude Swap needs the `cswap` command from the `claude-swap` package. Install it with one of the methods described in the upstream README:

```sh
uv tool install claude-swap
# or
pipx install claude-swap
```

Check that `cswap` runs in Terminal before you continue. The app never installs or upgrades the CLI for you.

### 2. Install the app

1. Download the `.dmg` and its `.sha256` file from the project's GitHub Releases page.
2. Verify the checksum:
   ```sh
   shasum -a 256 -c ClaudeSwap-<version>.sha256
   ```
3. Open the DMG and drag **Claude Swap** to Applications.

Until a notarized release is published, DMGs are **unsigned experimental builds**. macOS will block the first launch. To open this app only, use **right-click → Open**, or open **System Settings → Privacy & Security** and choose **Open Anyway** for Claude Swap. Do not disable Gatekeeper globally.

### 3. First launch

The app looks for `cswap` in this order: the `CLAUDE_SWAP_CLI_PATH` environment variable, the path saved in **Settings › Command-Line Tool**, then `PATH` plus `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`. If no CLI is found, the app shows install steps. It never shows demo accounts in place of your data.

## Compatibility

| Item | Value |
|---|---|
| Platform | macOS 14 or later |
| Minimum CLI version | `claude-swap` 0.26.0 |
| Baseline CLI version | 0.26.0 (the public command surface the wrapper was written against) |
| CLI versions verified with this app | None yet |
| Chip architecture | Apple silicon (arm64) first; Intel is not promised |

A CLI that is older than the minimum is marked incompatible, and changes that modify accounts are blocked. A newer CLI that is not yet verified still works, but the app labels it "not yet verified with this app version". The verified list lives in `ClaudeSwap/Resources/CLICompatibility.json`.

## Privacy and data

- **The wrapper itself** has no telemetry and makes no network requests.
- **The CLI it runs does contact Anthropic services**, for example to refresh OAuth tokens and to read usage. Those requests come from the upstream CLI, and its behavior is defined by upstream.
- **Credentials are stored by the CLI**, in the macOS Keychain and in files under the CLI's own data directory, as described by upstream. The wrapper does not store tokens. Tokens you paste are sent to `cswap add-token` through stdin, not as command-line arguments.
- **What the wrapper keeps locally:**
  - Preferences in `UserDefaults` (for example, the CLI path and appearance).
  - Logs in `~/Library/Logs/ClaudeSwap/`, rotated at 5 MB with one older generation kept.
  - The LaunchAgent property list `~/Library/LaunchAgents/app.claudeswap.autoswitch.plist`, only while Automation is on.
- **Usage cache:** the app reads the CLI's on-disk usage cache so inactive accounts can still show usage. That file is an internal detail of the CLI, not a public contract, and it is only tested against CLI 0.26.0.
- **Export files contain credentials.** The CLI writes them with `0600` permissions. Treat an export file like a password: do not share it, paste it into an issue, or store it in a synced folder.
- **Diagnostics** remove tokens, email addresses, and your home directory path before you see the preview. Review the preview before you share it, and remove anything you do not want to share.

## Troubleshooting

**"CLI not installed" or "No executable cswap"**
- Run `which cswap` in Terminal. If it prints a path, open **Settings › Command-Line Tool** in the app and choose that path.
- Apps opened from Finder do not inherit your Terminal `PATH`. Claude Swap searches the usual uv, pipx, and Homebrew locations, but a CLI installed somewhere else needs the Settings path.
- To run one launch with a specific CLI, start the executable from Terminal:
  ```sh
  CLAUDE_SWAP_CLI_PATH=/path/to/cswap /Applications/ClaudeSwap.app/Contents/MacOS/ClaudeSwap
  ```

**"Not yet verified with this app version"**
- This is expected for a CLI release that is not yet in the verified list. Check the release notes for the CLI version you have. If something misbehaves, see [Issues](#reporting-problems).

**"Incompatible CLI"**
- Upgrade the CLI with `uv tool upgrade claude-swap` or `pipx upgrade claude-swap`, then reopen the app.

**An action reports "outcome unknown"**
- A change timed out before the app received a result. The app re-reads the account list. Check the list before you try again; the wrapper never retries a change automatically.

**Automation shows "failing"**
- Open the logs in `~/Library/Logs/ClaudeSwap/`. Review them before sharing, because they can contain account information.

**"Two auto-switch engines may run"**
- Upstream's optional menu bar agent (`com.cswap.menubar`) is installed. The app warns about it but never stops it. Keep one of them enabled.

## Uninstall

1. Turn **Automation** off in the app. This stops the LaunchAgent and deletes its property list. If you have already deleted the app, unload and remove the agent manually:
   ```sh
   launchctl bootout gui/$(id -u)/app.claudeswap.autoswitch
   rm ~/Library/LaunchAgents/app.claudeswap.autoswitch.plist
   ```
2. Delete `/Applications/ClaudeSwap.app`.
3. Optional: remove preferences and logs:
   ```sh
   defaults delete app.claudeswap.ClaudeSwap
   rm -r ~/Library/Logs/ClaudeSwap
   ```

Removing the app does **not** remove the accounts or credentials managed by the CLI. To remove an account, use `cswap remove <identifier>` before you uninstall the CLI.

For removing the CLI and its stored data, follow the [claude-swap](https://github.com/realiti4/claude-swap) documentation.

Earlier builds of this app used a different bundle identifier and LaunchAgent label. On first launch the app copies its old preferences and replaces an old auto-switch agent (any `*.claudeswap.autoswitch` agent that runs `cswap auto`) with the current one.

## Build from source

Contributors: see [`CONTRIBUTING.md`](CONTRIBUTING.md). In short:

```sh
./scripts/bootstrap.sh                                  # installs XcodeGen if needed and generates the project
./scripts/build-app.sh --config Debug --action build    # unsigned Debug build
./scripts/build-app.sh --config Debug --action test     # unit tests
```

The Xcode project is generated from `project.yml`, which is the single source of the version (currently 0.2.0, build 8).

## Requirements

- macOS 14 or later.
- Xcode: the version used by CI in `.github/workflows/ci.yml`.
- The upstream `claude-swap` CLI, installed separately (see [Install](#install)).

## Documentation

- [`docs/CLI_COMPATIBILITY.md`](docs/CLI_COMPATIBILITY.md): how a CLI release is evaluated
- [`docs/QA_MATRIX.md`](docs/QA_MATRIX.md): acceptance matrix and status
- [`docs/PACKAGING.md`](docs/PACKAGING.md), [`docs/RELEASE.md`](docs/RELEASE.md), [`docs/SIGNING.md`](docs/SIGNING.md): packaging and release
- [`docs/SECURITY_REVIEW_CHECKLIST.md`](docs/SECURITY_REVIEW_CHECKLIST.md): security review items
- [`docs/adr/`](docs/adr/): architecture decisions
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md): upstream and third-party notices
- [`SECURITY.md`](SECURITY.md), [`CONTRIBUTING.md`](CONTRIBUTING.md), [`CHANGELOG.md`](CHANGELOG.md)

<a id="reporting-problems"></a>
## Reporting problems

Open an issue in this repository. Use the bug report template and attach only sanitized diagnostics. Never include tokens, export files, or account email addresses. Problems with the wrapper belong in this repository.

## License and credits

- Claude Swap for macOS: MIT License (see [`LICENSE`](LICENSE)).
- The account engine is [claude-swap](https://github.com/realiti4/claude-swap) by realiti4, licensed under MIT. It is installed separately and is not distributed with this app. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
