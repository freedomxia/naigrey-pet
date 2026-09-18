#!/bin/zsh
# 检查一段生成的绿幕视频能不能用来切桌宠动作：Tools/checkvideo.command 视频.mp4 [参考图.png]
set -euo pipefail
cd "${0:A:h}/.."
python3 Tools/checkvideo/check.py "$@"
