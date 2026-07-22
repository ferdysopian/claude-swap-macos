#!/usr/bin/env bash
# build-app.sh — build (and optionally test) the ClaudeSwap.xcodeproj target
# with xcodebuild, unsigned by default. No signing identity or Apple
# credentials are required or used here.
#
# Gracefully no-ops (exit 0) if ClaudeSwap.xcodeproj doesn't exist yet, so CI
# doesn't hard-fail while the Xcode project is still being scaffolded
# in parallel. Once the project exists, it builds/tests for real.
#
# Usage:
#   scripts/build-app.sh [--config Debug|Release] [--scheme ClaudeSwap]
#                         [--action build|test] [--derived-data-path <dir>]
#                         [--arch arm64|x86_64|universal2]
#
#   --arch forces a single-architecture build (ARCHS=<arch> ONLY_ACTIVE_ARCH=NO)
#   instead of the project's default. Use this when the embedded core helper
#   (Contents/MacOS/claude-swap-helper, see build-core-helper.sh) is only
#   available as a thin single-arch binary, so the outer app matches it
#   exactly — see docs/PACKAGING.md for why this matters. Omit --arch (or
#   pass universal2) to use the project's own ARCHS setting, which should be
#   universal2 for a release meant to embed a genuinely fat helper binary.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG="Debug"
SCHEME="ClaudeSwap"
ACTION="build"
DERIVED_DATA_PATH="$CS_BUILD_DIR/DerivedData"
FORCE_ARCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --action) ACTION="$2"; shift 2 ;;
    --derived-data-path) DERIVED_DATA_PATH="$2"; shift 2 ;;
    --arch) FORCE_ARCH="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cs_die "Unknown argument: $1" ;;
  esac
done

case "$FORCE_ARCH" in
  ""|universal2|arm64|x86_64) ;;
  *) cs_die "--arch must be arm64, x86_64, or universal2 (got '$FORCE_ARCH')" ;;
esac

case "$ACTION" in
  build|test) ;;
  *) cs_die "--action must be 'build' or 'test' (got '$ACTION')" ;;
esac

PROJECT_PATH="$CS_REPO_ROOT/ClaudeSwap.xcodeproj"
WORKSPACE_PATH="$CS_REPO_ROOT/ClaudeSwap.xcworkspace"

# Check for the actual project/workspace manifest files, not just the
# directory — Xcode.app creates the .xcodeproj/.xcworkspace *bundle*
# directory up front while the project is still being scaffolded, well
# before project.pbxproj / contents.xcworkspacedata exist.
HAVE_PROJECT=0
[[ -f "$PROJECT_PATH/project.pbxproj" ]] && HAVE_PROJECT=1
HAVE_WORKSPACE=0
[[ -f "$WORKSPACE_PATH/contents.xcworkspacedata" ]] && HAVE_WORKSPACE=1

if [[ "$HAVE_PROJECT" == "0" && "$HAVE_WORKSPACE" == "0" ]]; then
  cs_warn "ClaudeSwap.xcodeproj/.xcworkspace not fully scaffolded yet (no project.pbxproj / contents.xcworkspacedata) — nothing to build."
  cs_warn "This is expected while the Xcode project is still being scaffolded. Skipping."
  exit 0
fi

cs_require_cmd xcodebuild "Install Xcode from the App Store, then run 'xcode-select --install'."

PROJECT_FLAGS=(-project "$PROJECT_PATH")
[[ "$HAVE_WORKSPACE" == "1" ]] && PROJECT_FLAGS=(-workspace "$WORKSPACE_PATH")

mkdir -p "$DERIVED_DATA_PATH"

ARCH_OVERRIDE_ARGS=()
if [[ -n "$FORCE_ARCH" && "$FORCE_ARCH" != "universal2" ]]; then
  ARCH_OVERRIDE_ARGS=(ARCHS="$FORCE_ARCH" ONLY_ACTIVE_ARCH=NO)
  cs_log "Forcing single-architecture build: $FORCE_ARCH"
fi

cs_log "xcodebuild ${PROJECT_FLAGS[*]} -scheme $SCHEME -configuration $CONFIG $ACTION (unsigned)"

# CODE_SIGNING_ALLOWED=NO + CODE_SIGN_IDENTITY="-" guarantee this never
# requires (or invents) a certificate. This is the path CI always uses.
set -x
xcodebuild \
  "${PROJECT_FLAGS[@]}" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  ${ARCH_OVERRIDE_ARGS[@]+"${ARCH_OVERRIDE_ARGS[@]}"} \
  "$ACTION"
set +x

if [[ "$ACTION" == "build" ]]; then
  APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIG/$SCHEME.app"
  if [[ -d "$APP_PATH" ]]; then
    cs_log "Built: $APP_PATH"
  fi
fi
