#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
BIN=$(mktemp -d "${TMPDIR:-/tmp/}naigrey-stylecheck.XXXXXX")
trap 'rm -rf "$BIN"' EXIT
xcrun swiftc -O -target arm64-apple-macos13.0 Source/Sprites.swift Source/Rig.swift Source/Renderer.swift Source/Motion.swift Source/Ball.swift Source/Clips.swift Tools/stylecheck/main.swift \
  -framework AppKit -framework Metal -framework QuartzCore -framework Accelerate -framework AVFoundation -o "$BIN/stylecheck"
"$BIN/stylecheck" "$@"
