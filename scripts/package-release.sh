#!/usr/bin/env bash
# package-release.sh — build a Release ClaudeSwap.app and package it as a DMG
# with a SHA-256 checksum file in dist/.
#
# Wrapper-only: the app drives the user's separately installed upstream `cswap`
# CLI, which is NOT bundled here. Nothing from upstream is built or embedded.
#
# Version comes from project.yml (MARKETING_VERSION / CURRENT_PROJECT_VERSION).
#
# Signing and notarization are optional and driven by env vars:
#   DEVELOPER_ID_APPLICATION  signing identity (e.g. "Developer ID Application: Name (TEAMID)").
#                             Unset/empty -> unsigned build, artifact named *-unsigned.dmg.
#   NOTARY_PROFILE            notarytool keychain profile name. Used only with --notarize,
#                             which also requires DEVELOPER_ID_APPLICATION.
#
# Usage:
#   scripts/package-release.sh [--config Release] [--notarize] [--dry-run]
#
#   --dry-run    print the plan (version, artifact name, steps) and exit without building.
#   --notarize   submit the DMG with notarytool, wait, then staple. Requires
#                DEVELOPER_ID_APPLICATION and NOTARY_PROFILE.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG="Release"
NOTARIZE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cs_die "Unknown argument: $1" ;;
  esac
done

case "$CONFIG" in
  Release|Debug) ;;
  *) cs_die "--config must be Release or Debug (got '$CONFIG')" ;;
esac

VERSION="$(cs_project_setting MARKETING_VERSION)"
BUILD_NUMBER="$(cs_project_setting CURRENT_PROJECT_VERSION)"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || cs_die "project.yml MARKETING_VERSION is not dotted numbers (got '$VERSION')"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || cs_die "project.yml CURRENT_PROJECT_VERSION is not an integer (got '$BUILD_NUMBER')"

SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE_NAME="${NOTARY_PROFILE:-}"

if [[ "$NOTARIZE" == "1" ]]; then
  [[ -n "$SIGN_IDENTITY" ]] || cs_die "--notarize requires DEVELOPER_ID_APPLICATION (notarization needs a signed app)."
  [[ -n "$NOTARY_PROFILE_NAME" ]] || cs_die "--notarize requires NOTARY_PROFILE (a notarytool keychain profile name)."
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  ARTIFACT_STATE="signed"
  DMG_NAME="ClaudeSwap-${VERSION}.dmg"
else
  ARTIFACT_STATE="unsigned"
  DMG_NAME="ClaudeSwap-${VERSION}-unsigned.dmg"
fi
if [[ "$NOTARIZE" == "1" ]]; then
  ARTIFACT_STATE="notarized (pending)"
fi

DERIVED_DATA="$CS_BUILD_DIR/release-DerivedData"
APP_SRC="$DERIVED_DATA/Build/Products/$CONFIG/ClaudeSwap.app"
STAGE_DIR="$CS_BUILD_DIR/dmg-stage"
DMG_PATH="$CS_DIST_DIR/$DMG_NAME"
SHA_PATH="$DMG_PATH.sha256"

if [[ "$DRY_RUN" == "1" ]]; then
  cs_log "DRY RUN: nothing will be built or written."
  cs_log "  version:         $VERSION (build $BUILD_NUMBER), from project.yml"
  cs_log "  configuration:   $CONFIG"
  cs_log "  build step:      xcodebuild -project ClaudeSwap.xcodeproj -scheme ClaudeSwap -configuration $CONFIG -destination 'platform=macOS' -derivedDataPath $DERIVED_DATA build (CODE_SIGNING_ALLOWED=NO)"
  cs_log "  verify app:      $APP_SRC has CFBundleShortVersionString=$VERSION and CFBundleVersion=$BUILD_NUMBER"
  if [[ "$ARTIFACT_STATE" == "signed" ]]; then
    cs_log "  signing:         codesign --force --options runtime --timestamp --sign <DEVELOPER_ID_APPLICATION>"
  else
    cs_warn "  signing:         NONE (DEVELOPER_ID_APPLICATION not set) -> unsigned artifact"
  fi
  if [[ "$NOTARIZE" == "1" ]]; then
    cs_log "  notarization:    xcrun notarytool submit <dmg> --keychain-profile <NOTARY_PROFILE> --wait; xcrun stapler staple <dmg>"
  else
    cs_log "  notarization:    skipped (pass --notarize with DEVELOPER_ID_APPLICATION and NOTARY_PROFILE)"
  fi
  cs_log "  DMG:             $DMG_PATH (hdiutil UDZO)"
  cs_log "  checksum:        $SHA_PATH (shasum -a 256)"
  exit 0
fi

cs_require_cmd xcodebuild "Install Xcode from the App Store, then run 'xcode-select --install'."
cs_require_cmd hdiutil
cs_require_cmd shasum
[[ "$NOTARIZE" == "0" ]] || cs_require_cmd xcrun
if [[ -n "$SIGN_IDENTITY" ]]; then
  cs_require_cmd codesign
fi

mkdir -p "$CS_DIST_DIR" "$CS_BUILD_DIR"

# --- 1. Release build (fresh derived data so a stale .app can never be packaged)

rm -rf "$DERIVED_DATA"
cs_log "Building ClaudeSwap $CONFIG $VERSION ($BUILD_NUMBER), unsigned by xcodebuild; signing is applied below if configured."
xcodebuild \
  -project "$CS_REPO_ROOT/ClaudeSwap.xcodeproj" \
  -scheme ClaudeSwap \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  build

# --- 2. The .app must exist and carry the project.yml version -----------

[[ -d "$APP_SRC" ]] || cs_die "App bundle missing after build: $APP_SRC"
APP_PLIST="$APP_SRC/Contents/Info.plist"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || true)"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST" 2>/dev/null || true)"
if [[ "$ACTUAL_VERSION" != "$VERSION" || "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
  cs_die "Version mismatch in built app: $ACTUAL_VERSION ($ACTUAL_BUILD), project.yml says $VERSION ($BUILD_NUMBER)"
fi

# --- 3. Optional signing (hardened runtime + secure timestamp) ----------

if [[ -n "$SIGN_IDENTITY" ]]; then
  cs_log "Signing ClaudeSwap.app with Developer ID (hardened runtime)."
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_SRC"
  codesign --verify --strict --verbose=2 "$APP_SRC"
else
  cs_warn "DEVELOPER_ID_APPLICATION not set: app is NOT signed."
fi

# --- 4. DMG -------------------------------------------------------------

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_SRC" "$STAGE_DIR/ClaudeSwap.app"
ln -s /Applications "$STAGE_DIR/Applications"
rm -f "$DMG_PATH" "$SHA_PATH"
cs_log "Creating DMG: $DMG_PATH"
hdiutil create -volname "Claude Swap $VERSION" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE_DIR"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

# --- 5. Optional notarization (only when asked and configured) ----------

if [[ "$NOTARIZE" == "1" ]]; then
  cs_log "Submitting DMG to Apple notary service (profile: $NOTARY_PROFILE_NAME); this waits for the result."
  if ! xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE_NAME" --wait; then
    cs_die "notarytool submit failed. The DMG is NOT notarized."
  fi
  xcrun stapler staple "$DMG_PATH" || cs_die "stapler staple failed. The DMG is NOT stapled."
  xcrun stapler validate "$DMG_PATH" || cs_die "stapler validate failed."
  ARTIFACT_STATE="signed and notarized"
fi

# --- 6. Checksum and final check ----------------------------------------

(cd "$CS_DIST_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")

[[ -f "$DMG_PATH" ]] || cs_die "DMG missing at end of packaging: $DMG_PATH"
[[ -f "$SHA_PATH" ]] || cs_die "Checksum missing at end of packaging: $SHA_PATH"

cs_log "Artifact: $DMG_PATH"
cs_log "Checksum: $SHA_PATH"
cs_log "Status:   $ARTIFACT_STATE"
if [[ "$ARTIFACT_STATE" == "unsigned" ]]; then
  cs_warn "UNSIGNED, NOT NOTARIZED. Experimental build only. macOS will warn on first launch."
  cs_warn "Do not distribute it as a signed or notarized release."
fi
