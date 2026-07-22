#!/usr/bin/env bash
#
# bootstrap.sh — dev environment bootstrap for Claude Swap (native macOS app).
#
# This is a stub: today it just verifies the tools this repo depends on and
# regenerates ClaudeSwap.xcodeproj from project.yml. As the release pipeline
# matures this script will also:
#   - vendor/build a real `claude-swap-helper` executable from the pinned
#     core (see Dependencies/CoreDependency.lock.json) and drop it into
#     ClaudeSwap/Resources so `HelperLocator` finds a bundled helper.
#   - stamp ClaudeSwap/Resources/CoreBuildInfo.json with the real pinned
#     version/ref/build time instead of the dev template.
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "== Claude Swap bootstrap =="

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: Xcode command line tools not found. Install Xcode and run 'xcode-select --install'." >&2
  exit 1
fi
echo "-> xcodebuild: $(xcodebuild -version | head -n1)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "-> xcodegen not found; installing via Homebrew"
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew not found. Install it, or install xcodegen manually: https://github.com/yonaskolb/XcodeGen" >&2
    exit 1
  fi
  brew install xcodegen
fi
echo "-> xcodegen: $(xcodegen --version)"

echo "-> Regenerating ClaudeSwap.xcodeproj from project.yml"
xcodegen generate

core_path="${CLAUDE_SWAP_CORE_PATH:-$HOME/Developer/claude-swap}"
if [ -d "$core_path" ]; then
  echo "-> Found local claude_swap core checkout at $core_path"
  if [ ! -d "$core_path/.venv" ] && [ ! -d "$core_path/.venv312" ]; then
    echo "   (no .venv found there yet — the app will fall back to fixture/preview data until one exists)"
  fi
else
  echo "-> No local claude_swap core checkout found at $core_path"
  echo "   Set CLAUDE_SWAP_CORE_PATH, or the app will run in fixture/preview mode."
fi

echo "-> Bootstrap complete. Open ClaudeSwap.xcodeproj in Xcode, or run:"
echo "     xcodebuild -project ClaudeSwap.xcodeproj -scheme ClaudeSwap -configuration Debug build"
