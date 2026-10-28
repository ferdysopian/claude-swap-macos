# ADR 0002: The wrapper uses the officially installed `cswap` CLI for release 1

- **Status:** Accepted
- **Date:** 2026-10-28
- **Supersedes:** [ADR 0001](0001-bundled-python-helper.md) for release 1 only
- **Owners:** Maintainer of this repository

## Context

Claude Swap for macOS is a native SwiftUI wrapper. Account management (credential storage, usage lookups, switching, auto-switch engine) is implemented by the Python package `claude-swap` by realiti4, which installs the `cswap` command. The upstream project is MIT-licensed and published at https://github.com/realiti4/claude-swap.

ADR 0001 chose to freeze the Python core with PyInstaller and ship it inside the app as a `claude-swap-helper` process that speaks an NDJSON bridge protocol. Work since then showed that this path has problems for a public release:

- Upstream v0.26.0 does not ship a `claude_swap.bridge` module. The bridge only existed in a local, uncommitted checkout, so the protocol could not be treated as an upstream contract.
- A bundled helper needs per-architecture builds, PyInstaller packaging, signing of nested binaries, and a lock file that pinned an upstream revision. That is a large maintenance surface for a wrapper maintained by one person.
- Bundling a frozen engine makes the wrapper responsible for upstream's license notices, its dependencies, and its update cadence.
- The app's behavior depended on which local checkout or helper was found first, which made failures hard to explain to users.

The public CLI (`cswap`, from the `claude-swap` package on PyPI) already exposes the commands the wrapper needs: `list`, `switch`, `add`, `add-token -` (token from stdin), `alias`, `disable`, `enable`, `remove`, `config`, `auto`, `export`, and `import`.

## Decision

For release 1:

1. The wrapper does **not** bundle Python, the upstream engine, or any helper executable.
2. Users install the official CLI themselves, using the upstream instructions, for example `uv tool install claude-swap` or `pipx install claude-swap`.
3. The wrapper calls the installed `cswap` executable with argument arrays (no shell), stdin for secrets, timeouts, and bounded output (`ProcessRunner`).
4. CLI discovery order is: `CLAUDE_SWAP_CLI_PATH` environment variable, then the path saved in Settings › Command-Line Tool, then `PATH` plus `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`. The wrapper stores the launcher path, not the symlink target. An explicit path that is not executable is reported, never silently replaced. No sibling checkout and no bundled helper is ever selected automatically.
5. A compatibility policy (`ClaudeSwap/Resources/CLICompatibility.json`) defines the minimum CLI version (0.26.0), the baseline the code was written against, the list of CLI versions verified by the contract checklist (empty until a run passes), and the supported JSON schema versions (currently `[1]`). A CLI that is older than the minimum, or that reports an unknown JSON schema, is incompatible and mutations are blocked. A CLI that is newer but not listed as verified is labeled "not yet verified with this app version".
6. Demo data is never shown implicitly. Fixture data is used only when explicitly requested (previews, unit tests, and developer-only environment settings). Without a CLI, the app shows a "CLI not installed" state with install steps.
7. The NDJSON bridge (`CoreBridgeClient`) remains in the code as a development-only path (`CLAUDE_SWAP_BACKEND=bridge` with `CLAUDE_SWAP_CORE_PATH`). It is not a supported user path because no released upstream version provides the bridge module.
8. The wrapper never installs or upgrades the CLI automatically.

## Consequences

Positive:

- Release artifacts are a plain macOS app. No Python, no helper, no per-architecture engine builds, no nested-binary signing for an engine.
- Behavior is tied to a public, documented command surface. Compatibility is a concrete, testable statement about specific CLI versions.
- Attribution is simple to state: the engine is upstream's, installed separately, and nothing from upstream is distributed by the app.

Negative and accepted:

- Users must install the CLI first. The onboarding screen and README say so, and the app explains a missing CLI instead of falling back to demo data.
- Compatibility depends on the CLI's public output. Parsing of JSON output and of the CLI's on-disk usage cache must be checked against each CLI version before it is listed as verified. `UsageCacheStore` reads an internal file, which is not a public contract; it has been tested only against 0.26.0.
- Until a CLI version passes the contract checklist, `verifiedVersions` is empty, so the app reports every CLI as "not yet verified". This is intentional.
- Release timing is coupled to contract runs against the official package.

## Alternatives considered

### A. Bundle the official CLI later, unmodified

Deferred, not rejected. Bundling an unmodified official distribution could simplify installation for end users. It would bring Python packaging, signing of nested binaries, upstream license notices in the app, and an update process for the engine. It is evaluated after release 1 is stable. Any bundled copy must be the unmodified upstream distribution and must be called as a CLI, not renamed as a helper.

### B. Keep the NDJSON bridge with a local checkout

Rejected as a public path. It depends on code that is not in any released upstream version, so the wrapper could not state a compatibility contract for it. It remains a developer-only path.

### C. Fork upstream or send a pull request upstream

Out of scope for this decision. The wrapper does not depend on changes to upstream, and this work does not create or maintain a fork or upstream pull requests.

## Related

- [ADR 0001](0001-bundled-python-helper.md) (superseded for release 1)
- [`docs/CLI_COMPATIBILITY.md`](../CLI_COMPATIBILITY.md) — how a CLI version is evaluated and added to `verifiedVersions`
- [`docs/PACKAGING.md`](../PACKAGING.md) — what the release artifact contains
