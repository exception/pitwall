#!/bin/zsh
# Sets up a fresh checkout: fetches Ghostty at the pinned commit, builds
# libghostty (macOS app), libghostty-vt (session service), and generates the Xcode project.
#
# Requires: Xcode (+ Metal toolchain), zig 0.17.1, xcodegen.
set -e
cd "${0:A:h}/.."
GHOSTTY_COMMIT=7fa26e8b675f3248975479d88274c937d7e63905

if [[ ! -d vendor/ghostty ]]; then
  git clone https://github.com/ghostty-org/ghostty vendor/ghostty
fi
git -C vendor/ghostty fetch --quiet origin && git -C vendor/ghostty checkout --quiet $GHOSTTY_COMMIT

xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true
( cd vendor/ghostty
  zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
  zig build -Demit-lib-vt=true -Doptimize=ReleaseFast --prefix ../ghostty-vt-out )

xcodegen generate
echo "Ready. Open Pitwall.xcodeproj, or: xcodebuild -scheme Pitwall build"
