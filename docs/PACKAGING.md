# Packaging

How `claude-swap-macos` goes from source to a distributable DMG for release 1.

Related: [`RELEASE.md`](RELEASE.md) (release checklist), [`SIGNING.md`](SIGNING.md) (signing and notarization), [`CLI_COMPATIBILITY.md`](CLI_COMPATIBILITY.md), [ADR 0002](adr/0002-wrapper-uses-installed-cli.md).

## What the artifact contains

Release 1 is **wrapper-only**:

- `ClaudeSwap.app` (the SwiftUI app), built as Release for `arm64` first.
- No Python, no upstream engine, no helper executable, and no copy of `claude-swap`.
- The app finds the user's separately installed `cswap` at runtime (see the README).

Intel (`x86_64`) and universal builds are not promised. The `--arch` option exists for local experiments only.

## Version source

`project.yml` is the single source of the version:

- `MARKETING_VERSION` (currently `0.2.0`) and `CURRENT_PROJECT_VERSION` (currently `8`).
- `ClaudeSwap/Resources/Info.plist` reads them through `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.
- `ClaudeSwap.xcodeproj` is generated from `project.yml`. Change the version in `project.yml`, regenerate, and check the diff.
- `scripts/verify-metadata.sh --check-xcodegen` checks that the committed project matches the generated one.

A release tag must equal `v` plus `MARKETING_VERSION`. The release workflow rejects any other tag.

## Pipeline

```text
project.yml ──xcodegen──▶ ClaudeSwap.xcodeproj
                              │
scripts/build-app.sh ─────────┤  xcodebuild (Release, arm64)
                              ▼
                     build/…/ClaudeSwap.app
                              │
scripts/package-release.sh ───┤  version check against project.yml
                              │  optional codesign (DEVELOPER_ID_APPLICATION)
                              │  hdiutil → DMG
                              │  optional notarize + staple (--notarize, NOTARY_PROFILE)
                              │  shasum -a 256 → .sha256
                              ▼
                     dist/ClaudeSwap-<version>[-unsigned].dmg (+ .sha256)
```

## Scripts

| Script | Role |
|---|---|
| `scripts/bootstrap.sh` | Installs XcodeGen if needed and regenerates the project |
| `scripts/build-app.sh` | `xcodebuild` build, test, or ui-test |
| `scripts/verify-metadata.sh [--check-xcodegen]` | Offline metadata checks (CI `metadata` job) |
| `scripts/package-release.sh [--dry-run] [--notarize]` | Release Release-configuration app, DMG, checksum |

See [`scripts/README.md`](../scripts/README.md) for usage.

## Packaging a DMG

```sh
scripts/package-release.sh --dry-run    # print the plan; no build
scripts/package-release.sh              # unsigned build: dist/ClaudeSwap-<version>-unsigned.dmg
```

The script:

1. Reads `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `project.yml` and checks their format.
2. Builds the Release app with `xcodebuild`.
3. Checks that the built app's version matches `project.yml`.
4. Signs the app only if `DEVELOPER_ID_APPLICATION` is set (see [`SIGNING.md`](SIGNING.md)).
5. Creates the DMG with `hdiutil` (UDZO format).
6. Signs the DMG and notarizes and staples it only with `--notarize`, which also requires `NOTARY_PROFILE`.
7. Writes `ClaudeSwap-<version>.dmg.sha256` (or the `-unsigned` name) next to the DMG.

The artifact name tells the truth about its state: `ClaudeSwap-<version>.dmg` is signed, and `ClaudeSwap-<version>-unsigned.dmg` is not.

## Entitlements and sandbox

The app is distributed outside the Mac App Store and does **not** enable the App Sandbox. The wrapper starts the user's `cswap` process, which needs its own file and Keychain access. Signed builds use the hardened runtime (`codesign --options runtime`). No entitlements file is needed for release 1.

## Not included

- Auto-update. There is no updater and no appcast. The app's Settings › Updates pane says automatic updates are not available and links to GitHub Releases.
- Helper executables, Python packaging, PyInstaller, and per-architecture engine builds.

The release workflow maps its secrets onto the script: `CODESIGN_CERT_P12_BASE64` and `CODESIGN_CERT_PASSWORD` are imported into a temporary keychain, `CODESIGN_IDENTITY` is passed as `DEVELOPER_ID_APPLICATION`, and `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_SPECIFIC_PASSWORD` are stored as a `notarytool` keychain profile whose name is exported as `NOTARY_PROFILE`. Without them the workflow builds an unsigned DMG. This path has not been run yet.
