# scripts/

Packaging, build, and release automation for `claude-swap-macos`. Full docs: [`../docs/PACKAGING.md`](../docs/PACKAGING.md), [`../docs/SIGNING.md`](../docs/SIGNING.md), [`../docs/UPDATING-CORE.md`](../docs/UPDATING-CORE.md).

| Script | Purpose |
|---|---|
| `bootstrap.sh` | One-shot dev environment setup. Run this first. |
| `build-core-helper.sh` | Freeze the Python core (`../Dependencies/CoreDependency.lock.json` pin, or a local override) into a helper executable via PyInstaller. Read the arch caveats in the file header before touching `--arch`. |
| `update-core.sh` | Re-pin the core to an explicit `--tag`/`--sha`. Tests + smoke-builds before writing the lock file. Never runs `git push`. |
| `verify-core.sh` | Validate the lock file (used by CI on every PR). |
| `build-app.sh` | Unsigned `xcodebuild` build/test of `ClaudeSwap.xcodeproj`. No-ops gracefully if the project isn't scaffolded yet. |
| `package-release.sh` | Full release packaging: helper(s) + app + sign/notarize (only if credentials are configured) + DMG + checksums + Sparkle appcast item. |
| `lib/common.sh` | Shared bash helpers (logging, lock-file access, core-source resolution). Sourced by every script above; not run directly. |
| `lib/lock.py` | Dependency-free JSON get/set/validate for the lock file. Used by `common.sh`; you can also call it directly for scripting. |

## Quick start

```sh
scripts/bootstrap.sh
scripts/build-core-helper.sh
scripts/build-app.sh --config Debug
scripts/package-release.sh
```

Every script supports `-h`/`--help` (prints its own header comment).
