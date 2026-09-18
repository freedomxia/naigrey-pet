#!/bin/zsh
# Renders an MP4 of the rigged cat for review. Needs ffmpeg on PATH. Usage: Tools/preview.command out.mp4 [seconds] [still times...]
set -euo pipefail
cd "${0:A:h}/.."
BIN=$(mktemp -d "${TMPDIR:-/tmp/}naigrey-preview.XXXXXX")
trap 'rm -rf "$BIN"' EXIT
xcrun swiftc -O -target arm64-apple-macos13.0 Source/Sprites.swift Source/Rig.swift Source/Renderer.swift Source/Motion.swift Tools/preview/main.swift \
  -framework AppKit -framework Metal -framework QuartzCore -framework Accelerate -o "$BIN/preview"
"$BIN/preview" 奶灰.app/Contents/Resources/cats.png "$@"
