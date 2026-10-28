# Releasing

This is the checklist for a wrapper-only release of Claude Swap for macOS. Read [`PACKAGING.md`](PACKAGING.md) and [`SIGNING.md`](SIGNING.md) first.

**Approval:** creating a tag, pushing it, and publishing a GitHub Release are maintainer decisions. Do not do any of them without an explicit go-ahead for that specific version.

## Before you start

- [ ] `main` is green in CI: `metadata`, `build-test`, and `shell-lint`.
- [ ] `project.yml` has the intended `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Regenerate the project and check the diff: `scripts/bootstrap.sh`, then `scripts/verify-metadata.sh --check-xcodegen`.
- [ ] `CHANGELOG.md` has a section for the version, and the `Unreleased` items are moved into it.
- [ ] `README.md` and the docs match the release (for example, the compatibility table and the list of verified CLI versions).
- [ ] `ClaudeSwap/Resources/CLICompatibility.json` lists exactly the CLI versions that passed the contract checklist in [`CLI_COMPATIBILITY.md`](CLI_COMPATIBILITY.md). If none has passed, the release notes must say so.
- [ ] The QA matrix in [`QA_MATRIX.md`](QA_MATRIX.md) has a status for every row, and no row is marked verified without evidence.
- [ ] Unit tests pass locally: `scripts/build-app.sh --config Debug --action test`.
- [ ] The security checklist in [`SECURITY_REVIEW_CHECKLIST.md`](SECURITY_REVIEW_CHECKLIST.md) has been reviewed for changes in this release.

## Build the artifact

Tag and version rule: the tag must be `v` followed by `MARKETING_VERSION` (for example, `v0.2.0`). The release workflow fails on any mismatch.

Local dry run and packaging:

```sh
scripts/package-release.sh --dry-run
scripts/package-release.sh                  # unsigned, or signed if DEVELOPER_ID_APPLICATION is set
scripts/package-release.sh --notarize       # only with DEVELOPER_ID_APPLICATION and NOTARY_PROFILE
shasum -a 256 -c dist/ClaudeSwap-<version>*.dmg.sha256
```

Or let CI do it: pushing a matching tag runs `.github/workflows/release.yml`, which packages the DMG and creates a **draft** GitHub Release.

- With no signing secrets, the draft is marked as a prerelease and its notes start with an "Unsigned experimental build" warning.
- The DMG is never presented as notarized unless notarization actually ran.

## Release notes

Every release note includes:

1. The credit line, exactly as in the README:
   > A native macOS companion for [claude-swap](https://github.com/realiti4/claude-swap) by realiti4. Account management is powered by the separately installed upstream CLI. This wrapper is maintained independently.
2. The unofficial disclaimer: not affiliated with, endorsed by, or sponsored by Anthropic or realiti4.
3. The minimum CLI version (0.26.0 at the time of writing) and the list of verified CLI versions, or a statement that none is verified yet.
4. Whether the DMG is signed and notarized. If not: "Unsigned experimental build", and the first-launch instructions from the README.
5. The SHA-256 checksum of the DMG.
6. Known limitations from the changelog.
7. A reminder that the CLI is installed separately and that removing the app does not remove CLI accounts.

## Publish

1. Review the draft: artifact name, checksum, notes, prerelease flag.
2. Download the DMG from the draft and check the checksum.
3. Install it on a clean test Mac (or a test account), install the CLI with the documented command, and run the acceptance checks that apply to this release in [`QA_MATRIX.md`](QA_MATRIX.md).
4. Publish the release only when the maintainer approves.

## After release

- Record the release date and the evidence (CI run link, checksum, test notes) in `docs/DEFINITION_OF_DONE.md`.
- If a CLI version was verified for this release, record the contract run in `docs/QA_MATRIX.md`.
- Start a new `Unreleased` section in `CHANGELOG.md`.
