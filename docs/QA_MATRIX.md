# QA matrix

This page tracks acceptance for release 1 of Claude Swap for macOS. Every row starts as **Not run**. A row changes to **Passed** only when there is evidence (a test run, a CI link, or a dated manual note) and the evidence is recorded in the Notes column.

Unit tests with fake executables are useful, but they are **not** acceptance evidence for CLI behavior. Only a run against the unmodified official package counts (see [`CLI_COMPATIBILITY.md`](CLI_COMPATIBILITY.md)).

## Acceptance matrix

| # | Scenario | Expected result | Status | Notes |
|---|---|---|---|---|
| A-1 | Mac without the CLI | Onboarding shows the CLI requirement and install steps; no demo accounts appear | Not run | Unit coverage for discovery only (`LiveBackendDiscoveryTests`) |
| A-2 | Official CLI at the baseline version | Dashboard and in-scope operations work without any sibling checkout | Not run | Requires contract run |
| A-3 | Installed with uv or pipx; Finder launch with minimal `PATH` | CLI is found, or chosen in Settings › Command-Line Tool | Not run | Discovery order is covered by `LiveBackendDiscoveryTests`; no manual run yet |
| A-4 | Several CLI installs on one Mac | The active path and version are shown; the user can choose | Not run | |
| A-5 | Old CLI or unknown JSON schema | Clear compatibility message; account-changing actions blocked | Not run | Policy logic only; no real-CLI run |
| A-6 | CLI fails to launch or times out | UI stays responsive; status is honest; no orphaned process | Not run | `ProcessRunnerTests`: `timeoutTerminatesAndReaps`, `cancellationTerminatesAndReaps`, `launchFailureForMissingAndNonExecutable` (fake executables) |
| A-7 | Invalid token or rejected credential | No token in logs, diagnostics, or argv | Not run | No dedicated Redactor test file yet; manual check pending |
| A-8 | Add into an occupied slot | No silent overwrite; no indefinite wait for a prompt | Not run | Requires contract run (C-5) |
| A-9 | Alias fails after a successful add | UI reports partial success with the real account state | Not run | |
| A-10 | Import of an existing account | Not overwritten unless the user explicitly chooses overwrite; skipped accounts listed | Not run | Requires contract run (C-13, C-14) |
| A-11 | CLI and app used alternately | Results appear after refresh; the wrapper does not write account data itself | Not run | |
| A-12 | Automation disabled, then login again | Automation stays disabled | Not run | `AutoSwitchDaemonServiceTests` use an injected launchctl; real login not tested |
| A-13 | CLI upgraded while the service is running | Service path stays valid, or a clear recovery is offered | Not run | |
| A-14 | App removed | Wrapper service can be cleaned up; CLI accounts are not removed | Not run | Uninstall steps documented in README |
| A-15 | Clone on another Mac | Build uses only public files and documented tools | Not run | `bootstrap.sh` on a clean clone |

## Automated checks

| Check | Command or job | Status | Notes |
|---|---|---|---|
| Metadata consistency | `scripts/verify-metadata.sh --check-xcodegen` (CI `metadata`) | Not run | |
| Unit tests | `scripts/build-app.sh --config Debug --action test` (CI `build-test`) | Not run | Runs without network, Keychain, or a real `cswap` |
| Build | `scripts/build-app.sh --config Debug --action build` (CI `build-test`) | Not run | |
| Shell lint | `shellcheck -x` over `scripts/` (CI `shell-lint`) | Not run | |
| UI smoke test | `scripts/build-app.sh --config Debug --action ui-test` | Not run | Needs a GUI session and Accessibility permission |
| Package dry run | `scripts/package-release.sh --dry-run` | Not run | |
| Unsigned package | `scripts/package-release.sh` | Not run | |
| Checksum | `shasum -a 256 -c` on the produced `.sha256` | Not run | |

CI runs `metadata`, `build-test` and `shell-lint`. The UI smoke test (`scripts/build-app.sh --action ui-test`) needs a GUI session and is run manually.

## Unit test coverage (fake executables, no real CLI)

| Area | Test files | What they cover |
|---|---|---|
| Process runner | `ClaudeSwapTests/ProcessRunnerTests.swift` | Captured stdout, stderr, and exit code; literal arguments; 1 MB stdin; capped output; timeout; SIGTERM-ignoring child; cancellation; already-cancelled task; launch failure |
| Auto-switch service | `ClaudeSwapTests/AutoSwitchDaemonServiceTests.swift`, `AutoSwitchStateMappingTests.swift` | Enable writes plist and bootstraps; load fallback; disable boots out and removes plist; status running, failing, starting, not registered, orphaned, launcher missing; upstream menu bar agent detected without mutation; log rotation for large logs |
| CLI discovery and snapshot mapping | `ClaudeSwapTests/LiveBackendDiscoveryTests.swift` | Installed `cswap` resolved; `list --json` mapped to a snapshot; usage cache enrichment for inactive accounts |
| Redaction | None yet | Gap: `Redactor` has no dedicated tests. Add them before release. |
| Models | `BridgeModelDecodingTests.swift`, `BridgeErrorMappingTests.swift` | JSON decoding and error mapping |

These tests show that the wrapper handles the cases it knows about. They do not prove compatibility with a given CLI version.

## CLI contract runs

Record one row per run. Do not paste raw output that contains account identifiers, emails, or tokens.

| Date | CLI version | Installed by | macOS / chip | Checklist result | Outcome | Evidence |
|---|---|---|---|---|---|---|
| — | — | — | — | — | No run recorded yet | — |

The checklist items (C-1 to C-17) are in [`CLI_COMPATIBILITY.md`](CLI_COMPATIBILITY.md#contract-checklist). A version may be added to `verifiedVersions` only when every item passes in a run recorded here.

## Manual smoke test (release candidate)

Run on a clean test Mac or test account with no personal credentials:

- [ ] Install the DMG from the release, verify its checksum, and open the app.
- [ ] Without a CLI: onboarding shows install steps; no accounts are shown.
- [ ] Install the CLI, choose it in Settings if needed, and confirm the dashboard loads.
- [ ] Add a synthetic account with a setup token (use a throwaway token from a test account), set an alias, switch, disable and enable, then remove it.
- [ ] Export and import with the Save and Open panels; confirm the export file is not opened in the UI.
- [ ] Turn Automation on and off; confirm the LaunchAgent is created and removed.
- [ ] Open the diagnostics preview and confirm it contains no token, email, or home path.
- [ ] Quit and reopen the app; confirm state and Automation status are correct.
