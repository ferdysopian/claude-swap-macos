# ADR 0001: Bundle the existing Python core as a frozen helper process, rather than rewriting the switch logic in Swift

- **Status:** Accepted
- **Date:** 2026-07-22
- **Owners:** Packaging/CI/Release, with input from bridge and Swift app owners

## Context

`claude-swap` (the canonical Python core, https://github.com/realiti4/claude-swap) already implements the hard, security-sensitive parts of this product:

- OAuth token refresh and multi-account credential swapping for Claude Code
- macOS Keychain access (`macos_keychain.py`) and cross-platform credential storage
- Safe, lock-guarded file moves of `~/.claude` state (`claude_locks.py`, `locking.py`, `transfer.py`)
- Process detection to avoid swapping accounts out from under a running `claude` process
- A large, mature regression-test suite (1500+ tests as of this repo's Phase 0 baseline)

The macOS app (this repo) needs to expose that functionality through a native SwiftUI/AppKit menu-bar experience, with a bridge protocol (see `contracts/**`) connecting the two.

We had to decide how the native app talks to that logic.

## Decision

Freeze the existing, tested Python core into a standalone helper executable (via PyInstaller) and bundle it inside `ClaudeSwap.app`. The Swift app spawns it as a subprocess and communicates over a versioned NDJSON stdin/stdout protocol (`bridgeProtocolVersion` in `Dependencies/CoreDependency.lock.json`). Users never need Python installed; the helper is fully self-contained.

The pinned revision of the core is tracked explicitly in `Dependencies/CoreDependency.lock.json` and updated only via `scripts/update-core.sh`, so every build is reproducible from a lock file, the same way `Package.resolved` or `uv.lock` pin their respective dependencies.

## Alternatives considered

### A. Full Swift rewrite of the switching logic

Rejected. This would mean re-implementing and re-testing OAuth refresh, Keychain interaction, atomic file-swap logic, and process detection in a second language, with a second test suite, and keeping both in sync forever. The Python core's behavior (especially the failure-mode handling around partial swaps and locking) took significant iteration to get right; duplicating it is high risk for low reward. It also means every core bugfix has to be ported twice.

### B. Embed CPython in-process (PythonKit / C API) instead of a subprocess

Rejected. Embedding a full CPython runtime inside a hardened-runtime, notarized `.app` is substantially more complex to sign and notarize correctly (every extension module the interpreter loads at runtime needs to satisfy code-signing/library-validation checks, see `docs/SIGNING.md`), introduces GIL/threading interactions with SwiftUI's main-thread requirements, and makes crash isolation worse — a segfault in a Python C extension takes down the whole app instead of a helper process the app can just relaunch. A subprocess boundary is simpler to reason about, sandbox-adjacent (even though we're not sandboxed — see below), and easier to version independently of the app.

### C. Rewrite only the "hot path" (swap/credentials) in Swift, keep the rest in Python

Rejected for now. The swap/credential path is exactly the highest-risk code to rewrite (Keychain + concurrent file locking). Splitting the core would also mean the bridge protocol needs to distinguish "handled natively" vs "delegated to helper" per call, adding complexity for marginal benefit. Nothing rules this out later, call by call, once the Swift app is stable and specific operations are proven to need it (e.g. for latency).

## Consequences

- **App size**: a frozen Python helper (interpreter + stdlib subset + deps) adds tens of MB per architecture to the shipped app. Mitigated by `--onedir` builds (better compressibility in the DMG than `--onefile`) and by not vendoring anything beyond what `claude_swap.bridge` actually imports (`--collect-all claude_swap` rather than a blanket `--collect-all` of everything on `sys.path`).
- **Multi-architecture builds are non-trivial**: PyInstaller does not support `lipo`-merging two single-arch builds after the fact (confirmed upstream behavior — see the caveats documented at the top of `scripts/build-core-helper.sh`). Because `HelperLocator` (Swift) looks up exactly one fixed-name auxiliary executable with no runtime arch branching of its own, we ship two complete, architecture-consistent app+DMG pairs (arm64, x86_64) by default, or build a single genuinely-universal2 app+helper when a universal2 Python + universal2 wheels are available. This is handled entirely in `scripts/package-release.sh` / `.github/workflows/release.yml` and required no changes to `ClaudeSwap/CoreBridge/**`.
- **Versioning surface area**: three independent version numbers now matter (`pythonPackageVersion`, `bridgeProtocolVersion`, `helperBuildVersion`), all tracked in `Dependencies/CoreDependency.lock.json`. `scripts/verify-core.sh` and the Swift `CoreBridge` client are expected to check `bridgeProtocolVersion` compatibility at launch.
- **No App Sandbox** (see below) is a direct consequence of needing Keychain access equivalent to the CLI tool and unrestricted `~/.claude` file access; this decision doesn't change that calculus but does mean the helper process inherits the same sandbox posture as the app (no sandbox on either side).
- **Testing**: the core's own test suite (`pytest`) remains the primary correctness net and is run against the exact pinned revision by `scripts/update-core.sh` before any pin is accepted. The Swift side only needs to test the bridge protocol boundary and UI, not credential-swap correctness from scratch.

## Related

- `docs/PACKAGING.md` — how the helper is built and embedded
- `docs/SIGNING.md` — why the app is not sandboxed, and what that implies for signing/notarizing the helper
- `docs/UPDATING-CORE.md` — how the pin in `Dependencies/CoreDependency.lock.json` gets updated
- `scripts/build-core-helper.sh` — architecture caveats in detail
