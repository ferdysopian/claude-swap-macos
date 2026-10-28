# Definition of done

Ship criteria for Claude Swap for macOS. The plan separates two milestones, and each has its own gate:

1. **Source ready to publish:** the repository can be opened to the public with honest documentation and no personal data.
2. **Binary ready for users:** a DMG that a user can install, with a CLI version that has passed the contract checklist.

Publishing the source and publishing a binary are separate decisions.

Related: [`QA_MATRIX.md`](QA_MATRIX.md) (acceptance evidence), [`SECURITY_REVIEW_CHECKLIST.md`](SECURITY_REVIEW_CHECKLIST.md), [`RELEASE.md`](RELEASE.md).

**Status key:** Met · Not met · Partial. Only **Met** is backed by evidence recorded below.

## Milestone 1: source ready to publish

| # | Requirement | Evidence | Status | Notes |
|---|---|---|---|---|
| S-1 | History and files audited for secrets and personal data | Audit report kept outside the repository | Not met | Required before visibility changes |
| S-2 | Copyright and license decided | `LICENSE`, `THIRD_PARTY_NOTICES.md` | Met | `LICENSE`: Claude Swap for macOS contributors; upstream credited in `THIRD_PARTY_NOTICES.md` |
| S-3 | README states the wrapper is independent and links realiti4 | `README.md` | Met | Credit line and disclaimer present |
| S-4 | No personal paths, sibling checkout, fork, or local bridge required to build | `scripts/verify-metadata.sh`, clean-clone build | Not met | Clean-clone build not yet run |
| S-5 | Contributor setup and test commands documented | `CONTRIBUTING.md`, `scripts/README.md` | Met | Documented; not yet tested by a second person |
| S-6 | Issue, PR, security, and changelog files exist | `.github/`, `SECURITY.md`, `CHANGELOG.md` | Met | |
| S-7 | No pull requests, issues, or messages sent to upstream as part of the work | Process record | Met | |
| S-8 | No personal editor or tooling configuration committed | `git ls-files`, `.gitignore` | Met | Local tooling stays untracked |

## Milestone 2: binary ready for users

| # | Requirement | Evidence | Status | Notes |
|---|---|---|---|---|
| B-1 | A CLI version passes the official-package contract checklist | `CLI_COMPATIBILITY.md`, `QA_MATRIX.md` contract runs | Not met | `verifiedVersions` is empty |
| B-2 | Every acceptance scenario in the QA matrix is passed | `QA_MATRIX.md` | Not met | All rows Not run |
| B-3 | No demo fallback presented as user data | Discovery and backend code; manual check A-1 | Not met | Code still needs to be confirmed against this rule |
| B-4 | Account changes, settings, transfer, and automation show real results | Contract runs C-4 to C-14; manual smoke test | Not met | |
| B-5 | Process, redaction, and service tests pass in CI | CI `build-test` | Not met | CI run not recorded |
| B-6 | App version and artifact version match | `scripts/verify-metadata.sh`, `package-release.sh` version check | Not met | |
| B-7 | DMG installed and run on a clean machine | Manual smoke test | Not met | |
| B-8 | Credit to realiti4 in README, About, and release notes | README, About, release template | Partial | About screen wording not yet checked |
| B-9 | Signing and notarization status stated honestly | Release notes and artifact name | Partial | Unsigned build path works by design; signing not performed |
| B-10 | Tag, release workflow, and draft release verified | `release.yml` | Not met | No tag has been pushed by this work |

## Summary

| Milestone | Status |
|---|---|
| 1. Source ready to publish | Not met (documentation largely in place; audit and clean-clone checks pending) |
| 2. Binary ready for users | Not met |

## Release sign-off

| Role | Name | Date | Notes |
|---|---|---|---|
| Maintainer | | | |

**Release blockers:** B-1, B-2, B-4, B-7. Source publication blockers: S-1, S-4, S-8.
