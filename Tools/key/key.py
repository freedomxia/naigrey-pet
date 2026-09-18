"""把纯绿背景的视频抠成带透明通道的 ProRes 4444 母版。

    python3 Tools/key/key.py 输入.mp4 输出-透明.mov

针对平整绿幕：背景色从画面四边自动取样，用「绿色过量」求透明度，再按背景反推边缘的真实颜色
（不这么做，毛发边缘会留下一圈暗绿，看起来像黑边），然后去绿返色、清掉零散杂点、补上身体内部
被误判成背景的洞。
"""
import subprocess, sys, os
import numpy as np

src, dst = sys.argv[1], sys.argv[2]
probe = subprocess.run(["ffmpeg", "-v", "error", "-i", src, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True)
# 分辨率从第一帧的字节数反推不了，直接让 ffmpeg 告诉我们
info = subprocess.run(["ffmpeg", "-i", src], capture_output=True).stderr.decode()
import re
m = re.search(r",\s(\d{3,5})x(\d{3,5})[,\s]", info)
W, H = int(m.group(1)), int(m.group(2))
fps = 24.0
if (f := re.search(r"(\d+(?:\.\d+)?)\s+fps", info)): fps = float(f.group(1))
print(f"{W}x{H} @ {fps}fps")

reader = subprocess.Popen(["ffmpeg", "-v", "error", "-i", src, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
writer = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{W}x{H}", "-r", str(fps),
                           "-i", "-", "-an", "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le",
                           "-alpha_bits", "16", dst], stdin=subprocess.PIPE)

def borders(frame):
    return np.concatenate([frame[:12].reshape(-1, 3), frame[-12:].reshape(-1, 3),
                           frame[:, :12].reshape(-1, 3), frame[:, -12:].reshape(-1, 3)])

background = None
count = 0
while True:
    raw = reader.stdout.read(W * H * 3)
    if len(raw) < W * H * 3: break
    frame = np.frombuffer(raw, np.uint8).reshape(H, W, 3).astype(np.float32)
    if background is None:
        background = np.median(borders(frame), axis=0)
        print("背景色", background.astype(int))
    r, g, b = frame[..., 0], frame[..., 1], frame[..., 2]
    # 绿色过量：背景最大，猫身上接近 0，毛发边缘介于两者之间
    excess = g - np.maximum(r, b)
    bg_excess = float(background[1] - max(background[0], background[2]))
    solid, clear = bg_excess * 0.22, bg_excess * 0.82     # 低于 solid 全不透明，高于 clear 全透明
    alpha = np.clip((clear - excess) / (clear - solid), 0, 1)

    # 反推真实颜色：观察到的 = 前景*α + 背景*(1-α)
    a3 = alpha[..., None]
    fg = np.where(a3 > 0.02, (frame - background * (1 - a3)) / np.maximum(a3, 0.02), frame)
    fg = np.clip(fg, 0, 255)
    # 去绿返色：这只猫是灰白的，绿色本就不该超过红蓝的平均。边缘不留余量，否则会留一圈绿描边。
    limit = (fg[..., 0] + fg[..., 2]) / 2 * 1.02
    fg[..., 1] = np.minimum(fg[..., 1], limit)
    # 半透明像素除以很小的 α 会把噪声放大，越靠边越明显：那里直接按周围的毛色走
    faint = (alpha < 0.25)[..., None]
    fg = np.where(faint, np.repeat(((fg[..., 0:1] + fg[..., 2:3]) / 2), 3, axis=2), fg)

    # 清杂点：只去掉真正孤立的碎屑，不碰贴着毛的半透明像素；不向外扩张，否则背景会被拉进来
    a = alpha
    neighbours = np.zeros_like(a)
    neighbours[1:-1, 1:-1] = (a[:-2, 1:-1] + a[2:, 1:-1] + a[1:-1, :-2] + a[1:-1, 2:]) / 4
    a = np.where((a < 0.3) & (neighbours < 0.15), 0, a)
    a = np.where(neighbours > 0.92, np.maximum(a, neighbours), a)   # 补身体内部的洞
    out = np.dstack([fg, a * 255]).astype(np.uint8)
    writer.stdin.write(out.tobytes())
    count += 1
    if count % 48 == 0: print(f"  {count} 帧…", flush=True)

writer.stdin.close(); writer.wait(); reader.wait()
print(f"写出 {dst}（{count} 帧）")
