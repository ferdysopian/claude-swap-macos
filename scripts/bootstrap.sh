#!/usr/bin/env bash
# bootstrap.sh — contributor setup for a fresh clone.
#
#   1. Checks that Xcode, xcodegen and python3 are present. It does NOT install
#      anything; missing tools get an install hint and the script stops.
#   2. Regenerates ClaudeSwap.xcodeproj from project.yml (the source of truth).
#   3. Runs scripts/verify-metadata.sh.
#
# The upstream `cswap` CLI is needed at runtime to manage accounts. It is not
# required to build the app, so this script only reports on it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MISSING=0

if xcodebuild -version >/dev/null 2>&1; then
  cs_log "Xcode: $(xcodebuild -version | head -n 1)"
else
  cs_err "Full Xcode not found (xcodebuild fails)."
  cs_err "  hint: install Xcode from the App Store, then run 'sudo xcode-select -s /Applications/Xcode.app'."
  MISSING=1
fi

if command -v xcodegen >/dev/null 2>&1; then
  cs_log "xcodegen: $(xcodegen --version 2>/dev/null | head -n 1)"
else
  cs_err "xcodegen not found."
  cs_err "  hint: brew install xcodegen"
  MISSING=1
fi

if command -v python3 >/dev/null 2>&1; then
  cs_log "python3: $(python3 --version 2>&1)"
else
  cs_err "python3 not found (used by verify-metadata.sh)."
  cs_err "  hint: xcode-select --install   or   brew install python@3.12"
  MISSING=1
fi

if command -v cswap >/dev/null 2>&1; then
  cs_log "cswap found at $(command -v cswap) (informational; needed at runtime only)"
else
  cs_warn "cswap not on PATH. Not needed to build, but the app needs the upstream CLI at runtime (https://github.com/realiti4/claude-swap)."
fi

if [[ "$MISSING" == "1" ]]; then
  cs_die "Install the missing tools above, then re-run scripts/bootstrap.sh."
fi

cs_log "Generating ClaudeSwap.xcodeproj from project.yml"
(cd "$CS_REPO_ROOT" && xcodegen generate --spec project.yml)

"$SCRIPT_DIR/verify-metadata.sh"

cs_log "Bootstrap complete. Next: scripts/build-app.sh --config Debug --action build"
