# Third-party notices

This file explains which third-party software is involved in Claude Swap for macOS, and whether it is **distributed with the app** or only **installed or used separately**.

## Summary

| Component | Role | Distributed in the app? | License | Source |
|---|---|---|---|---|
| `claude-swap` (provides `cswap`) | Account engine, run as an external CLI | **No.** Users install it separately. | MIT | https://github.com/realiti4/claude-swap |
| Apple system frameworks (SwiftUI, AppKit, Foundation, and other macOS SDK frameworks) | Platform APIs the app is built with | Linked from macOS; not copied into the app | Apple platform terms | Apple Developer documentation |
| XcodeGen | Generates `ClaudeSwap.xcodeproj` from `project.yml` | **No.** Developer tool only. | See upstream repository | https://github.com/yonaskolb/XcodeGen |
| shellcheck | Lints the shell scripts in CI | **No.** Developer tool only. | See upstream repository | https://github.com/koalaman/shellcheck |

## 1. Upstream account engine: claude-swap

- **Project:** claude-swap by realiti4
- **Repository:** https://github.com/realiti4/claude-swap
- **License:** MIT. The upstream license text is in the upstream repository: https://github.com/realiti4/claude-swap/blob/main/LICENSE
- **How it is used:** Claude Swap runs the `cswap` command that the user installs with `uv tool install claude-swap` or `pipx install claude-swap`. The app calls the command with argument arrays, sends secrets through stdin, and reads its JSON output.
- **Distributed with Claude Swap?** No. The app does not contain upstream source code, Python, or a bundled `cswap`. Release artifacts contain only the wrapper.
- **Compatibility:** minimum 0.26.0. Verified versions are listed in `ClaudeSwap/Resources/CLICompatibility.json`.

The wrapper's own code was checked against upstream's source and against the installed 0.26.0 package. No upstream source was copied into this repository. If a future release bundles any part of upstream, this section and the release notes must be updated first, and the upstream copyright and MIT permission notice must be included with the distribution.

`LICENSE` covers this wrapper's own code. claude-swap keeps its own copyright notice and MIT license in its repository; nothing from it is redistributed here.

## 2. Platform frameworks

The app uses Apple's system frameworks, which ship with macOS and the Xcode SDK. They are not third-party packages and are not copied into the app bundle.

## 3. Packages

`project.yml` declares **no** Swift Package Manager or other third-party package dependencies. Checked on 2026-10-28. If a dependency is added, add it to this table with its license and whether it is distributed.

## 4. Developer tools (not distributed)

- **XcodeGen** generates the Xcode project. It runs on contributors' machines only.
- **shellcheck** lints `scripts/` in CI.

Neither tool is included in the app or in the DMG.

## 5. Removed components

Earlier development builds bundled a frozen copy of the Python core through a helper executable and a pinned upstream revision. Release 1 does not include that helper, the pin, or the helper build scripts. See [`docs/adr/0002-wrapper-uses-installed-cli.md`](docs/adr/0002-wrapper-uses-installed-cli.md).
