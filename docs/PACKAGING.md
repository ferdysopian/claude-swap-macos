# Packaging & Build Pipeline

This document explains how `claude-swap-macos` goes from source to a distributable DMG. It's owned by the Packaging/CI/Release role (`scripts/**`, `Dependencies/**`, `.github/workflows/**`). See also:

- [`docs/SIGNING.md`](SIGNING.md) — code signing, notarization, entitlements, required secrets
- [`docs/UPDATING-CORE.md`](UPDATING-CORE.md) — how the bundled Python core version is pinned/updated
- [`docs/adr/0001-bundled-python-helper.md`](adr/0001-bundled-python-helper.md) — why the app bundles a Python helper instead of a full Swift rewrite

## Why a Python helper exists

`ClaudeSwap.app` is a native SwiftUI/AppKit menu-bar app, but the actual account-switching logic lives in the existing, well-tested `claude-swap` Python package (canonical repo: https://github.com/realiti4/claude-swap, configurable). Rather than reimplement that logic in Swift, the app bundles a frozen (PyInstaller) copy of the core as a helper executable and talks to it over a small stdin/stdout JSON protocol (`contracts/**`). See the ADR for the full rationale.

This means packaging has two moving parts instead of one:

1. **The Python core helper** — frozen per architecture with `scripts/build-core-helper.sh`.
2. **The Swift app** — built with `scripts/build-app.sh` via `xcodebuild`.

`scripts/package-release.sh` orchestrates both, embeds the helper(s) into the app bundle, and produces the final DMG.

## Dependencies/CoreDependency.lock.json

The exact core revision bundled into any given build is pinned in [`Dependencies/CoreDependency.lock.json`](../Dependencies/CoreDependency.lock.json), validated against [`Dependencies/CoreDependency.schema.json`](../Dependencies/CoreDependency.schema.json). Key fields:

| Field | Meaning |
|---|---|
| `repository` | HTTPS clone URL of the core (configurable, e.g. for forks) |
| `tag` / `commitSha` | The exact pinned revision. Never a branch name. |
| `pythonPackageVersion` | `[project.version]` from the core's `pyproject.toml` at that revision |
| `bridgeProtocolVersion` | Version of the NDJSON bridge protocol the helper implements |
| `helperBuildVersion` | Counter bumped every time the helper is re-built from a new pin |
| `helper.entryPointCandidates` | Ordered list of Python entry points `build-core-helper.sh` tries; lets scripts work before `claude_swap.bridge` lands, and automatically prefer it once it does |
| `localOverride` | Path to a local checkout used instead of fetching+pinning, for day-to-day development |

Never hand-edit `commitSha` alone — always go through `scripts/update-core.sh` (see UPDATING-CORE.md) so tag/sha/version/tests stay consistent.

## Local development quick start

```sh
scripts/bootstrap.sh # sanity-checks toolchain, validates the lock file, sets up a helper build venv
scripts/build-core-helper.sh # freezes the core for your host architecture into dist/core-helper/<arch>/
scripts/build-app.sh --config Debug --action build # unsigned Debug build via xcodebuild
scripts/build-app.sh --config Debug --action test # unsigned Debug test run
scripts/package-release.sh # Release build + both helper arches embedded + DMG (unsigned unless signing env vars are set)
```

All of the above work entirely offline once `localOverride` in the lock file points at a local `claude-swap` checkout (it defaults to the sibling checkout used during this project's initial development; scripts fall back to `<parent-of-this-repo>/claude-swap` automatically if that path doesn't exist on your machine).

## Building the core helper

`scripts/build-core-helper.sh` uses [PyInstaller](https://pyinstaller.org/) in `--onedir` mode (better DMG compression than `--onefile`, and avoids `--onefile`'s runtime self-extraction overhead on every launch).

**Read the caveats at the top of that script before touching `--arch`.** Summary: PyInstaller does **not** support `lipo`-merging two separately-built single-arch executables into a working universal2 binary — that's a documented upstream limitation, not a bug here.

There's a second constraint that shapes the packaging strategy: `ClaudeSwap/CoreBridge/BridgeProcess.swift`'s `HelperLocator` finds the bundled helper via `Bundle.main.url(forAuxiliaryExecutable: "claude-swap-helper")` — Foundation's API for "the one executable with this exact name next to the app's main binary in `Contents/MacOS/`". There's no runtime architecture branching on the Swift side; it expects exactly one fixed-name helper binary. So the two supported ways to cover both Apple Silicon and Intel are:

1. **(default, `--arch dual` in `package-release.sh`, always works) Two separate app+DMG pairs.** Build a fully single-architecture app (`build-app.sh --arch <x>` forces `ARCHS=<x>`) with a matching single-arch helper (`build-core-helper.sh --arch <x>`) embedded in it, once for `arm64` and once for `x86_64`. This produces `ClaudeSwap-<version>-arm64.dmg` and `ClaudeSwap-<version>-x86_64.dmg`; users grab the one matching their Mac (the same pattern many native Mac apps use). Requires no universal2 wheels. CI (`release.yml`) uses this: an Apple Silicon runner builds the `arm64` helper artifact and an Intel-labeled runner builds the `x86_64` one, and the packaging job assembles both DMGs — never calling `lipo` on the PyInstaller output.
2. **(`--arch universal2`, single DMG) One genuinely fat app+helper.** Build the app with the project's default `ARCHS` (universal2 for a modern macOS target — Swift, unlike PyInstaller, supports this natively) and the helper via PyInstaller's own `--target-arch universal2`, which requires a universal2 Python (the official python.org "macOS 64-bit universal2 installer" — not Homebrew's single-arch builds) *and* every non-pure-Python dependency to ship universal2 wheels. PyInstaller fails loudly (`IncompatibleBinaryArchError`) rather than silently producing something broken if a dependency isn't fat; if you hit that, fall back to option 1.

### How the helper is actually embedded (and why it's not just a file copy)

`build-core-helper.sh` produces PyInstaller `--onedir` output: `<binary>` (the executable) plus a sibling `_internal/` directory holding the Python shared library, compiled extension modules, and the pure-Python `claude_swap` package itself. PyInstaller's bootloader has special-cased macOS `.app` detection: whenever the executable's parent directory matches `*.app/Contents/MacOS`, it looks for its support files at `Contents/Frameworks/` instead of `<exe_dir>/_internal/` — regardless of who assembled that `.app` (this is the same relocation PyInstaller's own `--windowed`/BUNDLE target performs, applied unconditionally based on the path alone). `package-release.sh` therefore:

- copies the helper executable to `Contents/MacOS/<helper.binaryName>` (matching `HelperLocator` exactly), and
- copies the *contents* of `_internal/` flat into `Contents/Frameworks/` (not into a nested `Contents/MacOS/_internal/`, which the bootloader won't look at and fails with "Failed to load Python shared library").

Getting this wrong is a silent-until-runtime failure — the build succeeds, codesigning succeeds, and the helper only fails when the Swift app actually tries to launch it. If you ever hand-roll packaging outside `package-release.sh`, verify by running the embedded binary directly: `ClaudeSwap.app/Contents/MacOS/claude-swap-helper --help` should print its argparse usage, not a `PYI-...` loader error.

## Building the app

`scripts/build-app.sh` wraps `xcodebuild` with:

```
CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES
```

This always works, requires no certificate, and is what `ci.yml` uses for every PR. Signed builds happen later, only in `package-release.sh` / `release.yml`, and only if signing credentials are present (see SIGNING.md).

If `ClaudeSwap.xcodeproj` doesn't yet have a `project.pbxproj` (e.g. while the Xcode project scaffolding is still in progress), `build-app.sh` and `package-release.sh` print a warning and exit `0` rather than failing CI. Once the project exists, they build for real.

The Xcode project itself should target **universal2** (`ARCHS = $(ARCHS_STANDARD)`, which defaults to arm64+x86_64 for modern macOS app targets) — Swift, unlike PyInstaller, fully supports building genuinely universal binaries in one pass, so this only concerns the Xcode project settings, not these scripts.

## Packaging a release DMG

`scripts/package-release.sh` (default `--arch dual`, i.e. once per architecture):

1. Builds the core helper for that architecture.
2. Builds the Release app for that same architecture via `build-app.sh --arch <x>`.
3. Embeds the helper: executable at `Contents/MacOS/<binaryName>`, its support files at `Contents/Frameworks/` (see above — this split is required, not cosmetic).
4. Signs + notarizes **only if** the relevant env vars are set (see SIGNING.md); otherwise produces `ClaudeSwap-<version>-<arch>-unsigned.dmg` and clearly says so in its output. No certificate is ever invented.
5. Creates the DMG with `hdiutil` (a simple `.app` + `Applications` symlink layout — no extra tooling required).
6. Writes a `sha256` checksum file next to the DMG.
7. Writes an `appcast-item-<version>-<arch>.xml` snippet for Sparkle (see below) — with a `TODO-SIGN-WITH-sign_update` placeholder signature if `SPARKLE_PRIVATE_KEY` isn't configured, so it's obvious the update feed isn't ready rather than silently shipping something that looks legitimate.
8. Before building (step 2) it also fills real pin values into `ClaudeSwap/Resources/CoreBuildInfo.json` — a small runtime-readable manifest `AppModel` can display in the About/Settings screen — then restores the checked-in template afterwards so a local run never leaves your working tree dirty.

## Sparkle 2 (auto-updates)

The Swift app itself wires up `SPUStandardUpdaterController` (via `UpdateService`). This doc covers the packaging side: how the update feed is produced and hosted.

**SPM integration** (done once, in Xcode, in the Xcode project; not by these scripts, since `Package.resolved` lives inside the `.xcodeproj`/`.xcworkspace` bundle):

1. Xcode → File → Add Package Dependencies… → `https://github.com/sparkle-project/Sparkle`
2. Dependency rule: pin an **exact version** for reproducibility (check https://github.com/sparkle-project/Sparkle/releases for the current release — 2.9.4 at the time this doc was written) rather than "Up to Next Major Version", so a Sparkle release can't silently change your update/signing behavior between builds.
3. Add the `Sparkle` library product to the `ClaudeSwap` app target.

If your workflow instead needs a standalone `Package.swift` (e.g. a shared framework target), the binary-target form Sparkle publishes looks like:

```swift
// swift-tools-version:5.3
import PackageDescription

let package = Package(
 name: "Sparkle",
 platforms: [.macOS(.v12)],
 products: [.library(name: "Sparkle", targets: ["Sparkle"])],
 targets: [
 .binaryTarget(
 name: "Sparkle",
 url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip",
 checksum: "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
)
 ]
)
```

Verify the checksum against the release you actually pin before trusting it — don't copy the value above without checking it matches the version you chose.

**Appcast URL pattern.** Host `appcast.xml` somewhere with HTTPS (Sparkle requires it — see [App Transport Security](https://sparkle-project.org/documentation/app-transport-security/)). Two common, low-maintenance options for an open-source GitHub project:

- **GitHub Releases, stable URL**: `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`, uploaded as a release asset by `release.yml` alongside the DMG. Simple, no extra hosting, but only reflects the *latest* release unless you maintain the full `<channel>` history yourself across releases.
- **GitHub Pages**: `https://<owner>.github.io/<repo>/appcast.xml`, generated/updated by a small step you maintain that appends each new `<item>` (the snippet `package-release.sh` writes) to a persisted `appcast.xml` history. More setup, but gives you a real rolling update feed with old versions still resolvable.

Whichever you choose, set that URL as `SUFeedURL` in the app's `Info.plist` and keep it consistent with wherever `release.yml` actually uploads the DMG + `appcast-item-*.xml`.

**Signing the feed.** Sparkle 2 uses ed25519 (EdDSA) signatures per update, generated by Sparkle's own `generate_keys` / `sign_update` command-line tools (shipped in Sparkle's `Sparkle-distribution-*.tar.xz` release asset, not something these scripts build). See [`docs/SIGNING.md`](SIGNING.md) for the required `SPARKLE_PRIVATE_KEY` secret and how `package-release.sh` uses it.

## Not distributed via the Mac App Store; no App Sandbox

`ClaudeSwap.app` is Developer-ID distributed (notarized DMG), **not** submitted to the Mac App Store, and does **not** enable the App Sandbox entitlement. This is intentional, not an oversight:

- The app (via its bundled helper) needs the same Keychain access as the `claude-swap` CLI tool uses today for credential storage — under the App Sandbox, Keychain access is scoped per-app-group and cross-tool sharing with the CLI's existing keychain items would require re-architecting how credentials are stored.
- It needs unrestricted read/write access to `~/.claude/` (the real, user-visible path Claude Code itself uses) to perform account swaps — under the App Sandbox this would require either a security-scoped bookmark the user re-grants every time, or a sandboxed container path that isn't actually `~/.claude`, defeating the point of the tool.
- It spawns a subprocess helper and talks to it over stdio — sandboxed apps can do this, but combined with the above two points, sandboxing doesn't buy meaningful additional safety here while it would materially break functionality.

See [`docs/SIGNING.md`](SIGNING.md) for exactly which entitlements the app *does* need (hardened runtime, not sandboxed) and why.

## Directory / script reference

| Path | Purpose |
|---|---|
| `scripts/bootstrap.sh` | One-shot dev environment setup |
| `scripts/build-core-helper.sh` | Freeze the Python core into a helper executable |
| `scripts/update-core.sh` | Re-pin the core to an explicit tag/sha (tests + smoke-builds first) |
| `scripts/verify-core.sh` | Validate `Dependencies/CoreDependency.lock.json` (used by CI) |
| `scripts/build-app.sh` | Unsigned `xcodebuild` build/test |
| `scripts/package-release.sh` | Full release packaging: helper(s) + app + sign/notarize (if configured) + DMG + appcast item |
| `Dependencies/CoreDependency.lock.json` | The pin (see above) |
| `.github/workflows/ci.yml` | PR verification — lock validation, unsigned Swift build/test, shellcheck |
| `.github/workflows/release.yml` | Tag-triggered release pipeline |
| `.github/workflows/update-core.yml` | `workflow_dispatch` to bump the core pin via PR |
