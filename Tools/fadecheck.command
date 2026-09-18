#!/bin/zsh
# 把切换动作那一瞬间的真实合成结果画出来（三种做法对比）：Tools/fadecheck.command 输出.png [片段名]
set -euo pipefail
cd "${0:A:h}/.."
BIN=$(mktemp -d "${TMPDIR:-/tmp/}naigrey-fadecheck.XXXXXX")
trap 'rm -rf "$BIN"' EXIT
xcrun swiftc -O -target arm64-apple-macos13.0 Source/Sprites.swift Source/Rig.swift Source/Renderer.swift Source/Motion.swift Source/Ball.swift Source/Clips.swift Tools/fadecheck/main.swift \
  -framework AppKit -framework Metal -framework QuartzCore -framework Accelerate -framework AVFoundation -o "$BIN/fadecheck"
"$BIN/fadecheck" "$@"
