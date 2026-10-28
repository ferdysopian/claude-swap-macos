#!/usr/bin/env bash
# verify-metadata.sh — offline consistency checks for release metadata.
#
# Checks:
#   1. ClaudeSwap/Resources/CLICompatibility.json is valid JSON with the
#      required fields, and minimumVersion/baselineVersion are dotted numbers.
#   2. MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml (the source
#      of truth) match every occurrence in ClaudeSwap.xcodeproj/project.pbxproj.
#   3. ClaudeSwap/Resources/Info.plist uses $(MARKETING_VERSION) and
#      $(CURRENT_PROJECT_VERSION) instead of hard-coded values.
#   4. No tracked file under project.yml, .github/, scripts/ or
#      ClaudeSwap/Resources/ contains an absolute personal home path.
#   5. There is no second Info.plist under ClaudeSwap/ outside Resources/.
#
# Optional --check-xcodegen: if xcodegen is installed, regenerate the project
# into a temp directory and fail if the result differs from the committed
# project.pbxproj (drift). Nothing in the repo is written.
#
# Usage:
#   scripts/verify-metadata.sh [--check-xcodegen]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CHECK_XCODEGEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-xcodegen) CHECK_XCODEGEN=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cs_die "Unknown argument: $1" ;;
  esac
done

FAILS=0
fail() { cs_err "$*"; FAILS=$((FAILS + 1)); }

PBXPROJ="$CS_REPO_ROOT/ClaudeSwap.xcodeproj/project.pbxproj"
INFO_PLIST="$CS_REPO_ROOT/ClaudeSwap/Resources/Info.plist"
COMPAT_JSON="$CS_REPO_ROOT/ClaudeSwap/Resources/CLICompatibility.json"

# Python snippets live in variables (not inline heredocs inside $(...)),
# which keeps parsing predictable on the bash 3.2 that macOS ships.
read -r -d '' COMPAT_PY <<'PY' || true
import json, re, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError) as e:
    print(f"invalid JSON: {e}")
    sys.exit(1)

DOTTED = re.compile(r"^[0-9]+(\.[0-9]+)+$")
required = {
    "cli": str,
    "package": str,
    "upstream": str,
    "minimumVersion": str,
    "baselineVersion": str,
    "verifiedVersions": list,
    "jsonSchemaVersions": list,
    "notes": str,
}
errors = []
if not isinstance(data, dict):
    errors.append("top level must be a JSON object")
else:
    for key, typ in required.items():
        if key not in data:
            errors.append(f"missing required field '{key}'")
        elif not isinstance(data[key], typ):
            errors.append(f"field '{key}' must be a {typ.__name__}")
    for key in ("minimumVersion", "baselineVersion"):
        value = data.get(key)
        if isinstance(value, str) and not DOTTED.match(value):
            errors.append(f"'{key}' must be dotted numbers like 0.26.0 (got {value!r})")
    verified = data.get("verifiedVersions")
    if isinstance(verified, list):
        for value in verified:
            if not isinstance(value, str) or not DOTTED.match(value):
                errors.append(f"'verifiedVersions' entry {value!r} must be dotted numbers")
if errors:
    print("; ".join(errors))
    sys.exit(1)
PY

read -r -d '' PLIST_PY <<'PY' || true
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    data = plistlib.load(f)
expected = {
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
}
bad = [f"{k} must be {v!r} (found {data.get(k)!r})" for k, v in expected.items() if data.get(k) != v]
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY

YML_VERSION="$(cs_project_setting MARKETING_VERSION)"
YML_BUILD="$(cs_project_setting CURRENT_PROJECT_VERSION)"
[[ -n "$YML_VERSION" ]] || fail "project.yml: MARKETING_VERSION not found under settings.base"
[[ -n "$YML_BUILD" ]] || fail "project.yml: CURRENT_PROJECT_VERSION not found under settings.base"

# --- 1. CLI compatibility policy ----------------------------------------

if [[ ! -f "$COMPAT_JSON" ]]; then
  fail "ClaudeSwap/Resources/CLICompatibility.json is missing"
else
  if ! out="$(python3 -c "$COMPAT_PY" "$COMPAT_JSON" 2>&1)"; then
    fail "CLICompatibility.json: $out"
  fi
fi

# --- 2. project.yml vs project.pbxproj ----------------------------------

check_pbx_key() {
  local key="$1" expected="$2" values count bad
  values="$(sed -nE "s/^[[:space:]]*${key} = ([^;]*);.*/\1/p" "$PBXPROJ" | tr -d '"')"
  count="$(printf '%s' "$values" | grep -c . || true)"
  if [[ "$count" == "0" ]]; then
    fail "project.pbxproj: no $key entries found"
    return
  fi
  bad="$(printf '%s\n' "$values" | grep -vxF "$expected" || true)"
  if [[ -n "$bad" ]]; then
    fail "project.pbxproj: $key has value(s) not matching project.yml ($expected): $(printf '%s' "$bad" | sort -u | tr '\n' ' ')"
    fail "  regenerate with: xcodegen generate  (after fixing project.yml)"
  fi
}

if [[ ! -f "$PBXPROJ" ]]; then
  fail "ClaudeSwap.xcodeproj/project.pbxproj is missing (run scripts/bootstrap.sh)"
else
  [[ -n "$YML_VERSION" ]] && check_pbx_key MARKETING_VERSION "$YML_VERSION"
  [[ -n "$YML_BUILD" ]] && check_pbx_key CURRENT_PROJECT_VERSION "$YML_BUILD"
fi

# --- 3. Info.plist uses build-setting variables -------------------------

if [[ ! -f "$INFO_PLIST" ]]; then
  fail "ClaudeSwap/Resources/Info.plist is missing"
else
  if ! out="$(python3 -c "$PLIST_PY" "$INFO_PLIST" 2>&1)"; then
    fail "Info.plist: $out"
  fi
fi

# --- 4. No absolute personal paths in tracked release/CI files ----------

PERSONAL_HITS=""
while IFS= read -r -d '' tracked; do
  hits="$(grep -nE '/Users/[A-Za-z]' "$CS_REPO_ROOT/$tracked" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    PERSONAL_HITS+="$(printf '%s\n' "$hits" | sed "s|^|$tracked:|")"$'\n'
  fi
done < <(git -C "$CS_REPO_ROOT" ls-files -z -- project.yml .github scripts ClaudeSwap/Resources)
if [[ -n "$PERSONAL_HITS" ]]; then
  fail "absolute personal path found in tracked files (use relative paths or env vars):"
  printf '%s' "$PERSONAL_HITS" | sed 's/^/    /' >&2
  FAILS=$((FAILS + 1))
fi

# --- 5. Single Info.plist -----------------------------------------------

EXTRA_PLISTS="$(find "$CS_REPO_ROOT/ClaudeSwap" -name Info.plist -not -path "$CS_REPO_ROOT/ClaudeSwap/Resources/*" 2>/dev/null || true)"
if [[ -n "$EXTRA_PLISTS" ]]; then
  fail "extra Info.plist outside ClaudeSwap/Resources/ (only Resources/Info.plist is used):"
  printf '%s\n' "$EXTRA_PLISTS" | sed 's/^/    /' >&2
fi

# --- optional: xcodegen drift -------------------------------------------

if [[ "$CHECK_XCODEGEN" == "1" ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    cs_warn "xcodegen not installed; skipping drift check (install with: brew install xcodegen)"
  elif [[ -f "$PBXPROJ" ]]; then
    # Generate inside a copy of the tracked tree: xcodegen writes paths
    # relative to the project location, so generating elsewhere would
    # always look like drift.
    GEN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cs-xcodegen.XXXXXX")"
    trap 'rm -rf "$GEN_DIR"' EXIT
    (cd "$CS_REPO_ROOT" && git ls-files -z --cached --others --exclude-standard) \
      | (cd "$CS_REPO_ROOT" && xargs -0 -I{} rsync -R -- "{}" "$GEN_DIR/" 2>/dev/null) || true
    if ! (cd "$GEN_DIR" && xcodegen generate --quiet --spec project.yml >/dev/null); then
      fail "xcodegen generate failed for project.yml"
    elif [[ ! -f "$GEN_DIR/ClaudeSwap.xcodeproj/project.pbxproj" ]]; then
      fail "xcodegen did not produce ClaudeSwap.xcodeproj/project.pbxproj in temp dir"
    else
      DRIFT="$(diff -u "$PBXPROJ" "$GEN_DIR/ClaudeSwap.xcodeproj/project.pbxproj" || true)"
      if [[ -n "$DRIFT" ]]; then
        fail "committed project.pbxproj differs from xcodegen output for project.yml (drift):"
        printf '%s\n' "$DRIFT" | head -n 40 | sed 's/^/    /' >&2
        fail "  run: xcodegen generate   (then review and commit the .pbxproj)"
      else
        cs_log "xcodegen drift check: project.pbxproj matches project.yml"
      fi
    fi
  fi
fi

# --- result ---------------------------------------------------------------

if [[ "$FAILS" -gt 0 ]]; then
  cs_die "verify-metadata: $FAILS problem(s) found"
fi

cs_log "verify-metadata: OK (version $YML_VERSION build $YML_BUILD; CLI policy, pbxproj, Info.plist, personal paths, single Info.plist)"
