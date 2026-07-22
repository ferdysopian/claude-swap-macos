#!/usr/bin/env bash
# package-release.sh — build a Release .app with the core helper embedded,
# (optionally) sign + notarize, and produce a distributable DMG + checksums
# + an appcast item snippet for Sparkle.
#
# ── Bundle layout (must match ClaudeSwap/CoreBridge/BridgeProcess.swift) ───
# `HelperLocator` resolves the bundled helper via
# `Bundle.main.url(forAuxiliaryExecutable: "claude-swap-helper")`, which is
# Foundation's API for "the executable named X next to the app's main binary
# in Contents/MacOS/". That means:
#   - There is exactly ONE helper binary in the bundle, at a fixed path
#     (Contents/MacOS/<helper.binaryName from the lock file>) — NOT a
#     per-architecture subdirectory, and Swift does no runtime arch
#     selection of its own.
#   - That helper binary's architecture(s) must cover whatever architecture
#     the app process itself is running as, or the OS can't launch it
#     (Rosetta 2 translates x86_64->arm64, never the reverse).
#
# Consequently there are exactly two correct ways to ship this app across
# both Apple Silicon and Intel Macs:
#
#   1. (--arch universal2, single DMG) Build a genuinely fat/universal2
#      helper (see build-core-helper.sh's universal2 caveats — this needs a
#      universal2 Python + universal2 wheels for every dependency) and a
#      universal2 app (Xcode's default ARCHS for a modern macOS target).
#      One .app, one DMG, works everywhere.
#
#   2. (--arch dual, two DMGs — default, always works) Build two complete,
#      architecture-consistent app+helper pairs — one arm64-only, one
#      x86_64-only (build-app.sh --arch <x> forces ARCHS=<x>) — and produce
#      two separate DMGs (ClaudeSwap-<version>-arm64.dmg /
#      -x86_64.dmg). Requires no universal2 wheels. Users pick the DMG
#      matching their Mac, the same way many other native Mac apps ship.
#
# --arch arm64 / --arch x86_64 build+package just that one single-arch pair
# (useful for CI matrix legs that only need one).
#
# Env vars consulted (all optional; unsigned path used when absent — see
# docs/SIGNING.md):
#   CODESIGN_IDENTITY, APPLE_TEAM_ID, APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD,
#   SPARKLE_PRIVATE_KEY, SPARKLE_SIGN_UPDATE_BIN
#
# CS_PREBUILT_HELPER_ARM64 / CS_PREBUILT_HELPER_X86_64 (optional): if set,
# skip calling build-core-helper.sh for that architecture and use this
# pre-built --output directory instead (i.e. the same layout
# build-core-helper.sh itself produces: <dir>/<binaryName>/<binaryName> +
# <dir>/<binaryName>/_internal/). release.yml sets these after downloading
# the matrix job's artifacts, so the packaging job (a single Apple Silicon
# runner) never has to cross-build the x86_64 helper itself — it just
# assembles what the Intel-labeled runner already built.
#
# Usage:
#   scripts/package-release.sh [--config Release] [--version 0.1.0]
#                               [--arch dual|universal2|arm64|x86_64] [--output dist/]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG="Release"
SCHEME="ClaudeSwap"
VERSION=""
ARCH_MODE="dual"
OUTPUT_DIR="$CS_DIST_DIR"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --arch) ARCH_MODE="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cs_die "Unknown argument: $1" ;;
  esac
done

case "$ARCH_MODE" in
  dual|universal2|arm64|x86_64) ;;
  *) cs_die "--arch must be dual, universal2, arm64, or x86_64 (got '$ARCH_MODE')" ;;
esac

mkdir -p "$OUTPUT_DIR"

# Bail out early (exit 0) only for the "not scaffolded yet" case — the same
# gate build-app.sh itself uses — so we don't waste time freezing helpers
# for nothing. Any failure *after* this point (project exists) is a real
# build problem and should fail the script (exit 1), not be swallowed.
if [[ ! -f "$CS_REPO_ROOT/ClaudeSwap.xcodeproj/project.pbxproj" && ! -f "$CS_REPO_ROOT/ClaudeSwap.xcworkspace/contents.xcworkspacedata" ]]; then
  cs_warn "ClaudeSwap.xcodeproj/.xcworkspace not fully scaffolded yet — nothing to package."
  cs_warn "This is expected while the Xcode project is still being scaffolded. Skipping."
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(git -C "$CS_REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")"
fi
cs_log "Packaging version: $VERSION (--arch $ARCH_MODE)"

HELPER_BINARY_NAME="$(cs_lock_get 'helper.binaryName' 'claude-swap-helper')"

# --- CoreBuildInfo.json: fill in real values for the build, then restore ---
# ClaudeSwap/Resources/CoreBuildInfo.json  is a template
# that this script is expected to overwrite with real pinned values before
# the Xcode build's "Copy Bundle Resources" phase picks it up, then restore
# afterwards so a local run of this script doesn't leave a dirty working
# tree. See docs/PACKAGING.md.
CORE_BUILD_INFO="$CS_REPO_ROOT/ClaudeSwap/Resources/CoreBuildInfo.json"
CORE_BUILD_INFO_BACKUP=""
restore_core_build_info() {
  if [[ -n "$CORE_BUILD_INFO_BACKUP" && -f "$CORE_BUILD_INFO_BACKUP" ]]; then
    mv "$CORE_BUILD_INFO_BACKUP" "$CORE_BUILD_INFO"
  fi
}

if [[ -f "$CORE_BUILD_INFO" ]]; then
  CORE_BUILD_INFO_BACKUP="$(mktemp -t claude-swap-core-build-info-backup)"
  cp "$CORE_BUILD_INFO" "$CORE_BUILD_INFO_BACKUP"
  trap restore_core_build_info EXIT

  CORE_REPO="$(cs_lock_get repository '')"
  CORE_REF="$(cs_lock_get tag '')"
  [[ -z "$CORE_REF" ]] && CORE_REF="$(cs_lock_get commitSha '')"
  CORE_PKG_VERSION="$(cs_lock_get pythonPackageVersion '0.0.0')"
  CORE_BRIDGE_PROTOCOL_VERSION="$(cs_lock_get bridgeProtocolVersion '1')"
  BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  python3 - "$CORE_BUILD_INFO" "$CORE_PKG_VERSION" "$CORE_REPO" "$CORE_REF" "$CORE_BRIDGE_PROTOCOL_VERSION" "$BUILT_AT" <<'PY'
import json, sys
path, version, source, ref, protocol_version, built_at = sys.argv[1:7]
with open(path) as f:
    data = json.load(f)
data["coreVersion"] = version
data["coreSource"] = source
data["coreRef"] = ref
data["protocolVersion"] = int(protocol_version)
data["builtAt"] = built_at
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  cs_log "Wrote real pin info into ClaudeSwap/Resources/CoreBuildInfo.json (will restore template on exit)."
else
  cs_warn "ClaudeSwap/Resources/CoreBuildInfo.json not found — skipping (nothing to fill in yet)."
fi

# --- per-architecture build+package -----------------------------------------

package_one_arch() {
  local arch="$1" # arm64 | x86_64 | universal2
  local suffix="$2" # filename suffix, e.g. "-arm64", "" for universal2

  cs_log "=== Building for $arch ==="

  local helper_out="$CS_BUILD_DIR/core-helper-$arch"
  # ${var^^} (bash 4+) isn't available in macOS's stock /bin/bash (3.2), so
  # uppercase via tr instead.
  local arch_upper
  arch_upper="$(printf '%s' "$arch" | tr '[:lower:]' '[:upper:]')"
  local prebuilt_var="CS_PREBUILT_HELPER_${arch_upper}" # e.g. CS_PREBUILT_HELPER_ARM64
  local prebuilt="${!prebuilt_var:-}"

  if [[ -n "$prebuilt" ]]; then
    cs_log "Using pre-built helper for $arch from $prebuilt (skipping build-core-helper.sh)."
    helper_out="$prebuilt"
  elif ! "$CS_SCRIPTS_DIR/build-core-helper.sh" --arch "$arch" --output "$helper_out"; then
    cs_warn "build-core-helper.sh failed for $arch (e.g. no matching-arch Python available on this host —"
    cs_warn "see the cross-arch note in build-core-helper.sh). Skipping this architecture, not aborting the whole run."
    return 1
  fi
  local helper_bin="$helper_out/$HELPER_BINARY_NAME/$HELPER_BINARY_NAME"
  if [[ ! -x "$helper_bin" ]]; then
    cs_warn "Expected helper binary at $helper_bin but it's missing. Skipping $arch."
    return 1
  fi

  local derived_data="$CS_BUILD_DIR/DerivedData-release-$arch"
  local build_arch_flag=()
  [[ "$arch" != "universal2" ]] && build_arch_flag=(--arch "$arch")
  if ! "$CS_SCRIPTS_DIR/build-app.sh" --config "$CONFIG" --scheme "$SCHEME" --action build \
    --derived-data-path "$derived_data" ${build_arch_flag[@]+"${build_arch_flag[@]}"}; then
    cs_warn "build-app.sh failed for $arch. Skipping this architecture, not aborting the whole run."
    return 1
  fi

  local app_path="$derived_data/Build/Products/$CONFIG/$SCHEME.app"
  if [[ ! -d "$app_path" ]]; then
    cs_warn "No $SCHEME.app produced for $arch (Xcode project probably doesn't exist yet). Skipping this leg."
    return 1
  fi
  cs_log "App ($arch): $app_path"

  # Embed the helper. build-core-helper.sh runs PyInstaller in --onedir mode,
  # producing <helper_dir>/<binary> (the executable) + <helper_dir>/_internal/
  # (Python's shared library, compiled extension modules, and pure-Python
  # support files).
  #
  # PyInstaller's bootloader auto-detects when the executable's parent
  # directory matches the pattern "*.app/Contents/MacOS" and, in that case
  # ONLY, relocates where it looks for that support directory: instead of
  # "<exe_dir>/_internal" it looks at "<Contents>/Frameworks" — this is the
  # same relocation PyInstaller's own macOS BUNDLE (.app) target performs,
  # and the bootloader applies it unconditionally based on the path alone,
  # regardless of who actually assembled the containing .app (see
  # PyInstaller's `pyi_main.c` / the 6.0 "Let there be symlinks" change).
  # Concretely this means embedding _internal/'s contents *inside*
  # Contents/MacOS/ (e.g. Contents/MacOS/_internal/...) does NOT work — the
  # bootloader won't look there — and produces a
  # "Failed to load Python shared library" crash at launch. The contents of
  # _internal/ must instead land flat at Contents/Frameworks/.
  #
  # (PyInstaller's own BUNDLE target additionally splits pure-data files out
  # to Contents/Resources/ with cross-linking symlinks, purely to keep
  # Contents/Frameworks codesigning-tidy. We skip that cosmetic split here —
  # a flat copy of _internal/ into Contents/Frameworks/ is sufficient for
  # sys._MEIPASS resolution to work; every Mach-O file under it still gets
  # signed individually below when CODESIGN_IDENTITY is set.)
  local helper_dir="$helper_out/$HELPER_BINARY_NAME"
  local dest="$app_path/Contents/MacOS/$HELPER_BINARY_NAME"
  mkdir -p "$app_path/Contents/Frameworks"
  cp -R "$helper_dir/_internal/." "$app_path/Contents/Frameworks/"
  cp "$helper_dir/$HELPER_BINARY_NAME" "$dest"
  chmod +x "$dest"
  cs_log "Embedded helper executable at Contents/MacOS/, support files at Contents/Frameworks/"
  file "$dest" || true

  local signed=0
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    cs_log "Signing helper support files + executable + app ($arch) ..."
    # codesign --deep on the outer .app mainly walks nested *bundles*
    # (frameworks/plugins); the helper's relocated support files under
    # Contents/Frameworks/ are mostly loose dylibs/.so (plus untouched pure
    # data/.py files that don't need signing), so sign every Mach-O found
    # there explicitly before signing the app itself.
    find "$app_path/Contents/Frameworks" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null \
      | xargs -0 -I{} codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" {}
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$dest"
    codesign --force --deep --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    signed=1
  else
    cs_warn "CODESIGN_IDENTITY not set — producing an UNSIGNED build for $arch."
  fi

  local dmg_suffix="$suffix"
  [[ "$signed" == "0" ]] && dmg_suffix="${dmg_suffix}-unsigned"
  local dmg_name="ClaudeSwap-${VERSION}${dmg_suffix}.dmg"
  local dmg_path="$OUTPUT_DIR/$dmg_name"
  local staging="$CS_BUILD_DIR/dmg-staging-$arch"
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -R "$app_path" "$staging/"
  ln -sf /Applications "$staging/Applications"

  cs_log "Creating DMG: $dmg_path"
  rm -f "$dmg_path"
  hdiutil create -volname "ClaudeSwap $VERSION" -srcfolder "$staging" -ov -format UDZO "$dmg_path" >/dev/null

  if [[ "$signed" == "1" && -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    cs_log "Notarizing $dmg_name ..."
    xcrun notarytool submit "$dmg_path" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
    xcrun stapler staple "$dmg_path"
  elif [[ "$signed" == "1" ]]; then
    cs_warn "Signed but notarization credentials not fully set — skipping notarization for $arch."
  fi

  ( cd "$OUTPUT_DIR" && shasum -a 256 "$dmg_name" > "${dmg_name}.sha256" )
  cs_log "Checksum: $OUTPUT_DIR/${dmg_name}.sha256"

  write_appcast_item "$dmg_path" "$dmg_name" "$suffix"
  return 0
}

write_appcast_item() {
  local dmg_path="$1" dmg_name="$2" suffix="$3"
  local dmg_size
  dmg_size="$(stat -f%z "$dmg_path")"
  local appcast_item_path="$OUTPUT_DIR/appcast-item-${VERSION}${suffix}.xml"
  local ed_signature="TODO-SIGN-WITH-sign_update"

  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" && -n "${SPARKLE_SIGN_UPDATE_BIN:-}" && -x "${SPARKLE_SIGN_UPDATE_BIN:-}" ]]; then
    ed_signature="$("$SPARKLE_SIGN_UPDATE_BIN" --ed-key-file <(printf '%s' "$SPARKLE_PRIVATE_KEY") "$dmg_path" | grep -o 'sparkle:edSignature="[^"]*"' | sed -E 's/.*"(.*)"/\1/')"
  else
    cs_warn "SPARKLE_PRIVATE_KEY / SPARKLE_SIGN_UPDATE_BIN not both set — leaving appcast signature as a placeholder for $dmg_name."
  fi

  cat > "$appcast_item_path" <<EOF
<!-- Paste into the <channel> of your hosted appcast.xml. See docs/PACKAGING.md
     for the full appcast URL pattern and docs/SIGNING.md for SPARKLE_PRIVATE_KEY. -->
<item>
  <title>Version ${VERSION}</title>
  <sparkle:version>${VERSION}</sparkle:version>
  <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
  <enclosure
    url="https://github.com/OWNER/REPO/releases/download/v${VERSION}/${dmg_name}"
    length="${dmg_size}"
    type="application/octet-stream"
    sparkle:edSignature="${ed_signature}" />
</item>
EOF
  cs_log "Appcast item snippet: $appcast_item_path"
}

ANY_BUILT=0
case "$ARCH_MODE" in
  dual)
    package_one_arch arm64 "-arm64" && ANY_BUILT=1
    package_one_arch x86_64 "-x86_64" && ANY_BUILT=1
    ;;
  universal2)
    package_one_arch universal2 "" && ANY_BUILT=1
    ;;
  arm64|x86_64)
    package_one_arch "$ARCH_MODE" "-$ARCH_MODE" && ANY_BUILT=1
    ;;
esac

if [[ "$ANY_BUILT" == "0" ]]; then
  # We already confirmed the Xcode project exists (see the early gate above),
  # so a build producing nothing at this point is a real failure, not the
  # parallel-scaffolding no-op case.
  cs_die "No app was produced for any requested architecture ($ARCH_MODE). See warnings above for the cause."
fi

cs_log "Done. Artifacts in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"
