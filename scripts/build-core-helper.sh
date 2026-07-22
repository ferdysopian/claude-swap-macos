#!/usr/bin/env bash
# build-core-helper.sh — freeze the claude-swap Python core into a
# standalone helper executable with PyInstaller, so the Swift app can spawn
# it as a subprocess without requiring users to have Python installed.
#
# ── Architecture caveats (read before touching --arch) ─────────────────────
#
# PyInstaller does NOT support gluing two single-arch builds together with
# `lipo` after the fact: the frozen executable embeds an architecture-specific
# archive of your app's code/deps inside itself, and lipo-merging two such
# executables produces a binary that *looks* universal2 but only actually
# runs the slice that happens to be last in the fat file (this is documented
# upstream: https://pyinstaller.org/en/stable/feature-notes.html#macos-multi-arch-support).
# We therefore never call lipo on PyInstaller output. Two supported paths:
#
#   1. (default / recommended) Build one THIN helper per architecture
#      (--arch arm64, --arch x86_64) and ship two complete, architecture-
#      consistent app+DMG pairs (package-release.sh --arch dual, the
#      default) — see that script for exactly how each helper is embedded at
#      Contents/MacOS/<binaryName> (with support files relocated to
#      Contents/Frameworks/, which is where PyInstaller's bootloader expects
#      them once it detects it's running inside a real .app bundle).
#      ClaudeSwap/CoreBridge/BridgeProcess.swift's HelperLocator looks up
#      exactly one fixed-name auxiliary executable — it does NOT pick
#      between architectures at runtime — so this only works as two
#      separate, fully single-arch app bundles/DMGs, not one bundle with
#      both thin binaries inside it. This works with any Python distribution
#      (Homebrew, python.org, pyenv) and any deps. CI builds arm64 on an
#      Apple Silicon runner and x86_64 on an Intel-labeled runner — see
#      .github/workflows/release.yml.
#
#   2. (--arch universal2) Ask PyInstaller itself to emit fat binaries via
#      `--target-arch universal2`. This ONLY works if:
#        - the python3 running this script is itself a universal2 build
#          (the official python.org "macOS 64-bit universal2 installer", NOT
#          Homebrew's single-arch python), AND
#        - every non-pure-Python dependency (compiled .so/.dylib) also ships
#          universal2 wheels.
#      If a dependency is single-arch, PyInstaller fails loudly with
#      IncompatibleBinaryArchError rather than producing something broken —
#      that's intentional upstream behavior, not a bug in this script. If you
#      hit it, fall back to path (1).
#
# Usage:
#   scripts/build-core-helper.sh [--arch arm64|x86_64|universal2|host]
#                                 [--source <path-to-core-checkout>]
#                                 [--output <dir>]
#                                 [--venv <path>]
#
#   --arch host (default): build for the architecture this script runs on.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ARCH="host"
SOURCE_OVERRIDE=""
OUTPUT_DIR=""
VENV_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --source) SOURCE_OVERRIDE="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --venv) VENV_OVERRIDE="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cs_die "Unknown argument: $1" ;;
  esac
done

if [[ "$ARCH" == "host" ]]; then
  ARCH="$(cs_host_arch)"
fi
case "$ARCH" in
  arm64|x86_64|universal2) ;;
  *) cs_die "--arch must be one of: arm64, x86_64, universal2, host (got '$ARCH')" ;;
esac

HOST_ARCH="$(cs_host_arch)"
if [[ "$ARCH" != "universal2" && "$ARCH" != "$HOST_ARCH" ]]; then
  cs_warn "Requested --arch $ARCH but host is $HOST_ARCH."
  cs_warn "Cross-arch builds require running under Rosetta 2: 'arch -x86_64 \$0 --arch x86_64' on Apple Silicon."
  cs_warn "This script will attempt to continue but PyInstaller must be run through a matching-arch interpreter."
fi

# --- resolve inputs ---------------------------------------------------------

if [[ -n "$SOURCE_OVERRIDE" ]]; then
  CORE_SRC="$SOURCE_OVERRIDE"
else
  CORE_SRC="$(cs_resolve_core_source 1)" || cs_die "Could not resolve a Python core source. Pass --source explicitly, or fix localOverride / run scripts/update-core.sh."
fi
[[ -f "$CORE_SRC/pyproject.toml" ]] || cs_die "No pyproject.toml at core source: $CORE_SRC"
cs_log "Core source: $CORE_SRC"

BINARY_NAME="$(cs_lock_get 'helper.binaryName' 'claude-swap-helper')"
OUTPUT_DIR="${OUTPUT_DIR:-$CS_DIST_DIR/core-helper/$ARCH}"
mkdir -p "$OUTPUT_DIR"

# --- pick an entry point ----------------------------------------------------
# Try helper.entryPointCandidates in order; first that resolves in CORE_SRC wins.
# This lets the script "just work" once src/claude_swap/bridge/ lands.

ENTRY_MODULE=""
CANDIDATES_JSON="$(cs_lock_get 'helper.entryPointCandidates' '["claude_swap.cli:main"]')"
while IFS= read -r candidate; do
  [[ -z "$candidate" ]] && continue
  mod="${candidate%%:*}"
  rel_path="${mod//.//}"
  if [[ -f "$CORE_SRC/src/$rel_path.py" || -f "$CORE_SRC/src/$rel_path/__main__.py" ]]; then
    ENTRY_MODULE="$candidate"
    break
  fi
done < <(python3 -c "import json,sys; print('\n'.join(json.loads(sys.argv[1])))" "$CANDIDATES_JSON")

if [[ -z "$ENTRY_MODULE" ]]; then
  cs_die "None of the configured helper.entryPointCandidates exist in $CORE_SRC/src. Checked: $CANDIDATES_JSON"
fi
cs_log "Using entry point: $ENTRY_MODULE"

# Generate a tiny launcher script PyInstaller freezes, so we support both
# "module with __main__" and "module:function" candidate styles uniformly.
ENTRY_SCRIPT="$(mktemp -t claude-swap-helper-entry).py"
trap 'rm -f "$ENTRY_SCRIPT"' EXIT
if [[ "$ENTRY_MODULE" == *:* ]]; then
  mod="${ENTRY_MODULE%%:*}"
  func="${ENTRY_MODULE##*:}"
  cat > "$ENTRY_SCRIPT" <<PY
from ${mod} import ${func} as _entry
if __name__ == "__main__":
    _entry()
PY
else
  cat > "$ENTRY_SCRIPT" <<PY
import runpy
if __name__ == "__main__":
    runpy.run_module("${ENTRY_MODULE}", run_name="__main__")
PY
fi

# --- venv with PyInstaller + the core package -------------------------------

VENV_DIR="${VENV_OVERRIDE:-$CS_REPO_ROOT/.venv-helper-build}"
if [[ ! -d "$VENV_DIR" ]]; then
  cs_log "Creating build venv at $VENV_DIR ..."
  python3 -m venv "$VENV_DIR"
fi
PY="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

"$PIP" install --quiet --upgrade pip
"$PIP" install --quiet "pyinstaller>=6.10,<7"
cs_log "Installing core package from $CORE_SRC ..."
"$PIP" install --quiet "$CORE_SRC"

if [[ "$ARCH" == "universal2" ]]; then
  if ! file "$PY" 2>/dev/null | grep -q "universal binary"; then
    cs_warn "The interpreter at $PY does not look like a universal2 build."
    cs_warn "universal2 output requires the python.org universal2 installer. See script header comment."
  fi
fi

# --- run PyInstaller --------------------------------------------------------

PYI_ARGS=(
  --name "$BINARY_NAME"
  --onedir
  --noconfirm
  --clean
  --distpath "$OUTPUT_DIR"
  --workpath "$CS_BUILD_DIR/pyinstaller-work-$ARCH"
  --specpath "$CS_BUILD_DIR/pyinstaller-spec-$ARCH"
  --target-arch "$ARCH"
  --collect-all claude_swap
  --console
)

cs_log "Running PyInstaller (arch=$ARCH, onedir) ..."
"$PY" -m PyInstaller "${PYI_ARGS[@]}" "$ENTRY_SCRIPT"

RESULT_BIN="$OUTPUT_DIR/$BINARY_NAME/$BINARY_NAME"
if [[ ! -x "$RESULT_BIN" ]]; then
  cs_die "PyInstaller did not produce expected binary at $RESULT_BIN"
fi

cs_log "Helper built: $RESULT_BIN"
file "$RESULT_BIN" || true

cat <<EOF

Next: scripts/package-release.sh embeds this onedir tree into a real .app
for you (executable -> Contents/MacOS/$BINARY_NAME, everything else in
$OUTPUT_DIR/$BINARY_NAME/_internal/ -> Contents/Frameworks/ — PyInstaller's
bootloader requires that exact split once it detects it's inside a .app
bundle; see docs/PACKAGING.md). Do not lipo this output with another arch's
output — see the caveats at the top of this script.
EOF
