"""判断一段生成的绿幕视频能不能拿来切桌宠动作。

    python3 Tools/checkvideo/check.py 视频.mp4 [参考图.png]

逐项检查：背景是否干净、猫是否全程完整在画面内、是不是一镜到底（有没有跳帧换镜头）、
体型是否稳定、有没有多出来的东西，并写一张缩略图供肉眼复核。不合格会直接说明重做时要强调什么。
"""
import subprocess, sys, os, collections
import numpy as np
from PIL import Image

video = sys.argv[1]
reference = sys.argv[2] if len(sys.argv) > 2 else None
FPS, W, H = 12, 480, 270          # 抽帧分析用的分辨率，够判断轮廓
proc = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-vf", f"fps={FPS},scale={W}:{H}",
                       "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True)
raw = proc.stdout
n = len(raw) // (W * H * 3)
if n < 2:
    print("读不出画面：", proc.stderr.decode()[:400]); sys.exit(1)
frames = np.frombuffer(raw, np.uint8)[:n * W * H * 3].reshape(n, H, W, 3).astype(np.int16)
duration = n / FPS
print(f"时长约 {duration:.1f} 秒，分析了 {n} 帧")

# 背景从首帧的边框自己学：绿幕、地板、渐变都算背景，不假设一定是纯绿
def learn_background(frame):
    edge = np.concatenate([frame[:14].reshape(-1, 3), frame[-14:].reshape(-1, 3),
                           frame[:, :10].reshape(-1, 3), frame[:, -10:].reshape(-1, 3)])
    quantised = (edge // 24) * 24
    counts = collections.Counter(map(tuple, quantised))
    total = len(quantised)
    return np.array([c for c, k in counts.items() if k / total > 0.02], dtype=np.int16)

palette = learn_background(frames[0])
def split(frame):
    d = np.abs(frame[:, :, None, :] - palette[None, None, :, :]).sum(axis=3).min(axis=2)
    return d < 60
background = np.stack([split(f) for f in frames])
cat = ~background

def despeckle(mask):
    """去掉零散噪点：只留下四邻居也都在前景里的像素。"""
    out = np.zeros_like(mask)
    out[1:-1, 1:-1] = mask[1:-1, 1:-1] & mask[:-2, 1:-1] & mask[2:, 1:-1] & mask[1:-1, :-2] & mask[1:-1, 2:]
    return out

def main_body(mask):
    """猫所在的矩形（按行列投影找主体），以及落在它之外的前景像素数。"""
    if not mask.any(): return None, 0
    def run(counts):
        keep = counts > max(2, counts.max() * 0.06)
        best = (0, 0, 0); start = None
        for i, k in enumerate(np.append(keep, False)):
            if k and start is None: start = i
            elif not k and start is not None:
                if i - start > best[0]: best = (i - start, start, i - 1)
                start = None
        return best[1], best[2]
    y0, y1 = run(mask.sum(1)); x0, x1 = run(mask.sum(0))
    inside = mask[y0:y1+1, x0:x1+1].sum()
    return (x0, y0, x1, y1), int(mask.sum() - inside)

issues, notes = [], []

# 1. 背景：边框一圈应该全是绿的，而且颜色不漂移
border = np.concatenate([background[:, :3].reshape(n, -1), background[:, -3:].reshape(n, -1),
                         background[:, :, :3].reshape(n, -1), background[:, :, -3:].reshape(n, -1)], axis=1)  # 上下左右各三行/列
clean = border.mean(axis=1)
greens = frames[:, :6, :6].reshape(n, -1, 3).mean(axis=1)
drift = np.abs(greens - greens.mean(axis=0)).max()
notes.append(f"背景干净度 {clean.mean()*100:.1f}%（最低 {clean.min()*100:.1f}%），底色漂移 {drift:.0f}/255")
if clean.min() < 0.85: issues.append("画面边上出现了首帧没有的东西（最低一帧只有 %.0f%% 还是背景）：重做时强调「背景全程不变，除了猫什么都不要进画面」" % (clean.min()*100))
if drift > 25: issues.append("背景颜色在变（可能有灯光变化或转场）：强调「背景颜色全程不变」")

# 2. 猫：完整、单只、大小稳定
heights, bottoms, widths, touch, blobs, masks = [], [], [], 0, 0, []
for i in range(n):
    clean_mask = despeckle(cat[i])
    masks.append(clean_mask)
    box, extra = main_body(clean_mask)
    if box is None: heights.append(0); bottoms.append(0); widths.append(0); continue
    x0, y0, x1, y1 = box
    heights.append(y1 - y0 + 1); bottoms.append(y1); widths.append(x1 - x0 + 1)
    if x0 <= 1 or x1 >= W - 2 or y0 <= 1: touch += 1   # 底边不算：猫本来就站在地上
    if extra > clean_mask.sum() * 0.08: blobs += 1
heights = np.array(heights); bottoms = np.array(bottoms)
notes.append(f"猫高 {heights.min()}-{heights.max()}px（波动 {heights.std()/max(1,heights.mean())*100:.0f}%），脚线波动 {bottoms.max()-bottoms.min()}px")
if touch > n * 0.05: issues.append(f"{touch}/{n} 帧里猫碰到或超出画面左右/上边缘：强调「猫始终完整在画面内，留出边距，不要出画」")
elif touch: notes.append(f"{touch} 帧里猫略微贴边，切片时注意")
if blobs > n * 0.2: notes.append(f"{blobs} 帧里画面上不止猫一个东西（是毛线球之类的道具就没关系，是别的猫或家具就要重做）")
if heights.std() / max(1, heights.mean()) > 0.25: issues.append("猫的大小变化过大（可能有推拉镜头）：强调「固定机位，不要变焦推拉」")

# 3. 一镜到底：相邻分析帧的剪影重合度，突然掉下去就是切了镜头
ious, jumps = [], []
for i in range(n - 1):
    inter = (masks[i] & masks[i+1]).sum(); union = (masks[i] | masks[i+1]).sum()
    ious.append(inter / union if union else 0)
    jumps.append(np.abs(frames[i+1] - frames[i]).mean())
ious, jumps = np.array(ious), np.array(jumps)
# 真正的切镜头两件事同时发生：剪影对不上，整幅画面也变了。只有剪影变是猫动得快，不算。
typical = max(1e-3, float(np.median(jumps)))
cuts = [(i + 1) / FPS for i in range(n - 1) if ious[i] < 0.35 and jumps[i] > typical * 3]
notes.append(f"相邻帧（{FPS}fps 抽样）剪影重合度 均值 {ious.mean():.2f}，最低 {ious.min():.2f}；画面变化最大是常态的 {jumps.max()/typical:.1f} 倍")
if cuts: issues.append(f"疑似切镜头，在第 {', '.join(f'{t:.1f}' for t in cuts[:6])} 秒：强调「一镜到底，全程不要切镜头、不要转场」")

# 4. 和参考图比：还是不是同一只猫
if reference and os.path.exists(reference):
    ref = np.array(Image.open(reference).convert("RGB").resize((W, H))).astype(np.int16)
    refmask = despeckle(~((ref[...,1] - np.maximum(ref[...,0], ref[...,2])) > 30))
    def norm(m):
        ys, xs = np.where(m)
        box = m[ys.min():ys.max()+1, xs.min():xs.max()+1]
        im = Image.fromarray((box*255).astype(np.uint8)).resize((160, 160))
        return np.array(im) > 127
    a = norm(refmask)
    sims = [ (a & norm(masks[i])).sum() / (a | norm(masks[i])).sum() for i in range(0, n, max(1, n//12)) if masks[i].any() ]
    notes.append(f"与参考图的相似度 首帧 {sims[0]:.2f}，全程最低 {min(sims):.2f}")
    if sims[0] < 0.75: issues.append("开头就不像参考图那只猫：重做时把参考图作为首帧，强调「保持参考图里猫的外形和比例」")

sheet = os.path.splitext(video)[0] + "-检查.png"
step = max(1, n // 24)
tiles = [Image.fromarray(frames[i].astype(np.uint8)) for i in range(0, n, step)][:24]
grid = Image.new("RGB", (W//2 * 6, H//2 * ((len(tiles)+5)//6)), (255,255,255))
for i, t in enumerate(tiles):
    grid.paste(t.resize((W//2, H//2)), (W//2 * (i % 6), H//2 * (i // 6)))
grid.save(sheet)

print("\n".join("· " + x for x in notes))
print()
if issues:
    print("❌ 这段不建议用：")
    for x in issues: print("  - " + x)
else:
    print("✅ 可以用：背景干净、猫全程完整、一镜到底、体型稳定")
print(f"\n缩略图：{sheet}")
