## Summary

<!-- What changes, and why. Short imperative subject line for the commit. -->

## Related issue

<!-- Closes #... (optional) -->

## Checklist

- [ ] Unit tests pass: `scripts/build-app.sh --config Debug --action test`
- [ ] Build passes: `scripts/build-app.sh --config Debug --action build`
- [ ] `shellcheck -x` is clean if `scripts/` changed
- [ ] `scripts/verify-metadata.sh --check-xcodegen` passes if `project.yml` or the project changed
- [ ] README, `docs/`, and `CHANGELOG.md` are updated in this PR where behavior changed
- [ ] If CLI behavior changed: `docs/CLI_COMPATIBILITY.md` and `ClaudeSwap/Resources/CLICompatibility.json` were reviewed. No CLI version was added to `verifiedVersions` without a recorded contract run.
- [ ] No tokens, export files, real account data, or screenshots of real accounts are included
- [ ] No personal paths (for example `/Users/<name>/`) are added
- [ ] New or changed credential handling sends secrets only through stdin
- [ ] Tests added or updated, with no network, real Keychain, or real `cswap` access

## Screenshots

<!-- Synthetic data only. Never screenshots of real accounts, emails, or tokens. -->
