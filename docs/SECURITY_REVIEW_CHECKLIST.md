# Security Review Checklist

Independent security audit runbook for Claude Swap (Python core + macOS native app). This review is performed at Phase 0 (credential fixes), Phase 2 (bridge), Phase 4 (add-token UI), Phase 5 (signing/updates), and Phase 6 (final audit).

**Related:** [`QA_MATRIX.md`](QA_MATRIX.md) Layer D, [`DEFINITION_OF_DONE.md`](DEFINITION_OF_DONE.md) item 11.

Record findings in the Evidence column: PR link, test name, grep output, or manual note.

**Last QA review:** 2026-07-22 — Phase 0 credentials + API/`add_token` + bridge redaction/server/protocol + `cswap-bridge` argv.

---

## Critical / High findings (escalate immediately)

| Sev | ID | Finding | Status |
|-----|-----|---------|--------|
| **CRITICAL** | F-BRIDGE-STDOUT | `ClaudeAccountSwitcher.add_account_from_token` (and other mutators) call `print()` to `sys.stdout`. Production `BridgeServer` writes NDJSON to `sys.stdout.buffer` — **same fd**. Human status lines (e.g. `Added Account N: email…`) interleave with protocol frames and corrupt the wire format for Swift clients. **Not a token leak**, but a bridge showstopper. Reproduced 2026-07-22: redirecting `sys.stdout` captured `Added Account 4: u@token.local [personal] (from token)\n` during `accounts.addToken`. | **FIXED** — `BridgeServer` installs `_WireSafeStdout` and arms per-thread diversion for every `_invoke_service` call (`server.py`). Regression: `test_service_print_does_not_reach_stdout_during_dispatch`. |
| — | — | Phase 0 credential fail-closed paths | **PASS** (no open issues) |
| — | — | `cswap-bridge` argv / `add_token` secret handling / wire redaction | **PASS** (see §3) |

---

## 1. Credentials and Transactional Safety

| # | Check | Method | Pass criteria | Evidence |
|---|-------|--------|---------------|----------|
| C-1 | Strict clear ordering | Code review `delete_account_credentials_strict` | `.enc` unlink **before** Keychain delete; cruft sweep is best-effort only | **PASS** — `credentials.py:980-983`: `unlink(missing_ok=True)` then `_kc_delete_backup`. Cruft via `_delete_non_served_credential_cruft` first (best-effort only; never touches served key). |
| C-2 | Fail-closed on unreadable store | `test_move_strict_clear_fails_closed_on_unreadable_dir` | Move aborts; stale material survives unreferenced | **PASS** — critical subset 11/11 on 3.12+3.14 (2026-07-22). |
| C-3 | Fail-closed on locked Keychain | `test_move_strict_clear_fails_closed_on_locked_keychain` | Move aborts; Keychain item not destroyed then lost | **PASS** — same suite. |
| C-4 | Required clear aborts commit | `test_*_failed_required_clear_aborts_commit` | Metadata unchanged; no wrong-credential commit | **PASS** — move + swap variants. |
| C-5 | Relocate cleanup guard | Code review `_relocate_locked` `target_mutated` | Pre-commit failure does **not** delete pre-existing stale target material | **PASS** — `switcher.py:1177-1232`: `target_mutated` set only after successful write/strict-clear; rollback cleanup gated on flag. Strict-clear raise leaves flag `False` → pre-existing stale intact. |
| C-6 | Swap rollback integrity | `test_swap_same_email_*` suite | Staging, empty-slot restore, partial failure rollback | **PASS** — suite green. |
| C-7 | Staging file permissions | `test_swap_same_email_persistent_failure_keeps_staged_copy` | Staging files mode `0600` on POSIX | **PASS**. |
| C-8 | Leftover staging refusal | `test_swap_refuses_leftover_staging` | Retry refuses; does not overwrite only copy | **PASS**. |
| C-9 | Metadata commit atomicity | `test_write_json_publishes_only_after_chmod` | chmod failure does not publish partial state | **PASS**. |
| C-10 | Session lock during destructive ops | Review `_ensure_no_live_session` call sites | swap/move/remove refuse live session-mode Claude | **PASS** — `_relocate_locked` / swap call `_ensure_no_live_session` before mutation. |
| C-11 | Test integrity (`monkeypatch.context`) | Review `test_move_accounts.py` / `test_swap_accounts.py` | Nested context; does not `undo()` autouse Keychain fake | **PASS** — 7 sites use `with monkeypatch.context() as mp:` (comments document Keychain-fake teardown risk). |

---

## 2. Keychain (macOS)

| # | Check | Method | Pass criteria | Evidence |
|---|-------|--------|---------------|----------|
| K-1 | No secrets in argv | Code review `macos_keychain.py` | `set_password` uses `security -i` stdin path; argv fallback only under size limit | **PASS** — prior review + `test_set_password_small_payload_uses_security_i_stdin`. |
| K-2 | Pinned binary path | Review `_SECURITY = "/usr/bin/security"` | No PATH hijack | **PASS**. |
| K-3 | Timeout on Keychain ops | Review `_TIMEOUT = 5.0` | Wedged Keychain cannot hang CLI indefinitely | **PASS**. |
| K-4 | Not-found vs error distinction | Review `_NOT_FOUND_RC = 44` | rc 44 → absent; other rc → `KeychainError` | **PASS**. |
| K-5 | Reader vs strict-clear semantics | Compare `_read_account_credentials` vs `delete_account_credentials_strict` | Reader best-effort (`""` on error); strict clear raises | **PASS**. |
| K-6 | Keychain delete on macOS even in file mode | Review strict clear path | Keychain delete runs unconditionally on macOS for served key | **PASS** — `if self._host.platform == Platform.MACOS: self._kc_delete_backup(...)` (not gated on `_use_keychain()`). |
| K-7 | Real Keychain contract tests | GHA `macos-keychain` job | Layer 2 integration passes on macOS runner | ☐ Pending CI run |
| K-8 | Helper inherits login session | Manual / integration | Bundled helper can access user's login keychain without spurious prompts | ☐ App not shipped |
| K-9 | No sandbox Keychain breakage | Review entitlements (when app exists) | Minimal entitlements; documented Keychain access model | ☐ App not shipped |

---

## 3. IPC / NDJSON Bridge

| # | Check | Method | Pass criteria | Evidence |
|---|-------|--------|---------------|----------|
| I-1 | Secrets never in process argv | Bridge `__main__` + argparse | Tokens only in stdin JSON body | **PASS** — `cswap-bridge` options are only `-h/--help`, `--max-request-bytes`, `--max-workers`. No token/secret/password flags. Secret for `accounts.addToken` is `params.secret` on stdin NDJSON only. |
| I-1b | Library rejects CLI stdin sentinel | `ClaudeSwapService.add_token` | `secret=="-"` / empty / non-str rejected | **PASS** — `service.py:355-359` rejects `""`, whitespace, `"-"`, non-str (verified live 2026-07-22). Prevents switcher reading next protocol line as a token. |
| I-2 | Request/response correlation | `test_bridge_protocol.py` / server | Every response has matching `id` | **PASS** — protocol + server tests green (69 related tests 2026-07-22). |
| I-3 | Malformed input handling | `test_bridge_server.py` | Clean errors; process survives | **PASS** — parse/UTF-8/oversized covered. |
| I-4 | Protocol version rejection | handshake major gate | Unsupported major rejected cleanly | **PASS** — `validate_handshake_params` → `UNSUPPORTED_PROTOCOL_VERSION`. |
| I-5 | Secret redaction on wire | `test_bridge_redaction.py` + `serialize` | No token values under sensitive keys on stdout | **PASS** — `protocol.serialize` → `redact()` before every stdout frame. Adversarial e2e: `accounts.addToken` with `sk-ant-oat01-LEAKME` → stdout contains no `LEAKME` / no `sk-ant-oat01`. `test_secret_shaped_*_is_redacted_on_the_wire`. |
| I-5b | Debug log redacts params | `server._dispatch_line` | Debug uses `redact(params)` | **PASS** — `server.py:300-302`. |
| I-6 | Request size / depth limits | max_request_bytes + redact depth | Oversized rejected; deep structures truncated | **PASS** — `DEFAULT_MAX_REQUEST_BYTES=1MiB`; redact `_MAX_DEPTH=32`. |
| I-7 | Mutating op serialization | `_mutation_lock` | Concurrent mutating requests serialized | **PASS** — `server.py:328-333` holds bridge-wide lock through result+event. |
| I-8 | Graceful shutdown | shutdown method + drain | Clean stop | **PASS** — `shutdown` + `_drain_pending`. |
| I-9 | Swift client never logs raw NDJSON with secrets | Swift `RedactionTests` | Logger privacy annotations | ☐ Swift not ready |
| I-10 | Helper crash recovery | Integration test | App recovery UI | ☐ App not ready |
| I-11 | No shell interpolation | Bridge entry / service `_core_ref` | Direct executable path | **PASS** — bridge is in-process module; `_core_ref` uses `["git","rev-parse","HEAD"]` list form (no shell). |
| I-12 | NDJSON stream not polluted by CLI prints | Service/bridge isolation | No human `print()` on shared stdout | **FAIL — F-BRIDGE-STDOUT** (see Critical table). Token not leaked; protocol corrupted. |

---

## 4. Updates and Supply Chain

| # | Check | Method | Pass criteria | Evidence |
|---|-------|--------|---------------|----------|
| U-1 | Pinned core dependency | `scripts/verify-core.sh` + `CoreDependency.lock.json` | SHA matches tagged commit; CI fails on drift | ☐ Pending (packaging) |
| U-2 | No runtime pip into bundle | Code + manual | App never `pip install`s into `Contents/Resources` | ☐ |
| U-3 | Sparkle signature validation | Release workflow + manual | Ed25519 signature verified before apply | ☐ |
| U-4 | Appcast HTTPS only | Review Sparkle config | No plaintext update channel | ☐ |
| U-5 | Helper binary signing | Release artifacts | Developer ID signature on nested Mach-O | ☐ |
| U-6 | Notarization staple | Release pipeline | Stapled ticket; Gatekeeper clean on fresh VM | ☐ |
| U-7 | Lock manifest review | PR review | No floating branch refs in production lock | ☐ |

---

## 5. Import / Export / Transfer

| # | Check | Method | Pass criteria | Evidence |
|---|-------|--------|---------------|----------|
| X-1 | Plaintext export warning | UI + CLI review | User warned before exporting credentials | ☐ Bridge/UI path pending |
| X-2 | `--full` scope documented | `test_transfer.py` + docs | MCP secrets not exported unless explicit | ☐ Partial — core CLI tests exist |
| X-3 | Import overwrite confirmation | API/bridge confirmation tests | Force flag required for destructive import | ☐ |
| X-4 | Temp file permissions | Code review transfer paths | Temp exports created with restrictive modes | ☐ |
| X-5 | No accidental MCP secret export | Manual spot-check | Export manifest excludes unexpected paths | ☐ |
| X-6 | Import path traversal | Adversarial fixture | Rejects `..` and absolute paths outside backup dir | ☐ |

---

## 6. Logging and Diagnostics

| # | Check | Method | Pass criteria | Evidence |
|---|-------|--------|---------------|----------|
| L-1 | JSON snapshot / bridge result redaction | `test_bridge_redaction.py` + snapshot `show_token_status=False` | No raw tokens in payloads | **PASS** — snapshot uses `show_token_status=False`; wire redact by key. |
| L-2 | Python log levels | Review bridge logger | Credentials never at INFO/DEBUG | **PASS** (params) — debug logs `redact(params)`. |
| L-2b | stderr error text not key-redacted | Code review `_send_error` / `_on_task_done` | Exception/`message` strings scrubbed | **MEDIUM** — stderr logs raw `message`/`exc` text. Current domain errors do not embed token values (spot-check). Defense-in-depth: redact or sanitize before logging. Not a known leak today. |
| L-3 | Swift Logger privacy | Code review + manual | Sensitive values use `.private` or redacted copy | ☐ |
| L-4 | Activity timeline sanitization | UI review + unit tests | No credential substrings in activity rows | ☐ |
| L-5 | Diagnostics copy preview | `service.diagnostics()` | Paths/booleans only | **PASS** — docstring + payload: version, paths, flags, pid — no credentials. |
| L-6 | stderr from helper | Integration grep | Bridge stderr redacted before Swift aggregation | ☐ Pending Swift aggregation; see L-2b |
| L-7 | Crash reports | Manual (if enabled) | No embedded tokens in crash attachments | ☐ |

---

## 7. Process Execution and Locks

| # | Check | Method | Pass criteria | Evidence |
|---|-------|--------|---------------|----------|
| P-1 | Claude Code file locks respected | `test_claude_locks.py`, `test_locking.py` | Bridge honors lock files during refresh/switch | ☐ Partial — core tests exist; bridge path inherits switcher |
| P-2 | No auto-executor with secrets | Code review | No `cswap run` spawning Claude with token in env | **PASS** for bridge — no run executor in bridge methods. |
| P-3 | Credential refresh chokepoint | Review `_post_backup_write` | Session invalidation after successful write only | **PASS** (core). |
| P-4 | Single helper instance | Integration + Activity Monitor | One bridge process per app | ☐ App not ready |

---

## 8. Entitlements and Hardening (macOS app)

| # | Check | Method | Pass criteria | Evidence |
|---|-------|--------|---------------|----------|
| E-1 | Minimal entitlements | Review `.entitlements` | No unnecessary access groups / sandbox exceptions | ☐ |
| E-2 | Hardened Runtime | Xcode build settings | Enabled for release builds | ☐ |
| E-3 | Library validation | Release build | No unsigned dylibs loaded | ☐ |
| E-4 | ATS / network | Review Info.plist | Justified exceptions only | ☐ |

---

## Review Schedule

| Milestone | Required sections | Sign-off |
|-----------|-------------------|----------|
| Phase 0 complete | §1, §2 (K-1–K-7) | **QA signed 2026-07-22 — PASS** |
| Bridge MVP | §3, §6 (L-1, L-6) | **QA 2026-07-22 — CONDITIONAL** (secrets/argv/redaction PASS; **F-BRIDGE-STDOUT blocks**) |
| Add-token UI | §3 (I-9), §6 | Pending |
| Release candidate | All sections | Pending |

---

## Adversarial grep patterns (automated aid)

Run against test fixtures and sample logs — **manual review still required**:

```bash
# Token-like patterns (adjust for project-specific formats)
rg -i 'sk-[a-zA-Z0-9]{10,}|refresh_token|access_token|Bearer [a-zA-Z0-9._-]+' \
  --glob '!*.enc' --glob '!.venv/**'

# Staging files left behind after failed ops
find "$HOME/.claude-swap-backup" -name '.swap-staging-*' 2>/dev/null
```

---

## Finding severity rubric

| Severity | Definition | Action |
|----------|------------|--------|
| **Critical** | Credential leak, commit of wrong token, secret in logs/argv, **or protocol-corrupting stdout on the bridge wire** | Block release |
| **High** | Fail-open on locked Keychain, rollback destroys only copy | Block release |
| **Medium** | Missing confirmation on destructive op, verbose error with email, stderr not structurally redacted | Fix before RC |
| **Low** | Documentation gap, defense-in-depth hardening | Track for follow-up |
