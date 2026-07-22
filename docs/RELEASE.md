# Cutting a release

## Automatic (recommended)

1. Merge to `main` (or `native-app`) with CI green.
2. Tag and push:
   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. The **Release** workflow builds an unsigned arm64 DMG (unless signing
   secrets are set) and opens a **draft** GitHub Release with the artifacts.
4. Review the draft → publish when ready.

## Manual

**Actions → Release → Run workflow**

| Input | Meaning |
|-------|---------|
| `version` | Label without `v` when not tagging |
| `require_pin` | Fail if `Dependencies/CoreDependency.lock.json` is still `PENDING` |
| `include_intel` | Also build x86_64 helper (needs `macos-15-intel` or self-hosted) |

## Signing / notarization (optional)

Add these repository secrets (Settings → Secrets and variables → Actions).
All are optional — without them the workflow ships an **unsigned** DMG.

| Secret | Purpose |
|--------|---------|
| `CODESIGN_IDENTITY` | `Developer ID Application: … (TEAMID)` |
| `CODESIGN_CERT_P12_BASE64` | Base64 `.p12` export |
| `CODESIGN_CERT_PASSWORD` | `.p12` password |
| `APPLE_TEAM_ID` | 10-char Team ID |
| `APPLE_ID` | Apple ID for notarytool |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password |
| `SPARKLE_PRIVATE_KEY` | Sparkle ed25519 key (base64) |

See [`SIGNING.md`](SIGNING.md) and [`PACKAGING.md`](PACKAGING.md).

## Core helper pin

Until `scripts/update-core.sh --tag <tag>` pins a real `claude-swap` revision,
releases ship **without** an embedded helper. The app still works by
discovering an installed `cswap` on the user’s Mac (or fixture mode).

For production cuts, pin the core first, then release with `require_pin: true`.
