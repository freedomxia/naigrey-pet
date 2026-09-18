#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp/}naigrey-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc Source/Sprites.swift Source/Rig.swift Source/Renderer.swift Source/Motion.swift Source/Ball.swift Source/Clips.swift Source/Senses.swift Source/Updater.swift Tests/main.swift -framework AppKit -framework ImageIO -framework Metal -framework QuartzCore -framework Accelerate -framework AVFoundation -o "$TEST_DIR/verify"
"$TEST_DIR/verify" 奶灰.app/Contents/Resources/cats.png
codesign --verify --strict 奶灰.app
