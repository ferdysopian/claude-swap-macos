#!/usr/bin/env bash
# Shared helpers sourced by scripts in scripts/**.
# Not meant to be executed directly.

set -uo pipefail

# --- paths -------------------------------------------------------------

# Repo root = parent of scripts/lib
CS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CS_SCRIPTS_DIR="$CS_REPO_ROOT/scripts"
CS_BUILD_DIR="$CS_REPO_ROOT/build"
CS_DIST_DIR="$CS_REPO_ROOT/dist"
CS_PROJECT_YML="$CS_REPO_ROOT/project.yml"

export CS_REPO_ROOT CS_SCRIPTS_DIR CS_BUILD_DIR CS_DIST_DIR CS_PROJECT_YML

# --- logging -------------------------------------------------------------

_cs_is_tty() { [[ -t 1 ]]; }

cs_log()  { if _cs_is_tty; then printf '\033[1;34m[claude-swap]\033[0m %s\n' "$*"; else printf '[claude-swap] %s\n' "$*"; fi; }
cs_warn() { if _cs_is_tty; then printf '\033[1;33m[claude-swap][warn]\033[0m %s\n' "$*" >&2; else printf '[claude-swap][warn] %s\n' "$*" >&2; fi; }
cs_err()  { if _cs_is_tty; then printf '\033[1;31m[claude-swap][error]\033[0m %s\n' "$*" >&2; else printf '[claude-swap][error] %s\n' "$*" >&2; fi; }
cs_die()  { cs_err "$*"; exit 1; }

# --- prerequisite checks -------------------------------------------------

cs_require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    cs_err "Required command '$cmd' not found on PATH."
    [[ -n "$hint" ]] && cs_err "  hint: $hint"
    exit 1
  fi
}

# --- project settings ----------------------------------------------------

# cs_project_setting <KEY>
# Prints a value from the top-level `settings.base` block of project.yml
# (e.g. MARKETING_VERSION -> 0.2.0). project.yml is the version source of
# truth; the .pbxproj is generated from it by xcodegen.
cs_project_setting() {
  local key="$1"
  sed -nE "s/^[[:space:]]*${key}:[[:space:]]*\"?([^\"[:space:]]+)\"?.*/\1/p" "$CS_PROJECT_YML" | head -n 1
}
