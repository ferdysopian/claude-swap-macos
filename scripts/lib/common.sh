#!/usr/bin/env bash
# Shared helpers sourced by every script in scripts/**.
# Not meant to be executed directly.

set -uo pipefail

# --- paths -------------------------------------------------------------

# Repo root = parent of scripts/lib
CS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CS_SCRIPTS_DIR="$CS_REPO_ROOT/scripts"
CS_LOCK_FILE="$CS_REPO_ROOT/Dependencies/CoreDependency.lock.json"
CS_LOCK_PY="$CS_SCRIPTS_DIR/lib/lock.py"
CS_BUILD_DIR="$CS_REPO_ROOT/build"
CS_DIST_DIR="$CS_REPO_ROOT/dist"
CS_CORE_CACHE_DIR="$CS_REPO_ROOT/.core-src-cache"

export CS_REPO_ROOT CS_SCRIPTS_DIR CS_LOCK_FILE CS_LOCK_PY CS_BUILD_DIR CS_DIST_DIR CS_CORE_CACHE_DIR

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

cs_require_python3() {
  cs_require_cmd python3 "Install Python 3.12+ (e.g. 'brew install python@3.12' or https://python.org)."
  local ver
  ver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  local major minor
  major="${ver%%.*}"
  minor="${ver##*.}"
  if (( major < 3 || (major == 3 && minor < 12) )); then
    cs_warn "python3 is $ver; claude-swap core requires >=3.12. Continuing, but the helper build may fail."
  fi
}

# --- lock file access (delegates to lock.py for correct JSON handling) ---

cs_lock_get() {
  # cs_lock_get <dotted.path> [default]
  local path="$1"
  local default="${2:-}"
  local out
  if out="$(python3 "$CS_LOCK_PY" get "$path" --lock "$CS_LOCK_FILE" 2>/dev/null)"; then
    printf '%s' "$out"
  else
    printf '%s' "$default"
  fi
}

cs_lock_set() {
  # cs_lock_set <dotted.path> <value> [--type str|int|bool|json]
  python3 "$CS_LOCK_PY" set "$@" --lock "$CS_LOCK_FILE"
}

cs_lock_validate() {
  python3 "$CS_LOCK_PY" validate --lock "$CS_LOCK_FILE" --schema "$CS_REPO_ROOT/Dependencies/CoreDependency.schema.json" "$@"
}

# --- core source resolution ----------------------------------------------

# Resolves which directory on disk contains the claude-swap core source
# (either localOverride, or a cached clone of the pinned commit). Prints the
# absolute path on stdout, or nothing + non-zero exit if unavailable without
# network access.
cs_resolve_core_source() {
  local allow_fetch="${1:-1}" # pass 0 to disallow network clone (offline/verify-only paths)

  local override_enabled override_path
  override_enabled="$(cs_lock_get 'localOverride.enabled' 'false')"
  override_path="$(cs_lock_get 'localOverride.path' '')"

  if [[ "$override_enabled" == "true" && -n "$override_path" ]]; then
    if [[ -d "$override_path" && -f "$override_path/pyproject.toml" ]]; then
      printf '%s' "$override_path"
      return 0
    fi
    cs_warn "localOverride.path '$override_path' not found or missing pyproject.toml on this machine."
    local sibling_default
    sibling_default="$(cd "$CS_REPO_ROOT/.." && pwd)/claude-swap"
    if [[ -d "$sibling_default" && -f "$sibling_default/pyproject.toml" ]]; then
      cs_warn "Falling back to sibling checkout: $sibling_default"
      printf '%s' "$sibling_default"
      return 0
    fi
    cs_warn "Sibling fallback '$sibling_default' also not found. Falling back to the pinned commitSha."
  fi

  if [[ "$allow_fetch" != "1" ]]; then
    return 1
  fi

  local repo sha
  repo="$(cs_lock_get 'repository' '')"
  sha="$(cs_lock_get 'commitSha' '')"

  if [[ -z "$repo" || "$sha" == PENDING* || -z "$sha" ]]; then
    cs_err "No usable core source: localOverride is unavailable and commitSha is unpinned ('$sha')."
    cs_err "Run scripts/update-core.sh --tag <tag> (or --sha <sha>) first, or enable localOverride."
    return 1
  fi

  mkdir -p "$CS_CORE_CACHE_DIR"
  local cache_dir="$CS_CORE_CACHE_DIR/$sha"
  if [[ -d "$cache_dir/.git" ]]; then
    printf '%s' "$cache_dir"
    return 0
  fi

  cs_log "Fetching pinned core commit $sha from $repo into $cache_dir ..." >&2
  rm -rf "$cache_dir"
  mkdir -p "$cache_dir"
  (
    cd "$cache_dir"
    git init -q
    git remote add origin "$repo"
    git fetch -q --depth 1 origin "$sha" 2>/dev/null || git fetch -q origin
    git checkout -q "$sha"
  ) || { cs_err "Failed to fetch/checkout $sha from $repo"; return 1; }

  printf '%s' "$cache_dir"
}

# Host architecture as PyInstaller/Xcode understand it: arm64 | x86_64
cs_host_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    arm64) echo "arm64" ;;
    x86_64) echo "x86_64" ;;
    *) echo "$m" ;;
  esac
}
