#!/usr/bin/env bash
# build-app.sh — build, unit-test, or UI-test ClaudeSwap.xcodeproj with
# xcodebuild. Unsigned: no signing identity or Apple credentials are used.
#
# Usage:
#   scripts/build-app.sh [--config Debug|Release] [--action build|test|ui-test]
#                         [--derived-data <dir>] [--arch arm64|x86_64|universal2]
#
#   build    scheme ClaudeSwap; builds the app. After a successful build, checks
#            that ClaudeSwap.app exists and that its Info.plist versions match
#            project.yml (MARKETING_VERSION / CURRENT_PROJECT_VERSION).
#   test     scheme ClaudeSwap, -only-testing:ClaudeSwapTests (unit tests only).
#   ui-test  scheme ClaudeSwapUITests, -only-testing:ClaudeSwapUITests.
#            Needs a logged-in GUI session with Accessibility permission, so it
#            is not part of CI.
#
#   --derived-data <dir>  DerivedData location (default: build/DerivedData).
#                         --derived-data-path is accepted as an alias.
#   --arch                forces a single-architecture build (ARCHS=<arch>
#                         ONLY_ACTIVE_ARCH=NO). Omit it for the project default.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG="Debug"
ACTION="build"
DERIVED_DATA_PATH="$CS_BUILD_DIR/DerivedData"
FORCE_ARCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --action) ACTION="$2"; shift 2 ;;
    --derived-data|--derived-data-path) DERIVED_DATA_PATH="$2"; shift 2 ;;
    --arch) FORCE_ARCH="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cs_die "Unknown argument: $1" ;;
  esac
done

case "$CONFIG" in
  Debug|Release) ;;
  *) cs_die "--config must be Debug or Release (got '$CONFIG')" ;;
esac

case "$FORCE_ARCH" in
  ""|universal2|arm64|x86_64) ;;
  *) cs_die "--arch must be arm64, x86_64, or universal2 (got '$FORCE_ARCH')" ;;
esac

case "$ACTION" in
  build)   SCHEME="ClaudeSwap";        ACTION_ARGS=(build) ;;
  test)    SCHEME="ClaudeSwap";        ACTION_ARGS=(test "-only-testing:ClaudeSwapTests") ;;
  ui-test) SCHEME="ClaudeSwapUITests"; ACTION_ARGS=(test "-only-testing:ClaudeSwapUITests") ;;
  *) cs_die "--action must be 'build', 'test' or 'ui-test' (got '$ACTION')" ;;
esac

PROJECT_PATH="$CS_REPO_ROOT/ClaudeSwap.xcodeproj"
if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
  cs_die "ClaudeSwap.xcodeproj/project.pbxproj not found. Run scripts/bootstrap.sh to generate it."
fi

cs_require_cmd xcodebuild "Install Xcode from the App Store, then run 'xcode-select --install'."

ARCH_OVERRIDE_ARGS=()
if [[ -n "$FORCE_ARCH" && "$FORCE_ARCH" != "universal2" ]]; then
  ARCH_OVERRIDE_ARGS=(ARCHS="$FORCE_ARCH" ONLY_ACTIVE_ARCH=NO)
  cs_log "Forcing single-architecture build: $FORCE_ARCH"
fi

mkdir -p "$DERIVED_DATA_PATH"

cs_log "xcodebuild -project ClaudeSwap.xcodeproj -scheme $SCHEME -configuration $CONFIG ${ACTION_ARGS[*]} (unsigned, DerivedData: $DERIVED_DATA_PATH)"

# CODE_SIGNING_ALLOWED=NO + CODE_SIGN_IDENTITY="-" guarantee this never
# requires (or invents) a certificate. This is the path CI always uses.
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  ${ARCH_OVERRIDE_ARGS[@]+"${ARCH_OVERRIDE_ARGS[@]}"} \
  "${ACTION_ARGS[@]}"

if [[ "$ACTION" != "build" ]]; then
  cs_log "$ACTION finished."
  exit 0
fi

# --- post-build: the produced app must exist and carry the project.yml version

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIG/ClaudeSwap.app"
APP_PLIST="$APP_PATH/Contents/Info.plist"
[[ -d "$APP_PATH" ]] || cs_die "Expected app bundle not found: $APP_PATH"
[[ -f "$APP_PLIST" ]] || cs_die "Info.plist missing inside app bundle: $APP_PLIST"

EXPECTED_VERSION="$(cs_project_setting MARKETING_VERSION)"
EXPECTED_BUILD="$(cs_project_setting CURRENT_PROJECT_VERSION)"
[[ -n "$EXPECTED_VERSION" && -n "$EXPECTED_BUILD" ]] || cs_die "Could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || true)"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST" 2>/dev/null || true)"

if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" || "$ACTUAL_BUILD" != "$EXPECTED_BUILD" ]]; then
  cs_die "Built app version mismatch: CFBundleShortVersionString='$ACTUAL_VERSION' (expected $EXPECTED_VERSION), CFBundleVersion='$ACTUAL_BUILD' (expected $EXPECTED_BUILD)"
fi

cs_log "Built: $APP_PATH (version $ACTUAL_VERSION, build $ACTUAL_BUILD)"
