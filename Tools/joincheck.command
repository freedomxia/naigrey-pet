#!/bin/zsh
# 检查每个动作接缝上，前一段结尾和后一段开头对不对得上：Tools/joincheck.command 输出.png
set -euo pipefail
cd "${0:A:h}/.."
BIN=$(mktemp -d "${TMPDIR:-/tmp/}naigrey-joincheck.XXXXXX")
trap 'rm -rf "$BIN"' EXIT
xcrun swiftc -O -target arm64-apple-macos13.0 Source/Sprites.swift Source/Rig.swift Source/Renderer.swift Source/Motion.swift Source/Ball.swift Source/Clips.swift Tools/joincheck/main.swift \
  -framework AppKit -framework Metal -framework QuartzCore -framework Accelerate -framework AVFoundation -o "$BIN/joincheck"
"$BIN/joincheck" "$@"
