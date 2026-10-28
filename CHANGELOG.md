# Changelog

All notable changes to Claude Swap for macOS are recorded here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The project is experimental; versions may change without notice before a stable release.

Claude Swap for macOS is a native macOS companion for [claude-swap](https://github.com/realiti4/claude-swap) by realiti4. Account management is powered by the separately installed upstream CLI. This wrapper is maintained independently.

## Unreleased

Release 1 plan: the wrapper drives the officially installed `cswap` CLI. Nothing from upstream is bundled. See [ADR 0002](docs/adr/0002-wrapper-uses-installed-cli.md).

### Added

- Minimum CLI version policy (`ClaudeSwap/Resources/CLICompatibility.json`): minimum and baseline `0.26.0`, an empty list of verified versions, and supported JSON schema `1`. Unverified CLI versions are labeled; incompatible versions block account changes.
- CLI discovery: `CLAUDE_SWAP_CLI_PATH`, then the path saved in Settings › Command-Line Tool, then the usual uv, pipx, and Homebrew locations. Explicit paths that are not executable are reported.
- Process runner for CLI calls: argument arrays only (no shell), stdin for secrets, timeouts, cancellation, bounded output, and one CLI command at a time.
- Redaction for diagnostics and logs, with a preview before the diagnostics are copied.
- Auto-switch LaunchAgent (`app.claudeswap.autoswitch`) with real status: disabled, starting, running, failing, launcher missing, registration without plist, and plist not loaded. Logs are rotated at 5 MB.
- Warning when upstream's menu bar agent (`com.cswap.menubar`) is installed, because two auto-switch engines may run. The app does not stop it.
- Documentation: README rewritten for users and contributors, `THIRD_PARTY_NOTICES.md`, `CONTRIBUTING.md`, `SECURITY.md`, issue and pull request templates, ADR 0002, and `docs/CLI_COMPATIBILITY.md`.

### Changed

- The app uses the installed CLI as its only production backend. When no CLI is found, it shows install steps instead of demo accounts. Fixture data is used only when explicitly requested, in previews, and in tests.
- Export and import use the CLI's own export file, selected in Save and Open panels. The export file contains credentials and must be handled like a password. Import skips existing accounts unless the user explicitly chooses to overwrite them.
- Adding an account into an occupied slot requires explicit overwrite confirmation.
- A failed alias after a successful add is reported as a partial success.
- Settings changes that fail are reported to the user instead of being ignored.
- Version source: `project.yml` is the single source of `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. The earlier drift between `project.yml` and the project file is resolved.
- Development documentation for the NDJSON bridge is limited to developer use (`CLAUDE_SWAP_BACKEND=bridge` with `CLAUDE_SWAP_CORE_PATH`). It is not a supported user path.

### Removed

- The bundled Python core helper, its pinned upstream revision (`Dependencies/CoreDependency.lock.json`), the helper build and update scripts, the core-update workflow, and the build-info manifest (`CoreBuildInfo.json`).
- The "no tokens" wording in the export description. The export file does contain credentials.
- Statements that the app never transmits tokens anywhere. The CLI contacts Anthropic services, so the accurate statement is that the wrapper itself makes no network requests and that credentials are handled by the CLI.

### Known gaps

- No CLI version is listed in `verifiedVersions` yet, so every CLI is currently labeled "not yet verified with this app version".
- The official-package contract checklist (`docs/CLI_COMPATIBILITY.md`) has not been run.
- Release artifacts are unsigned. Signing and notarization are documented but not performed.
- No automatic update check. The "Check for Updates" pane points to GitHub Releases.
- Action versions in CI are not pinned to commit SHAs yet.

## 0.2.0 (build 8)

Recorded from git history: the version bump commit (`Bump version to 0.2.0 (build 8)`) and the change that ran auto-switch as a LaunchAgent so the Automation toggle takes effect. The earlier release notes for this build were not written as a changelog entry.
