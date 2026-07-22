# Definition of Done

Ship criteria for the Claude Swap native macOS app and its pinned Python core. Each item maps to **automated evidence** (CI artifact, test suite) and **manual evidence** (audit checklist, smoke test notes).

This document tracks Phase 6 sign-off.

**Related matrices:** [`QA_MATRIX.md`](QA_MATRIX.md), [`SECURITY_REVIEW_CHECKLIST.md`](SECURITY_REVIEW_CHECKLIST.md), [`ACCESSIBILITY_REVIEW.md`](ACCESSIBILITY_REVIEW.md)

---

## Summary Status

| Phase | Gate | Status |
|-------|------|--------|
| 0 | Credential safety tests green on 3.12 + 3.14 | **Complete** |
| 1 | Public Python API + tests | In progress (Python API) |
| 2 | NDJSON bridge + contract tests | In progress (bridge) |
| 3 | Swift app foundation builds | In progress (Swift app) |
| 4 | Full product features | Pending |
| 5 | Packaging, signing, updates | In progress (packaging) |
| 6 | Final audit sign-off | Pending |

---

## Checklist

| # | Requirement | Phase | Automated evidence | Manual evidence | Status | Notes |
|---|-------------|-------|-------------------|-----------------|--------|-------|
| 1 | Documented reusable Python library API | 1 | `tests/api/*` green in CI | `docs/api.md` matches `claude_swap.api` exports | ☐ | `src/claude_swap/api/` not yet present |
| 2 | CLI / TUI / JSON / menubar compatibility | 1 | Full `pytest` green; `test_cli.py`, `test_json_output.py`, `test_tui.py`, `test_menubar.py` | Spot-check menubar on macOS | ☐ Partial | Core CLI tests exist; menubar optional dep |
| 3 | Baseline credential failures resolved | 0 | 11 critical tests × 3.12 + 3.14 CI job | QA security review §1 | ☑ | **1529 passed** full suite; critical subset green |
| 4 | Native SwiftUI macOS app | 3 | `xcodebuild -scheme ClaudeSwap -configuration Debug build` | Launch smoke on macOS 14+ | ☐ | Xcode project in progress |
| 5 | No end-user Python installation required | 5 | Unsigned `scripts/build-app.sh` artifact in CI | Fresh VM: launch without system Python | ☐ | |
| 6 | Existing accounts appear on first launch | 3 | Integration test with temp HOME + real backup layout | Manual test with `~/.claude-swap-backup` | ☐ | |
| 7 | Native account operations (switch, add, remove, move) | 4 | Bridge integration + XCUITest flows | Manual switch/add/remove | ☐ | |
| 8 | Usage / quota states render correctly | 4 | `SnapshotModelTests` + fixture decode | Dashboard visual review | ☐ | |
| 9 | Auto-switch uses shared engine with CLI | 4 | `tests/bridge/test_events.py` | Same `settings.json` behavior CLI vs app | ☐ | |
| 10 | One helper process, one shared AppModel | 3 | Integration test: single bridge PID | Activity Monitor: one helper | ☐ | |
| 11 | No secrets in snapshots, logs, or diagnostics | 2, 6 | `tests/bridge/test_redaction.py`, `test_json_output.py` | [`SECURITY_REVIEW_CHECKLIST.md`](SECURITY_REVIEW_CHECKLIST.md) §6 | ☐ Partial | JSON output tested; bridge pending |
| 12 | Graceful degradation (Keychain, network, helper crash) | 4, 6 | Swift integration tests | Locked Keychain manual; offline manual | ☐ | |
| 13 | No duplicate Python core in macos repo | 3 | CI tree check: no `src/claude_swap/` | Repo inspection | ☐ In progress | Python duplicate removed; app scaffold pending |
| 14 | Pinned GitHub core dependency | 5 | `scripts/verify-core.sh` in CI | `Dependencies/CoreDependency.lock.json` review | ☐ | packaging |
| 15 | Sparkle update channel ready | 5 | Release workflow produces appcast + signed DMG | Appcast XML + signature validation | ☐ | |
| 16 | All tests pass | 6 | CI green: Python matrix + bridge + Swift | Final run transcript attached | ☐ Partial | Python core green; Swift TBD |
| 17 | Accessibility polished | 6 | XCUITest accessibility identifiers | [`ACCESSIBILITY_REVIEW.md`](ACCESSIBILITY_REVIEW.md) sign-off | ☐ | |
| 18 | Developer documentation complete | 6 | Doc inventory in repo | External dev dry-run bootstrap | ☐ Partial | QA/security/a11y docs started |
| 19 | No placeholders in production paths | 6 | CI grep gate for TODO/FIXME in `ClaudeSwap/`, bridge | Manual stub audit | ☐ | |
| 20 | Final clean build reproducible | 6 | Recorded commands in `docs/RELEASE.md` | Artifact paths: `.app`, DMG, helper binary | ☐ | |

**Legend:** ☑ Done · ☐ Not done · ☐ Partial

---

## Phase Gates

### Phase 0 — Complete

**Entry:** Identical Python baseline in both repos.  
**Exit criteria:**

- [x] P0-3: Critical credential tests pass on Python 3.12 and 3.14
- [x] P0-2: Full suite ≥ 1529 passed, 3 skipped
- [x] QA Phase 0 security review of credential fixes (see parent deliverable)

**Recorded commands:**

```bash
cd claude-swap
uv run pytest -q                                    # 1529 passed, 3 skipped
uv run pytest tests/test_move_accounts.py tests/test_swap_accounts.py \
  -k "strict_clear or metadata_failure or same_email or failed_required" -v
uv run --python 3.12 pytest tests/test_move_accounts.py tests/test_swap_accounts.py \
  -k "strict_clear or metadata_failure or same_email or failed_required" -v
```

### Phase 1 — Python API

**Exit:** DoD #1, #2; `tests/api/*` in CI.

### Phase 2 — Bridge

**Exit:** DoD #11 (bridge portion); P2-1 through P2-12 in [`QA_MATRIX.md`](QA_MATRIX.md).

### Phase 3 — App Foundation

**Exit:** DoD #4, #6, #10, #13.

### Phase 4 — Product

**Exit:** DoD #7, #8, #9, #12 (partial).

### Phase 5 — Release Engineering

**Exit:** DoD #5, #14, #15.

### Phase 6 — Final Audit

**Exit:** All 20 items ☑; QA sign-off below.

---

## Evidence Log

| Date | Item # | Evidence type | Reference |
|------|--------|---------------|-----------|
| 2026-07-22 | 3 | Automated | `uv run pytest -q` → 1529 passed, 3 skipped |
| 2026-07-22 | 3 | Automated | Critical subset 11/11 pass on 3.12 and 3.14 |
| 2026-07-22 | 3 | Manual | QA Phase 0 security review — **approved** |
| 2026-07-22 | 18 | Manual | Created `docs/QA_MATRIX.md`, `SECURITY_REVIEW_CHECKLIST.md`, `ACCESSIBILITY_REVIEW.md`, `DEFINITION_OF_DONE.md` |

---

## Final Sign-off (Phase 6)

| Role | Name | Date | Signature |
|------|------|------|-----------|
| QA / Audit | | | |
| Release owner | | | |

**Release blockers (if any):**

_None recorded._
