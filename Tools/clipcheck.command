#!/bin/zsh
# Places each video clip exactly as the app does next to the drawn cat and writes a PNG for checking alignment.
set -euo pipefail
cd "${0:A:h}/.."
BIN=$(mktemp -d "${TMPDIR:-/tmp/}naigrey-clipcheck.XXXXXX")
trap 'rm -rf "$BIN"' EXIT
xcrun swiftc -O -target arm64-apple-macos13.0 Source/Sprites.swift Source/Rig.swift Source/Renderer.swift Source/Motion.swift Source/Ball.swift Source/Clips.swift Tools/clipcheck/main.swift \
  -framework AppKit -framework Metal -framework QuartzCore -framework Accelerate -framework AVFoundation -o "$BIN/clipcheck"
"$BIN/clipcheck" "$@"
