#!/bin/zsh
# 把纯绿背景视频抠成透明 ProRes 母版：Tools/key.command 输入.mp4 输出-透明.mov
set -euo pipefail
cd "${0:A:h}/.."
python3 Tools/key/key.py "$@"
