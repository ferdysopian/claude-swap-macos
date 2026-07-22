# Updating the bundled Python core

The macOS app bundles a frozen copy of the `claude-swap` Python core (see [`docs/adr/0001-bundled-python-helper.md`](adr/0001-bundled-python-helper.md) for why). Exactly which revision is bundled is pinned in [`Dependencies/CoreDependency.lock.json`](../Dependencies/CoreDependency.lock.json). This document covers how that pin gets updated.

## The rule: explicit tag or SHA only, never a floating ref

`scripts/update-core.sh` refuses to run without an explicit `--tag <tag>` or `--sha <full-40-char-sha>`. It will not accept `main`, `latest`, `HEAD`, or any other floating ref — the entire point of the lock file is that anyone, at any time, can look at it and know exactly which core commit is bundled, without needing to know what "main" pointed to on some particular date.

If you pass `--tag`, the script resolves it to a commit SHA itself and pins both; if you pass `--sha` alone, it must be the full 40-character hex SHA (not an abbreviation) and it verifies that commit actually exists in the configured repository.

## Local: `scripts/update-core.sh`

```sh
# Pin to a tag (recommended for releases):
scripts/update-core.sh --tag v0.24.0

# Pin to an exact commit (e.g. for a fix that hasn't been tagged yet):
scripts/update-core.sh --sha 0123456789abcdef0123456789abcdef01234567

# Point at a fork/mirror:
scripts/update-core.sh --tag v0.24.0 --repo https://github.com/you/claude-swap
```

What it does, in order:

1. Clones the configured `repository` into a throwaway temp directory (never touches your working tree's git history).
2. Checks out the tag/sha and re-verifies the resolved commit matches what you asked for.
3. Confirms `pyproject.toml` at that commit really is the `claude-swap` package and reads its `[project.version]`.
4. Runs the core's own test suite against that exact commit (`uv run pytest` if `uv` is available, else a plain venv + `pip install -e .[dev]` + `pytest`). **The pin is not written if tests fail.**
5. Does a smoke build of the frozen helper (`scripts/build-core-helper.sh`) against that commit for your host architecture, to catch freezing problems (missing hidden imports, etc.) before they become a release-day surprise.
6. Updates `Dependencies/CoreDependency.lock.json`: `repository` (if `--repo` was given), `tag`, `commitSha`, `pythonPackageVersion`, `helperBuildVersion` (incremented), `updatedAt`, `updatedBy`.
7. Cleans up the temp clone.

**This script never runs `git push`.** By default it doesn't even `git commit` — it just leaves the modified lock file in your working tree for you to review (`git diff Dependencies/CoreDependency.lock.json`) and commit yourself. Pass `--commit` if you want it to make a local commit on your current branch (still never pushed).

Useful flags:

- `--skip-tests` — skip step 4 (not recommended before a real release pin; useful for quick local experimentation with a WIP core branch via `--allow-branch`).
- `--skip-helper-build` — skip step 5.
- `--allow-branch` — escape hatch to point `--tag` at something that's actually a branch name, for local experimentation only. Never use this for a pin you intend to commit/release.
- `--bridge-protocol-version <n>` — also bump `bridgeProtocolVersion` in the lock file, when the core's bridge contract (`contracts/**`) changed incompatibly alongside this pin.

## Via GitHub Actions: `update-core.yml`

For re-pinning without a local checkout (e.g. from your phone, or as part of a scheduled bump reminder), trigger the `Update core pin` workflow manually:

```sh
gh workflow run update-core.yml -f tag=v0.24.0
# or:
gh workflow run update-core.yml -f sha=0123456789abcdef0123456789abcdef01234567
```

Or via the Actions tab → "Update core pin" → "Run workflow", filling in `tag` or `sha` (and optionally `repo` / `bridge_protocol_version`).

This runs the exact same `scripts/update-core.sh` (tests + smoke build included) and then opens a pull request with just the `Dependencies/CoreDependency.lock.json` change, using [`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request) — that action, not the script, is what pushes a branch and opens the PR. Review the PR like any other change (CI re-verifies the lock file and rebuilds the app against it) before merging.

## Local development: `localOverride`

Day to day, you don't want to re-pin the lock file every time you touch the core — you want scripts to just use your local checkout. That's what `localOverride` in the lock file is for:

```json
"localOverride": {
  "enabled": true,
  "path": "/absolute/path/to/your/claude-swap/checkout"
}
```

When `enabled` is `true` and `path` exists (and contains a `pyproject.toml`), every script (`bootstrap.sh`, `build-core-helper.sh`, `verify-core.sh`, `update-core.sh`'s own smoke build, etc.) uses that checkout directly instead of fetching `repository`@`commitSha`. This repo ships with `localOverride.path` defaulted to the sibling `claude-swap` checkout used for local development; if that exact path doesn't exist on your machine, scripts automatically fall back to `<parent-directory-of-this-repo>/claude-swap` (i.e., a sibling checkout with the default name) before giving up and requiring a real pin.

**Set `localOverride.enabled` to `false` before cutting a release build.** `scripts/verify-core.sh --require-pin` (used by `release.yml`) fails the build if `commitSha` is still the `PENDING-run-scripts/update-core.sh` placeholder, specifically to prevent a release accidentally shipping whatever happened to be in someone's local override directory at build time instead of a reviewed, pinned, tested revision.

## Checking the current pin

```sh
scripts/verify-core.sh                  # schema/shape validation only (offline, non-fatal on PENDING)
scripts/verify-core.sh --check-source   # also resolves + prints where the core source currently comes from
scripts/verify-core.sh --require-pin    # fail if commitSha is still the placeholder (what release.yml uses)
```

Or just read the fields directly: `cat Dependencies/CoreDependency.lock.json`.

## When to bump `bridgeProtocolVersion`

`bridgeProtocolVersion` (also in the lock file) is independent of `pythonPackageVersion` — it tracks the wire protocol between the Swift `CoreBridge` client and the Python helper (`contracts/**`). Bump it (via `--bridge-protocol-version` on `update-core.sh`) whenever a core update changes the bridge protocol in a way older Swift clients couldn't handle — coordinate a matching Swift CoreBridge change before merging such a pin, since it likely needs a corresponding Swift-side change in the same release.
