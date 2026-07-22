# Claude Swap macOS — QA Test Matrix

Cross-platform verification plan for the native macOS app and its bundled Python core. Phases align with the project spec (0–6). This matrix records evidence in [`DEFINITION_OF_DONE.md`](DEFINITION_OF_DONE.md).

**Repos**

| Repo | Role |
|------|------|
| `claude-swap` | Canonical Python core, public API, NDJSON bridge |
| `claude-swap-macos` | SwiftUI app, bundled helper, packaging, CI |

**Evidence recording:** For each row, capture command output, CI run URL, or manual audit notes in the DoD evidence column when the gate is reached.

---

## Phase 0 — Baseline and Credential Safety

| ID | Verification | Command / method | Pass criteria | Owner | Status |
|----|--------------|------------------|---------------|-------|--------|
| P0-1 | Repo duplication proof | `diff -rq --exclude='.venv' --exclude='.pytest_cache' --exclude='__pycache__'` canonical vs macos (before Python removal) | Only cache/venv differ | repo audit | Done |
| P0-2 | Full Python suite baseline | `cd claude-swap && uv run pytest -q` | Record pass/skip/fail counts | QA | **1529 passed, 3 skipped** |
| P0-3 | Critical credential tests × 2 Python versions | See [Critical credential tests](#critical-credential-tests) | **0 failures** on 3.12 and 3.14 | credential fix / QA verify | **Pass** |
| P0-4 | Root-cause classification | Code review: `credentials.py`, `switcher.py` | Fix in production code, not test skips | QA | Done |
| P0-5 | Recoverable baseline | Baseline tarball under `.claude-swap-baselines/` | Documented artifact before macos Python removal | repo audit | Done |
| P0-6 | Git workflow | Both repos on `main` / `native-app` branches | Branch strategy documented in `README.md` | packaging | Done |

**Phase 0 gate:** All critical credential tests green on **Python 3.12 and 3.14** before Phase 1 merge.

### Critical credential tests

Run from canonical `claude-swap` (or macos repo while Python duplicate exists):

```bash
CRITICAL='tests/test_move_accounts.py tests/test_swap_accounts.py'
FILTER='strict_clear or metadata_failure or same_email or failed_required'

# Python 3.14 (default .python-version)
uv run pytest $CRITICAL -k "$FILTER" -v

# Python 3.12
uv run --python 3.12 pytest $CRITICAL -k "$FILTER" -v
```

| Test | File | Security property |
|------|------|-------------------|
| `test_move_strict_clear_fails_closed_on_unreadable_dir` | `test_move_accounts.py` | Unreadable `.enc` dir aborts commit; stale key survives |
| `test_move_strict_clear_fails_closed_on_locked_keychain` | `test_move_accounts.py` | Locked Keychain aborts commit; stale item survives |
| `test_move_failed_required_clear_aborts_commit` | `test_move_accounts.py` | Unlink failure aborts; metadata unchanged |
| `test_move_metadata_failure_leaves_account_intact` | `test_move_accounts.py` | `sequence.json` write failure rolls back target strays |
| `test_swap_same_email_partial_failure_rolls_back` | `test_swap_accounts.py` | Mid-write failure restores both slots |
| `test_swap_same_email_persistent_failure_keeps_staged_copy` | `test_swap_accounts.py` | Staging survives persistent backend outage |
| `test_swap_same_email_rollback_restores_empty_slot` | `test_swap_accounts.py` | Unbacked slot cleared on rollback |
| `test_swap_failed_required_clear_aborts_commit` | `test_swap_accounts.py` | Required clear failure aborts swap pre-commit |
| `test_move_clears_stale_destination_key` | `test_move_accounts.py` | Unbacked move clears stale target material |
| `test_swap_clears_stale_destination_key` | `test_swap_accounts.py` | Unbacked swap clears stale destination |
| `test_write_json_publishes_only_after_chmod` | `test_swap_accounts.py` | Metadata commit atomicity |

### Full suite — dual Python matrix

| ID | Python | Command | Expected |
|----|--------|---------|----------|
| P0-F1 | 3.14 | `uv run pytest -q` | All pass (except known skips) |
| P0-F2 | 3.12 | `uv run --python 3.12 pytest -q` | Same totals as 3.14 |
| P0-F3 | 3.12 | `uv run --python 3.12 pytest tests/test_macos_keychain_contract.py tests/test_macos_keychain.py -v` | Pass on macOS CI |
| P0-F4 | either | Real Keychain integration (`@pytest.mark.no_keychain_fake`) | Pass on GHA `macos-latest` only |

---

## Phase 1 — Python Library Boundary

| ID | Verification | Test path (proposed) | Pass criteria |
|----|--------------|----------------------|---------------|
| P1-1 | Service has no stdout/`sys.exit`/`input` | `tests/api/test_service_side_effects.py` | No side effects in service calls |
| P1-2 | Typed errors / stable codes | `tests/api/test_errors.py` | Every domain error maps to machine code |
| P1-3 | Snapshot contract | `tests/api/test_contracts.py` | Sentinels present; no secrets in payload |
| P1-4 | Destructive ops require confirmation | `tests/api/test_confirmations.py` | `remove`/`move`/`swap`/`import` reject without flags |
| P1-5 | CLI regression | `test_cli.py`, `test_json_output.py`, `test_tui.py` | No regressions |
| P1-6 | Public API surface doc | `docs/api.md` | Matches exported `claude_swap.api` |

**CI:** `api-tests` job on canonical repo.

---

## Phase 2 — NDJSON Bridge

### Layer A — Unit (in-process)

| ID | Area | Test file | Pass criteria |
|----|------|-----------|---------------|
| P2-1 | Handshake + capabilities | `tests/bridge/test_handshake.py` | Version/capabilities exchanged |
| P2-2 | Request/response correlation | `tests/bridge/test_correlation.py` | Every response has matching `id` |
| P2-3 | Malformed NDJSON | `tests/bridge/test_malformed.py` | Clean errors; process survives |
| P2-4 | Unsupported protocol major | `tests/bridge/test_version_reject.py` | Structured rejection |
| P2-5 | Secret redaction | `tests/bridge/test_redaction.py` | No token/secret in stdout/errors/logs |
| P2-6 | Request size limits | `tests/bridge/test_limits.py` | Oversized input rejected |
| P2-7 | Mutating op serialization | `tests/bridge/test_serialization.py` | Concurrent mutating requests queued |
| P2-8 | Shutdown / crash | `tests/bridge/test_lifecycle.py` | Graceful shutdown; no half-written state |
| P2-9 | Golden fixtures | `contracts/fixtures/*.json` + `tests/bridge/test_golden.py` | Decode matches schema |
| P2-10 | E2E subprocess | `tests/bridge/test_e2e_process.py` | Real `python -m claude_swap.bridge` against temp HOME |
| P2-11 | Auto-switch events | `tests/bridge/test_events.py` | Events match `AutoSwitchEvent` semantics |
| P2-12 | Schema validation | `contracts/bridge-v1.schema.json` + CI | All fixtures validate |

### Layer B — Contract (golden files)

- `snapshot-full.json`, `snapshot-empty.json`, `snapshot-errors.json`, `events.json`
- Forward-compat: unknown fields ignored
- Backward-compat: major version bump policy tests

### Layer C — Integration (subprocess + isolated HOME)

- Spawn bridge → handshake → snapshot → switch → snapshot invalidation event
- Keychain fake via existing `conftest.py` patterns
- Mid-operation crash → no orphaned staging files
- Concurrent snapshot + switch → serialized mutating ops

### Layer D — Security adversarial (independent review)

- Secret in request params never echoed
- stderr sanitized before log aggregation
- Max line length / max JSON depth enforced
- Unknown destructive method params rejected

**CI:** `bridge-contract` job on ubuntu + macos.

---

## Phase 3 — Native App Foundation

| ID | Verification | Command / target | Pass criteria |
|----|--------------|------------------|---------------|
| P3-1 | Xcode project builds | `xcodebuild -scheme ClaudeSwap -configuration Debug build` | 0 errors |
| P3-2 | Helper bundled | Inspect `Contents/Helpers/` or auxiliary executable | Correct arch at runtime |
| P3-3 | CoreBridgeClient unit | `ClaudeSwapTests/CoreBridgeClientTests.swift` | NDJSON framing, correlation, timeout |
| P3-4 | Fixture decoding | Golden bridge fixtures → Swift `Codable` | All fixtures decode |
| P3-5 | AppModel integration | Mock bridge → `@Observable` state | Single refresh coalescing |
| P3-6 | Shared state | Window + MenuBarExtra | One helper process, one model |
| P3-7 | Onboarding/Dashboard smoke | XCUITest launch | Real snapshot populates UI |
| P3-8 | No duplicate Python source | Repo tree audit | macos repo lacks `src/claude_swap/` |

---

## Phase 4 — Full Product Functionality

| ID | Area | Automated | Manual |
|----|------|-----------|--------|
| P4-1 | Automation settings | Swift unit: range validation mirrors Python | App change → verify `settings.json` |
| P4-2 | Activity timeline | Event decoding tests | No credentials in timeline rows |
| P4-3 | Import/export | Bridge integration with temp files | `--full` warning; force overwrite |
| P4-4 | Add token sheet | Bridge: secret via stdin only | Secure field cleared after submit |
| P4-5 | Account destructive actions | XCUITest confirmation sheets | Exact account named in sheet |
| P4-6 | Notifications | Unit: notification content redaction | Keychain 30s delay message |
| P4-7 | Launch at Login | ServiceManagement smoke | Toggle persists |
| P4-8 | Accessibility baseline | XCUITest accessibility identifiers | VoiceOver pass on Dashboard + Accounts |

---

## Phase 5 — Dependency and Release Engineering

| ID | Verification | Evidence |
|----|--------------|----------|
| P5-1 | Lock manifest | `scripts/verify-core.sh` in CI | SHA matches pinned commit |
| P5-2 | `update-core.sh` dry run | Manual + script unit tests | Refuses unpinned branch |
| P5-3 | Multi-arch helper | arm64 + x86_64 build artifacts | Both signed in release |
| P5-4 | Unsigned dev build | `scripts/build-app.sh` without certs | App launches without system Python |
| P5-5 | Sparkle appcast | Validate XML + ed25519 signature | Checksum matches DMG |
| P5-6 | Notarization pipeline | GHA release workflow | Stapled `.app` |
| P5-7 | CI matrix | PR workflow: lock verify + helper build + Swift tests | All green |

---

## Phase 6 — Final Verification and Audit

| ID | Activity | reviewer role |
|----|----------|----------|
| P6-1 | Full Python suite 3.12 + 3.14 | Execute + record totals |
| P6-2 | Full Swift unit + UI suite | Execute + record totals |
| P6-3 | Bridge E2E matrix | Run Layer C integration |
| P6-4 | Security audit | [`SECURITY_REVIEW_CHECKLIST.md`](SECURITY_REVIEW_CHECKLIST.md) |
| P6-5 | Accessibility audit | [`ACCESSIBILITY_REVIEW.md`](ACCESSIBILITY_REVIEW.md) |
| P6-6 | Fresh clone bootstrap | `scripts/bootstrap.sh` → build → test |
| P6-7 | Placeholder/stub hunt | Grep TODO/FIXME in production paths |
| P6-8 | DoD sign-off | [`DEFINITION_OF_DONE.md`](DEFINITION_OF_DONE.md) |
| P6-9 | Final report | Architecture, test totals, external steps |

---

## Swift Test Plan

### Unit — `ClaudeSwapTests/`

| Suite | Coverage |
|-------|----------|
| `BridgeProtocolTests` | NDJSON partial reads, multiple messages per read, unknown fields |
| `BridgeErrorTests` | Python error code → Swift `BridgeError` mapping |
| `BridgeFixtureTests` | All golden JSON fixtures |
| `CoreBridgeClientTests` | Timeouts, cancellation, crash detection, restart backoff |
| `SnapshotModelTests` | Sentinel states, countdown from `resetsAt`, stale presentation |
| `UsageFormattingTests` | Pace, exhaustion estimate labeling |
| `MenuBarLabelTests` | Compact/detailed label modes |
| `SettingsPersistenceTests` | Swift UI prefs vs core settings separation |
| `RedactionTests` | Diagnostics copy preview strips secrets |
| `AppModelTests` | Event stream → UI state; last-known-good on helper failure |

### Integration — `ClaudeSwapIntegrationTests/`

| Scenario | Bridge + temp HOME |
|----------|-------------------|
| Empty first run | Onboarding path |
| Existing `~/.claude-swap-backup` | Accounts appear without re-import |
| Switch success | Snapshot invalidation event |
| Switch rollback failure | UI shows error; state unchanged |
| Add token | Secret not in logs/process args |
| Quarantine / relogin | Sentinel badges |
| Keychain unavailable | Recovery UI |
| Helper crash | Backoff + recovery screen |
| Incompatible protocol | Actionable error |

### UI — `ClaudeSwapUITests/`

Onboarding, populated dashboard, empty state, switch flow, add-token sheet, remove confirmation, automation settings, error recovery, settings navigation, reopen main window after close.

---

## Manual Audit Matrices

Detailed runbooks:

- **Security:** [`SECURITY_REVIEW_CHECKLIST.md`](SECURITY_REVIEW_CHECKLIST.md)
- **Accessibility:** [`ACCESSIBILITY_REVIEW.md`](ACCESSIBILITY_REVIEW.md)

---

## Recommended CI Jobs (target state)

| Job | Runner | Scope |
|-----|--------|-------|
| `python-matrix` | ubuntu, macos | pytest 3.12 + 3.14 full suite |
| `credential-critical` | ubuntu | 11 critical tests × 3.12 + 3.14 |
| `macos-keychain` | macos-latest | `test_macos_keychain_contract.py` + real Keychain |
| `api-tests` | ubuntu | `tests/api/*` |
| `bridge-contract` | ubuntu + macos | `tests/bridge/*` + schema validation |
| `swift-unit` | macos-latest | `xcodebuild test -scheme ClaudeSwap` |
| `verify-core` | ubuntu | `scripts/verify-core.sh` |
| `unsigned-build` | macos-latest | `scripts/build-app.sh` Debug |

---

## Quick reference commands

```bash
# Full suite (canonical core)
cd claude-swap && uv run pytest -q

# Critical credential subset
uv run pytest tests/test_move_accounts.py tests/test_swap_accounts.py \
  -k "strict_clear or metadata_failure or same_email or failed_required" -v

# macOS Keychain CI subset
uv run pytest tests/test_macos_keychain_contract.py tests/test_macos_keychain.py -v \
  -o faulthandler_timeout=60

# Swift (when Xcode project exists)
xcodebuild -scheme ClaudeSwap -configuration Debug build
xcodebuild -scheme ClaudeSwap -destination 'platform=macOS' test
```
