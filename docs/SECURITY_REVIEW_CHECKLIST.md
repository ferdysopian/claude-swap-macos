# Security review checklist

Review runbook for Claude Swap for macOS. It covers the wrapper only. The upstream `cswap` CLI and Claude Code are reviewed by their own projects.

Run this checklist before each release and whenever CLI calls, credential handling, logging, diagnostics, export and import, or the auto-switch service change. Record findings with the evidence (test name, PR, grep output, or manual note). Do not record secrets in the findings.

Related: [`QA_MATRIX.md`](QA_MATRIX.md), [`DEFINITION_OF_DONE.md`](DEFINITION_OF_DONE.md).

**Status key:** Pass · Fail · Pending. Pending means not yet reviewed for this release.

## Severity

| Severity | Definition | Action |
|---|---|---|
| Critical | Credential leak, token in argv, environment, logs, or diagnostics, or a change that writes account data outside the CLI | Block release |
| High | Fail-open on a locked Keychain or a failed credential operation reported as success; overwrite without confirmation | Block release |
| Medium | Missing confirmation on a destructive action; error text with an email or path shown in UI or logs | Fix before release |
| Low | Documentation gap; defense-in-depth | Track |

## 1. Credentials

| # | Check | Method | Pass criteria | Status |
|---|---|---|---|---|
| CR-1 | Tokens are sent to the CLI through stdin only | Review `CswapCLIClient` for `add-token -`; `ProcessRunnerTests` | Token never appears in argv or environment | Pending |
| CR-2 | Tokens are not stored by the wrapper | Review `UserDefaults` keys and file writes | No token written to preferences, logs, or temp files | Pending |
| CR-3 | Secure input for token entry | Review `AddAccountSheet` | `SecureField` used; value cleared after submit | Pending |
| CR-4 | Wrapper makes no network requests | Review for `URLSession`, `URLRequest`, and networking APIs in `ClaudeSwap/` | None found in the wrapper's own code | Pending |
| CR-5 | Keychain access is performed by the CLI only | Review the code for Keychain APIs | No Keychain reads or writes in the wrapper | Pending |

## 2. CLI execution

| # | Check | Method | Pass criteria | Status |
|---|---|---|---|---|
| EX-1 | No shell interpolation | Review `ProcessRunner` and calls to `Process` | Executable and arguments passed as arrays; no `sh -c` | Pending |
| EX-2 | Explicit paths are not silently replaced | `LiveBackendDiscoveryTests`, review of `CLIDiscovery` | Non-executable explicit path is reported | Pending |
| EX-3 | Timeouts and cancellation | `ProcessRunnerTests`: `timeoutTerminatesAndReaps`, `childIgnoringSigtermIsKilled`, `cancellationTerminatesAndReaps` | Process is terminated and reaped; pipes closed on every path | Pending |
| EX-4 | Bounded output | `ProcessRunnerTests`: `largeOutputOnBothStreamsIsCapped` | Output size limit enforced for stdout and stderr | Pending |
| EX-5 | Mutations are not retried automatically | Review `CswapCLIClient` | No automatic retry of account-changing commands; timeout reported as "outcome unknown" | Pending |
| EX-6 | One CLI command at a time | Review serialization in `CswapCLIClient` | Concurrent commands are queued | Pending |
| EX-7 | Development-only bridge is not a user path | Review `BridgeProcess` and documentation | Bridge selected only by explicit developer environment setting | Pending |

## 3. Logging and diagnostics

| # | Check | Method | Pass criteria | Status |
|---|---|---|---|---|
| LD-1 | Redaction of tokens, emails, and home paths | Gap: no dedicated `Redactor` tests yet; add them | Sanitized output for each pattern (Anthropic-style keys, bearer headers, JSON secret fields, long opaque strings, emails, home path, ANSI escapes) | Pending |
| LD-2 | Diagnostics preview before copy | Manual smoke test | Preview shown; nothing copied without the user's action | Pending |
| LD-3 | Activity timeline has no credential text | Review timeline entries; unit tests | No token-shaped strings in timeline rows | Pending |
| LD-4 | Logs are rotated | `AutoSwitchDaemonServiceTests`: `rotatesLargeLogs` | Size limit (5 MB) and one old generation honored | Pending |
| LD-5 | Error text from the CLI is sanitized before display or logging | Review error mapping | Raw CLI messages pass through `Redactor` | Pending |
| LD-6 | Logs are not sent anywhere | Review for network or telemetry code | No telemetry; logs stay in `~/Library/Logs/ClaudeSwap/` | Pending |

## 4. Export and import

| # | Check | Method | Pass criteria | Status |
|---|---|---|---|---|
| XI-1 | User is told the export file contains credentials | Review Tools UI text | Warning present; no text claiming the file has no tokens | Pending |
| XI-2 | Export file is not rendered in the UI or clipboard | Review `ToolsView` and export path | Only Save and Open panels handle the file | Pending |
| XI-3 | Import never overwrites by default | Review import call; contract check C-13 and C-14 | `--force` only after explicit user choice | Pending |
| XI-4 | Temporary files are private and removed | Review temp-file handling | Restrictive permissions; removed on success and failure | Pending |
| XI-5 | Input size is limited before reading | Review import path | Size bound applied | Pending |

## 5. Auto-switch service

| # | Check | Method | Pass criteria | Status |
|---|---|---|---|---|
| AS-1 | One service, one label | `AutoSwitchDaemonServiceTests` | Only `app.claudeswap.autoswitch` is installed | Pending |
| AS-2 | Disable stops and removes the agent | `AutoSwitchDaemonServiceTests` | Bootout and plist removal verified | Pending |
| AS-3 | No override flags in the plist | Plist generation tests | Plist runs `cswap auto --json` with no threshold or interval flags; `cswap config` is the source | Pending |
| AS-4 | Upstream menu bar agent is not stopped | Review service code | Warning only; no action on `com.cswap.menubar` | Pending |
| AS-5 | Real login and reboot behavior | Manual test | Disabled automation stays disabled after login | Pending |

## 6. Packaging and supply chain

| # | Check | Method | Pass criteria | Status |
|---|---|---|---|---|
| SC-1 | No third-party packages | `project.yml` review | No `packages:` section | Pass |
| SC-2 | No bundled upstream code or executables | Artifact inspection of the DMG | Only the app bundle; no helper, Python, or `cswap` | Pending |
| SC-3 | Artifact state is stated honestly | Artifact name and release notes | `-unsigned` name and warning when unsigned | Pending |
| SC-4 | Signing and notarization checks, when performed | [`SIGNING.md`](SIGNING.md#checks-before-publishing-a-signed-build) | All checks pass | Pending |
| SC-5 | CI actions pinned to reviewed commit SHAs | Review `.github/workflows/` | Pinned | Pending (TODO in workflows) |
| SC-6 | Workflows use least privilege | Review `permissions:` in workflows | `contents: read` by default; write only for release creation | Pending |

## 7. Entitlements and hardening

| # | Check | Method | Pass criteria | Status |
|---|---|---|---|---|
| EN-1 | No App Sandbox entitlement | Entitlements review | Not present | Pending |
| EN-2 | Hardened runtime on signed builds | `codesign -dv` on the signed app | `runtime` flag present | Pending |
| EN-3 | App Transport Security | Review `Info.plist` | No exceptions unless justified | Pending |

## Adversarial search (aid, not a substitute for review)

```sh
# Token-like strings in tracked files (review every hit; test fixtures must be synthetic)
git grep -n -E 'sk-ant-[A-Za-z0-9_-]+|Bearer [A-Za-z0-9._-]+' -- ':!*.enc'

# Personal home paths in tracked files
git grep -n -E '/Users/[a-zA-Z0-9._-]+/'
```

Note: `git grep` only searches tracked files. Check untracked new files separately before committing.

## Review log

| Date | Scope | Reviewer | Result | Evidence |
|---|---|---|---|---|
| — | — | — | No review recorded yet | — |
