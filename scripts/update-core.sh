#!/usr/bin/env bash
# update-core.sh — re-pin the Python core (Dependencies/CoreDependency.lock.json)
# to an EXPLICIT tag or commit SHA. This script never accepts a floating ref
# (branch name, "latest", "HEAD") because the whole point of the lock file is
# reproducibility: given a lock file, anyone can rebuild byte-for-byte the
# same helper.
#
# This script NEVER runs `git push`. It only edits the lock file on disk (and
# optionally makes a local commit with --commit). Pushing / opening a PR is
# left to a human, or to .github/workflows/update-core.yml which uses a
# dedicated GitHub Action to open a PR from a branch.
#
# What it does:
#   1. Require --tag <tag> or --sha <sha> (exactly one; --sha may also be
#      supplied alongside --tag to additionally pin/verify the exact commit).
#   2. Clone the configured repository into a temp dir, checkout the ref,
#      resolve+verify the exact commit SHA.
#   3. Verify pyproject.toml identifies the `claude-swap` package and read
#      its version.
#   4. Run the core's test suite (uv run pytest, falling back to a plain
#      venv + pip install -e .[dev] + pytest).
#   5. Smoke-build the core helper for the host architecture (fails fast if
#      the pin doesn't freeze cleanly).
#   6. Update the lock file (repository already fixed unless --repo given;
#      tag, commitSha, pythonPackageVersion, helperBuildVersion += 1,
#      updatedAt, updatedBy).
#   7. Clean up the temp clone.
#
# Usage:
#   scripts/update-core.sh --tag v0.24.0
#   scripts/update-core.sh --sha 0123456789abcdef0123456789abcdef01234567
#   scripts/update-core.sh --tag v0.24.0 --repo https://github.com/you/claude-swap
#   scripts/update-core.sh --tag v0.24.0 --skip-tests   # not recommended
#   scripts/update-core.sh --tag v0.24.0 --commit        # also `git commit` locally (never pushes)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TAG=""
SHA=""
REPO_OVERRIDE=""
SKIP_TESTS=0
SKIP_HELPER_BUILD=0
DO_COMMIT=0
ALLOW_BRANCH=0
BRIDGE_PROTOCOL_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
    --repo) REPO_OVERRIDE="$2"; shift 2 ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --skip-helper-build) SKIP_HELPER_BUILD=1; shift ;;
    --commit) DO_COMMIT=1; shift ;;
    --allow-branch) ALLOW_BRANCH=1; shift ;; # dev escape hatch, still requires exact sha verification
    --bridge-protocol-version) BRIDGE_PROTOCOL_VERSION="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) cs_die "Unknown argument: $1" ;;
  esac
done

if [[ -z "$TAG" && -z "$SHA" ]]; then
  cs_die "Refusing to update without an explicit --tag or --sha. Floating refs (main/latest/HEAD) are not allowed."
fi

REPO="${REPO_OVERRIDE:-$(cs_lock_get repository "https://github.com/realiti4/claude-swap")}"
cs_log "Repository: $REPO"

if [[ -z "$TAG" ]]; then
  # sha-only pin: require full 40-char sha, no abbreviations, no branch names.
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || cs_die "--sha must be a full 40-character commit SHA, got: $SHA"
fi

TMP_DIR="$(mktemp -d -t claude-swap-core-update)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

cs_log "Cloning $REPO into temp dir ..."
git clone --quiet --no-checkout "$REPO" "$TMP_DIR/repo"
cd "$TMP_DIR/repo"

if [[ -n "$TAG" ]]; then
  if ! git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null && ! git ls-remote --tags origin | grep -q "refs/tags/$TAG\$"; then
    cs_die "Tag '$TAG' not found on $REPO. Use an exact, existing tag."
  fi
  git fetch --quiet --tags origin "$TAG" || true
  RESOLVED_SHA="$(git rev-list -n1 "$TAG" 2>/dev/null || git rev-parse "refs/tags/$TAG")"
  if [[ -n "$SHA" && "$RESOLVED_SHA" != "$SHA" ]]; then
    cs_die "Tag '$TAG' resolves to $RESOLVED_SHA, which does not match --sha $SHA."
  fi
  SHA="$RESOLVED_SHA"
else
  # sha-only: must be reachable and, unless --allow-branch, must not be a branch tip we silently drift on.
  git fetch --quiet origin "$SHA" 2>/dev/null || git fetch --quiet origin
fi

git checkout --quiet "$SHA" 2>/dev/null || cs_die "Could not checkout $SHA — is it a valid commit in $REPO?"
ACTUAL_SHA="$(git rev-parse HEAD)"
[[ "$ACTUAL_SHA" == "$SHA" ]] || cs_die "Checked out $ACTUAL_SHA but expected $SHA."
cs_log "Verified commit: $ACTUAL_SHA"

if [[ "$ALLOW_BRANCH" != "1" ]]; then
  # Best-effort guard: reject if the ref is literally a branch name (not a tag/sha).
  if [[ -n "$TAG" ]] && git show-ref --verify --quiet "refs/remotes/origin/$TAG"; then
    cs_die "'$TAG' looks like a branch, not a tag. Branches are floating refs; pass --allow-branch to override (not recommended for releases)."
  fi
fi

[[ -f pyproject.toml ]] || cs_die "pyproject.toml missing at $SHA — not a valid claude-swap checkout."
PKG_NAME="$(python3 -c "
import tomllib, sys
with open('pyproject.toml', 'rb') as f:
    data = tomllib.load(f)
print(data.get('project', {}).get('name', ''))
" 2>/dev/null || python3 -c "
import re
print(re.search(r'name\s*=\s*\"([^\"]+)\"', open('pyproject.toml').read()).group(1))
")"
[[ "$PKG_NAME" == "claude-swap" ]] || cs_die "pyproject.toml [project.name] is '$PKG_NAME', expected 'claude-swap'."

PKG_VERSION="$(python3 -c "
import tomllib
with open('pyproject.toml', 'rb') as f:
    data = tomllib.load(f)
print(data.get('project', {}).get('version', ''))
" 2>/dev/null || python3 -c "
import re
print(re.search(r'version\s*=\s*\"([^\"]+)\"', open('pyproject.toml').read()).group(1))
")"
[[ -n "$PKG_VERSION" ]] || cs_die "Could not read [project.version] from pyproject.toml."
cs_log "Core pyproject.toml version: $PKG_VERSION"

# --- test the pinned revision ------------------------------------------------

if [[ "$SKIP_TESTS" == "1" ]]; then
  cs_warn "Skipping test suite (--skip-tests). Not recommended before a release pin."
else
  cs_log "Running core test suite at $SHA ..."
  if command -v uv >/dev/null 2>&1; then
    uv run --with-editable . --python 3.12 pytest -q || uv run pytest -q
  else
    python3 -m venv "$TMP_DIR/test-venv"
    "$TMP_DIR/test-venv/bin/pip" install --quiet -e ".[dev]" 2>/dev/null || \
      "$TMP_DIR/test-venv/bin/pip" install --quiet -e . pytest pytest-asyncio
    "$TMP_DIR/test-venv/bin/pytest" -q
  fi
  cs_log "Tests passed."
fi

# --- smoke-build the helper ---------------------------------------------------

if [[ "$SKIP_HELPER_BUILD" == "1" ]]; then
  cs_warn "Skipping helper smoke build (--skip-helper-build)."
else
  cs_log "Smoke-building core helper against pinned revision ..."
  "$CS_SCRIPTS_DIR/build-core-helper.sh" --source "$TMP_DIR/repo" --arch host \
    --output "$TMP_DIR/helper-smoke-build"
fi

# --- update the lock file -----------------------------------------------------

cd "$CS_REPO_ROOT"
[[ -n "$REPO_OVERRIDE" ]] && cs_lock_set repository "$REPO_OVERRIDE"
if [[ -n "$TAG" ]]; then
  cs_lock_set tag "$TAG"
else
  cs_lock_set tag "" --type null
fi
cs_lock_set commitSha "$SHA"
cs_lock_set pythonPackageVersion "$PKG_VERSION"
if [[ -n "$BRIDGE_PROTOCOL_VERSION" ]]; then
  cs_lock_set bridgeProtocolVersion "$BRIDGE_PROTOCOL_VERSION" --type int
fi
CURRENT_HELPER_BUILD="$(cs_lock_get helperBuildVersion 0)"
NEXT_HELPER_BUILD=$((CURRENT_HELPER_BUILD + 1))
cs_lock_set helperBuildVersion "$NEXT_HELPER_BUILD" --type int --touch-metadata --updated-by "scripts/update-core.sh"

cs_log "Lock file updated:"
if git -C "$CS_REPO_ROOT" ls-files --error-unmatch "$CS_LOCK_FILE" >/dev/null 2>&1; then
  git --no-pager diff -- "$CS_LOCK_FILE" || true
else
  cs_log "(lock file is not yet tracked by git; showing full contents instead of a diff)"
  cat "$CS_LOCK_FILE"
fi

if [[ "$DO_COMMIT" == "1" ]]; then
  git add "$CS_LOCK_FILE"
  git commit -m "chore(core): pin claude-swap to ${TAG:-$SHA} ($SHA)"
  cs_log "Committed locally on branch $(git branch --show-current). This script did NOT push."
else
  cs_log "Not committed (pass --commit to make a local commit). This script never pushes regardless."
fi
