# Signing and notarization

Related: [`PACKAGING.md`](PACKAGING.md), [`RELEASE.md`](RELEASE.md).

## The unsigned path is the default

Nothing in this repository needs an Apple Developer certificate to build, test, or package:

- `scripts/build-app.sh` builds with code signing disabled.
- `scripts/package-release.sh` signs only if `DEVELOPER_ID_APPLICATION` is set. Otherwise it produces `ClaudeSwap-<version>-unsigned.dmg` and says so in its output.
- The `ci.yml` workflow uses no secrets.
- No script creates, fakes, or guesses a certificate or signature.

An unsigned or un-notarized app is blocked by Gatekeeper on first launch. Users who choose to run an unsigned experimental build should:

1. Verify the SHA-256 checksum (`shasum -a 256 -c <file>.sha256`).
2. Use **right-click → Open**, or open **System Settings → Privacy & Security** and choose **Open Anyway** for Claude Swap.

Do not tell users to disable Gatekeeper globally.

## Signing

Signing needs an Apple Developer Program membership and a **Developer ID Application** certificate in the signing machine's keychain.

`scripts/package-release.sh` uses:

| Variable | Use |
|---|---|
| `DEVELOPER_ID_APPLICATION` | Signing identity, for example `Developer ID Application: Name (TEAMID)`. Setting it enables signing. |

When it is set, the script runs `codesign --force --options runtime --timestamp --sign <identity>` on the app and checks it with `codesign --verify --strict`, then signs the DMG.

## Notarization

Notarization runs only with `scripts/package-release.sh --notarize`, which requires both `DEVELOPER_ID_APPLICATION` and `NOTARY_PROFILE`.

`NOTARY_PROFILE` is the name of a `notarytool` keychain profile. Create it once on the signing machine with Apple's tool (use your own Apple ID, team ID, and an app-specific password; never commit them):

```sh
xcrun notarytool store-credentials "<profile-name>"
```

The script then runs `xcrun notarytool submit <dmg> --keychain-profile <profile> --wait` and, if that succeeds, `xcrun stapler staple` and `xcrun stapler validate`. If notarization fails, the script stops and the DMG must not be published as notarized.

## Secrets for CI

`.github/workflows/release.yml` runs without any secrets and produces an unsigned DMG. Signing secrets are optional.

The release workflow maps its secrets onto the script: `CODESIGN_CERT_P12_BASE64` and `CODESIGN_CERT_PASSWORD` are imported into a temporary keychain, `CODESIGN_IDENTITY` is passed as `DEVELOPER_ID_APPLICATION`, and `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_SPECIFIC_PASSWORD` are stored as a `notarytool` keychain profile whose name is exported as `NOTARY_PROFILE`. Without them the workflow builds an unsigned DMG. This path has not been run yet.

## Entitlements

- The app does not enable `com.apple.security.app-sandbox`. See [`PACKAGING.md`](PACKAGING.md#entitlements-and-sandbox).
- Signed builds use the hardened runtime through `--options runtime`.
- Release 1 has no bundled executables other than the app itself, so no library-validation exception is expected. If that changes, revisit this section first.

## Checks before publishing a signed build

- `codesign --verify --strict --verbose=2 ClaudeSwap.app` passes.
- `spctl --assess --type execute --verbose ClaudeSwap.app` reports the expected result for a notarized app.
- For a notarized DMG: `xcrun stapler validate <dmg>` passes.
- The DMG's `.sha256` matches the file.
