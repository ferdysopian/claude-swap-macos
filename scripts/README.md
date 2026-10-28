# scripts/

Build, check, and packaging scripts for `claude-swap-macos`. Run them from the repository root. See [`../docs/PACKAGING.md`](../docs/PACKAGING.md) and [`../docs/RELEASE.md`](../docs/RELEASE.md) for the release flow, and [`../docs/SIGNING.md`](../docs/SIGNING.md) for signing.

The release DMG contains only the wrapper app. The upstream `cswap` CLI is installed separately by users and is not built or bundled by any script here.

| Script | Purpose |
|---|---|
| `bootstrap.sh` | Developer setup. Installs XcodeGen if needed and regenerates `ClaudeSwap.xcodeproj` from `project.yml`. Run it first. |
| `build-app.sh` | `xcodebuild` wrapper. Usage: `scripts/build-app.sh [--config Debug\|Release] [--action build\|test\|ui-test] [--derived-data <dir>] [--arch arm64\|x86_64\|universal2]`. `build` and `test` use scheme `ClaudeSwap`; `ui-test` uses scheme `ClaudeSwapUITests` and needs a GUI session with Accessibility permission. DerivedData defaults to `build/DerivedData`. |
| `verify-metadata.sh` | Offline consistency checks: `CLICompatibility.json` shape, version values in `project.yml` against `project.pbxproj`, `Info.plist` version placeholders, no personal home paths in tracked config, and a single `Info.plist`. Add `--check-xcodegen` to regenerate the project into a temporary location and compare it with the committed project. CI runs this as the `metadata` job. |
| `package-release.sh` | Builds a Release app and packages it as a DMG with a SHA-256 file in `dist/`. Usage: `scripts/package-release.sh [--config Release] [--notarize] [--dry-run]`. `--dry-run` prints the version, artifact name, and planned steps without building. Signing happens only when `DEVELOPER_ID_APPLICATION` is set. Without it, the artifact is named `*-unsigned.dmg`. `--notarize` submits the DMG with `notarytool` and staples it; it requires `DEVELOPER_ID_APPLICATION` and `NOTARY_PROFILE`. |
| `lib/common.sh` | Shared shell helpers (logging, paths, reading `project.yml` settings). Sourced by the scripts above; not run directly. |
| `generate_app_icon.swift` | Generates the placeholder `AppIcon` artwork. Run it manually when the icon changes; it is not part of the build. |

## Quick start

```sh
scripts/bootstrap.sh
scripts/verify-metadata.sh --check-xcodegen
scripts/build-app.sh --config Debug --action build
scripts/build-app.sh --config Debug --action test
scripts/package-release.sh --dry-run
```

Shell lint, as run in CI:

```sh
(cd scripts && shellcheck -x ./*.sh ./lib/*.sh)
```

Every script supports `-h`/`--help`, which prints its header comment.
