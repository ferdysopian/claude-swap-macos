# CLI compatibility

This document explains how a new release of the upstream CLI (`cswap`, package `claude-swap`, https://github.com/realiti4/claude-swap) is evaluated, and how the result is recorded in the app. It replaces the older `UPDATING-CORE.md` pin workflow, which no longer applies because nothing from upstream is bundled.

## The policy file

`ClaudeSwap/Resources/CLICompatibility.json` is read by the app at runtime:

| Field | Meaning |
|---|---|
| `minimumVersion` | Oldest CLI the app will run mutations against. Older versions are incompatible. |
| `baselineVersion` | The official release whose public command surface the wrapper was written against (currently `0.26.0`). |
| `verifiedVersions` | CLI versions that passed the contract checklist below against the unmodified official package. Empty until a run passes. |
| `jsonSchemaVersions` | JSON output schema versions the parser supports (currently `[1]`). An unknown schema makes the CLI incompatible. |

The app labels a CLI that is not in `verifiedVersions` as "not yet verified with this app version". This is a normal state for a new CLI release, not an error.

Fake-executable unit tests (`ProcessRunnerTests`, `AutoSwitchDaemonServiceTests`) do **not** count as verification. Only a contract run against the official package does.

## When to evaluate a new CLI release

- A new `claude-swap` release appears on PyPI or in upstream's changelog.
- A user reports a CLI behavior change, or the app shows an unknown-schema state.
- Before a wrapper release that claims support for a newer CLI version.

## Procedure

1. **Use a clean environment.** Run the contract on a dedicated macOS test account or VM that has no personal Claude Code credentials. `HOME` overrides do not isolate the macOS Keychain, so do not rely on them.
2. **Install the official package unmodified** at the exact version under test, using the same method documented for users (`uv tool install claude-swap==<version>` or `pipx install claude-swap==<version>`). Do not install from a branch, a local checkout, or a patched wheel.
3. **Record** the version, the installation method, the macOS version, and the Mac architecture.
4. **Run the contract checklist** below. Every item must pass. Record the result and any output that explains a failure, after removing tokens, email addresses, and home paths.
5. **Run the wrapper's automated tests** against the same app build: `scripts/build-app.sh --config Debug --action test`.
6. **Update the policy file** only after steps 4 and 5 pass:
   - Add the version to `verifiedVersions`.
   - Add a JSON schema version to `jsonSchemaVersions` only if the parser actually supports it.
   - Change `minimumVersion` only together with a code change that needs it, and note the reason in `CHANGELOG.md`.
7. **Update the docs** that state a verified CLI version (the README compatibility note and the release notes) in the same commit.

If any item fails, do not add the version. Record the failure in `docs/QA_MATRIX.md`, and decide whether the wrapper needs a change, a documented limitation, or a higher `minimumVersion`.

## Contract checklist

Each item must pass on the unmodified official package. Feature names match the acceptance matrix in [`QA_MATRIX.md`](QA_MATRIX.md).

| # | Check | Command used by the wrapper | Pass criteria |
|---|---|---|---|
| C-1 | Version is reported and parses | `cswap --version` | Output is recognized as the expected version |
| C-2 | Account list parses | `cswap list --json` | Valid against schema 1; empty account list handled |
| C-3 | Status parses | `cswap status --json` | Valid against schema 1 |
| C-4 | Switch changes the active account | `cswap switch <identifier> --json`; bare `cswap switch --json` for rotation | Next `list --json` shows the new active account |
| C-5 | Add from current login | `cswap add` (with explicit slot where used) | Account appears; occupied slot is refused without overwrite |
| C-6 | Add token via stdin | `cswap add-token -`, token on stdin | Account appears; token does not appear in argv, environment, or logs |
| C-7 | Alias set and unset | `cswap alias <identifier> <alias>` and `--unset` | Alias shown in `list --json` |
| C-8 | Disable and enable | `cswap disable` / `cswap enable` | `list --json` reflects the state |
| C-9 | Remove | `cswap remove <identifier>` | Account gone; the confirmation input the CLI expects is supplied the way the wrapper supplies it |
| C-10 | Config list and set | `cswap config list --json`, `cswap config set ...` | JSON parses; `autoswitch.*` keys are readable and settable |
| C-11 | Auto-switch command | `cswap auto --json` (run by the LaunchAgent) | Runs as a long-lived process under launchd; the wrapper's status reflects its real state |
| C-12 | Export | `cswap export <file>` | File written with restrictive permissions (0600); contents treated as credentials |
| C-13 | Import without overwrite | `cswap import <file>` (stdout lines starting with `Skipped` are reported) | Existing accounts are skipped and listed, not overwritten |
| C-14 | Import with overwrite | `cswap import <file> --force` | Only runs after an explicit user choice in the wrapper |
| C-15 | Failure exit codes | e.g. `cswap switch <unknown> --json`, `cswap alias <unknown> x` | Non-zero exit; stderr message can be sanitized |
| C-16 | Usage cache file | Read the CLI's on-disk usage cache after `cswap list --json` | Cache file is found and parsed, or the wrapper reports it missing; no crash |
| C-17 | Login-free run | Commands above on a machine with no personal credentials | No prompts that would hang the wrapper; timeouts are honored |

## Recording results

Record each run as one row in the status table in [`QA_MATRIX.md`](QA_MATRIX.md) (section "CLI contract runs"), with the CLI version, date, macOS version, and a pass or fail for each checklist item. Do not paste raw CLI output that contains account identifiers, emails, or tokens.

## What to do when a CLI release breaks something

- **Schema change:** keep the old version as the verified set, add the new schema only after the parser is updated and tested, and state the change in the changelog.
- **Command change:** update the wrapper's argument mapping, keep `minimumVersion` at the lowest version that still passes, and document the boundary.
- **Behavior change in a shared engine feature** (for example, switch selection): record it as a CLI behavior change. The wrapper does not implement its own switching algorithm.
