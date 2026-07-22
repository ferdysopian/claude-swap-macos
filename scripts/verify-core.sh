#!/usr/bin/env bash
# verify-core.sh — validate Dependencies/CoreDependency.lock.json and (best
# effort) the resolvability of the source it points at.
#
# Used by CI (ci.yml) on every PR. Never mutates anything, never touches the
# network unless --check-source is passed.
#
# Exit codes:
#   0  lock file is well-formed (a PENDING commitSha is a warning, not an
#      error, so CI stays green before the first real pin exists)
#   1  lock file is malformed / missing required fields / schema violation
#
# Usage:
#   scripts/verify-core.sh                 # schema + shape checks only (default, offline)
#   scripts/verify-core.sh --check-source   # also confirm the resolved core source exists on disk
#   scripts/verify-core.sh --require-pin    # fail if commitSha is still the PENDING placeholder

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CHECK_SOURCE=0
REQUIRE_PIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-source) CHECK_SOURCE=1; shift ;;
    --require-pin) REQUIRE_PIN=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) cs_die "Unknown argument: $1" ;;
  esac
done

[[ -f "$CS_LOCK_FILE" ]] || cs_die "Missing lock file: $CS_LOCK_FILE"

cs_log "Validating $(basename "$CS_LOCK_FILE") against schema ..."
if ! python3 "$CS_LOCK_PY" validate --lock "$CS_LOCK_FILE" --schema "$CS_REPO_ROOT/Dependencies/CoreDependency.schema.json"; then
  cs_die "Lock file failed validation (see errors above)."
fi

SHA="$(cs_lock_get commitSha)"
if [[ "$SHA" == PENDING* ]]; then
  if [[ "$REQUIRE_PIN" == "1" ]]; then
    cs_die "commitSha is still the placeholder and --require-pin was set. Run scripts/update-core.sh first."
  else
    cs_warn "commitSha is still unpinned (expected during early bootstrap; CI treats this as non-fatal)."
  fi
fi

# Cross-check bridgeProtocolVersion against contracts/ if one has been published.
CONTRACT_VERSION_FILE="$CS_REPO_ROOT/contracts/BRIDGE_PROTOCOL_VERSION"
if [[ -f "$CONTRACT_VERSION_FILE" ]]; then
  CONTRACT_VERSION="$(tr -d '[:space:]' < "$CONTRACT_VERSION_FILE")"
  LOCK_VERSION="$(cs_lock_get bridgeProtocolVersion)"
  if [[ -n "$CONTRACT_VERSION" && "$CONTRACT_VERSION" != "$LOCK_VERSION" ]]; then
    cs_die "bridgeProtocolVersion mismatch: lock=$LOCK_VERSION contracts/BRIDGE_PROTOCOL_VERSION=$CONTRACT_VERSION"
  fi
fi

if [[ "$CHECK_SOURCE" == "1" ]]; then
  cs_log "Resolving core source (localOverride or pinned commit) ..."
  if SRC="$(cs_resolve_core_source 0)"; then
    cs_log "Core source resolves to: $SRC"
  else
    if [[ "$REQUIRE_PIN" == "1" ]]; then
      cs_die "Could not resolve core source and --require-pin was set."
    else
      cs_warn "Could not resolve core source offline (no localOverride, no pin yet). Non-fatal."
    fi
  fi
fi

cs_log "verify-core.sh: OK"
