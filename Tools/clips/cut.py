"""把一段抠好的透明视频切成桌宠用的片段。

    python3 Tools/clips/cut.py 透明素材.mov 输出目录 模式 [片段名前缀]

模式：
  walk    一段「坐→起身→走→停下→坐回」的素材，切成 standUp / walk（循环）/ sitDown 三段，
          三段首尾相接、不留缝；走路段自动找步态循环点并测出地面速度。
  inout   一段「坐→道具进画→有规律地做事→道具出画→坐回」的素材（打字、听歌），切成
          <名字>In / <名字> / <名字>Out 三段，中间那段是循环。
  simple  一段「坐→做一件事→坐回」的素材，整段切成一个片段。

每个片段都记下白爪子中心（App 用它把猫踩在同一条地面线上）、裁剪框、时长；坐姿高度从首帧量，
因为所有素材都是从同一张参考图生成的，首帧就是待机那只猫。
"""
import json, os, subprocess, sys, tempfile
import numpy as np
from PIL import Image

src, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]
prefix = sys.argv[4] if len(sys.argv) > 4 else ""
info = subprocess.run(["ffmpeg", "-i", src], capture_output=True).stderr.decode()
import re
m = re.search(r",\s(\d{3,5})x(\d{3,5})[,\s]", info)
W, H = int(m.group(1)), int(m.group(2))
FPS = float(re.search(r"(\d+(?:\.\d+)?)\s+fps", info).group(1)) if re.search(r"(\d+(?:\.\d+)?)\s+fps", info) else 24.0
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", src, "-f", "rawvideo", "-pix_fmt", "rgba", "-"], capture_output=True).stdout
n = len(raw) // (W * H * 4)
frames = np.frombuffer(raw, np.uint8)[:n * W * H * 4].reshape(n, H, W, 4)
print(f"{W}x{H} @{FPS}fps, {n} 帧")

alpha = frames[..., 3]
lum = frames[..., 0] * 0.3 + frames[..., 1] * 0.59 + frames[..., 2] * 0.11
shape = []
for i in range(n):
    a = alpha[i] > 40
    ys, xs = np.where(a)
    bottom = int(ys.max())
    band = slice(max(0, bottom - 55), bottom + 1)
    white = (alpha[i][band] > 120) & (lum[i][band] > 180)
    wy, wx = np.where(white)
    shape.append(dict(x0=int(xs.min()), x1=int(xs.max()), y0=int(ys.min()), y1=bottom,
                      anchor=[float(wx.mean()) if len(wx) else float(xs.mean()), float(bottom)]))
sit_height = float(np.median([shape[i]["y1"] - shape[i]["y0"] for i in range(min(6, n))]))
print(f"坐姿高度 {sit_height:.0f}px")

def silhouette(i): return (alpha[i] > 100)[::4, ::4]

def aligned_iou(i, j):
    """两帧按白爪子对齐后的剪影重合度——App 就是按爪子把片段踩在地面线上的，所以这才是屏幕上的接缝。"""
    dx = int(round(shape[j]["anchor"][0] - shape[i]["anchor"][0]))
    dy = int(round(shape[j]["anchor"][1] - shape[i]["anchor"][1]))
    a = alpha[i] > 120
    b = np.roll(np.roll(alpha[j] > 120, -dy, axis=0), -dx, axis=1)
    return (a & b).sum() / (a | b).sum()

def find_loop(lo, hi):
    """走路段里最合适的一个完整步态：接缝按爪子对齐后最吻合的那一对。"""
    best = None
    for period in range(14, 30):
        for start in range(lo, hi - period):
            score = aligned_iou(start, start + period)
            if best is None or score > best[2]: best = (start, period, score)
    return best

def paw_series():
    """逐帧测「贴地的爪子往后滑了多少」，既用来定地面速度，也用来判断每一帧猫是不是真的在走。"""
    return [paw_speed(i, i + 1) for i in range(n - 1)] + [0.0]

def paw_speed(lo, hi):
    """着地的爪子每帧往后滑多少：在底部条带取小块，到下一帧里找最佳匹配。"""
    moves = []
    for i in range(lo, min(hi, n - 1)):
        bottom = shape[i]["y1"]
        band = slice(max(0, bottom - 18), bottom - 1)   # 只看贴地的那一层，几乎都是着地的爪子
        row, arow = lum[i][band], alpha[i][band]
        mask = (arow > 150) & (row > 175)
        cols = np.where(mask.sum(0) > 4)[0]
        if len(cols) < 10: continue
        for x in np.linspace(cols.min() + 12, cols.max() - 12, 14).astype(int):
            patch = lum[i][band, x-11:x+11]
            if patch.shape[1] < 22 or (arow[:, x-11:x+11] > 150).mean() < 0.5: continue
            scores = [(np.abs(lum[i+1][band, x-11+d:x+11+d] - patch).mean(), d)
                      for d in range(-26, 27) if lum[i+1][band, x-11+d:x+11+d].shape == patch.shape]
            if scores:
                score, d = min(scores)
                if score < 12: moves.append(d)
    moves = np.array(moves)
    if len(moves) == 0: return 0.0
    # 着地的爪子往后走，摆动的腿往前甩：取往后那一群的中位数
    back = moves[moves > 0]
    return float(np.median(back)) if len(back) > len(moves) * 0.3 else float(np.median(moves))

def best_scale_against(reference, f1):
    """把末帧和参考坐姿（待机那只画的猫）按脚线对齐，搜一遍缩放取剪影最吻合的那个倍数。
    比单纯对齐高度可靠：模型有时会让猫坐得更挺，那时候按高度缩就会缩过头。"""
    ref = np.array(Image.open(reference).convert("RGB")).astype(np.int16)
    refmask = ~((ref[..., 1] - np.maximum(ref[..., 0], ref[..., 2])) > 30)
    rys, rxs = np.where(refmask)
    ref_box = refmask[rys.min():rys.max()+1, rxs.min():rxs.max()+1]
    cat = alpha[f1] > 120
    cys, cxs = np.where(cat)
    cat_box = cat[cys.min():cys.max()+1, cxs.min():cxs.max()+1]
    best = (0.0, 1.0)
    for step in range(-20, 21):
        factor = 1 + step * 0.02
        h = max(4, int(cat_box.shape[0] * factor)); w = max(4, int(cat_box.shape[1] * factor))
        scaled = np.array(Image.fromarray((cat_box * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR)) > 127
        H2 = max(h, ref_box.shape[0]); W2 = max(w, ref_box.shape[1]) + 40
        a = np.zeros((H2, W2), bool); b = np.zeros((H2, W2), bool)
        a[H2-ref_box.shape[0]:, (W2-ref_box.shape[1])//2:(W2-ref_box.shape[1])//2+ref_box.shape[1]] = ref_box
        b[H2-h:, (W2-w)//2:(W2-w)//2+w] = scaled
        score = (a & b).sum() / (a | b).sum()
        if score > best[0]: best = (score, factor)
    print(f"  末帧与画的猫最佳吻合 {best[0]:.2f}，需要 ×{best[1]:.2f}")
    return best[1]

def frame_scale(f0, f1, ratio):
    """模型有时会在一段里慢慢改变大小。按「运动进行到哪」把缩放逐帧拉回去：猫动得最多的时候
    校正得最多，静止时不动，所以看不出来在缩放。"""
    if not ratio or abs(ratio - 1) < 0.04: return None
    small = (alpha[f0:f1+1] > 120)[:, ::6, ::6]
    motion = np.array([0.0] + [float((small[i] ^ small[i-1]).sum()) for i in range(1, len(small))])
    progress = np.cumsum(motion) / max(1e-6, motion.sum())
    print(f"  缩放校正 ×{ratio:.2f}，按运动进度分摊")
    return 1 + (ratio - 1) * progress

def write_clip(name, f0, f1, loop=False, speed=None, pingpong=False, rescale=None, ball=False):
    """f0..f1 含头含尾；loop 的片段最后一帧不写（它等于第一帧）。"""
    last = f1 - 1 if loop else f1
    keep = range(f0, last + 1)
    x0 = min(shape[k]["x0"] for k in keep); x1 = max(shape[k]["x1"] for k in keep)
    y0 = min(shape[k]["y0"] for k in keep); y1 = max(shape[k]["y1"] for k in keep)
    pad = 10
    x0, y0 = max(0, x0 - pad), max(0, y0 - pad)
    x1, y1 = min(W, x1 + pad + 1), min(H, y1 + pad + 1)
    cw, ch = (x1 - x0) + (x1 - x0) % 2, (y1 - y0) + (y1 - y0) % 2
    x0 = min(x0, W - cw); y0 = min(y0, H - ch)
    count = last - f0 + 1
    blend = 2 if loop else 0     # 循环接缝处把尾巴几帧往开头混，掩掉步态对不齐的那一点
    scales = frame_scale(f0, last, rescale)
    clip = dict(name=name, file=f"{name}.mov", duration=round(count / FPS, 4), size=[cw, ch],
                start=[round(shape[f0]["anchor"][0] - x0, 1), round(shape[f0]["anchor"][1] - y0, 1)],
                end=[round(shape[last]["anchor"][0] - x0, 1), round(shape[last]["anchor"][1] - y0, 1)])
    if loop:
        clip["loop"] = True
        clip["end"] = clip["start"]
    if pingpong: clip["pingPong"] = True
    if speed: clip["speed"] = round(speed, 1)
    if ball:
        seen = [(k, ball_at(k)) for k in keep]
        seen = [(k, b) for k, b in seen if b]
        if seen:
            (k0, b0), (k1, b1) = seen[0], seen[-1]
            before = next((b for k, b in seen if k >= k1 - 4), b1)
            clip["ballStart"] = [round(b0[0] - x0, 1), round(b0[1] - y0, 1)]
            clip["ballEnd"] = [round(b1[0] - x0, 1), round(b1[1] - y0, 1)]
            dt = max(1, k1 - max(k0, k1 - 4)) / FPS
            clip["ballVelocity"] = [round((b1[0] - before[0]) / dt, 1), round((b1[1] - before[1]) / dt, 1)]
            print(f"  球：{clip['ballStart']} → {clip['ballEnd']}，速度 {clip['ballVelocity']}")
    tmp = os.path.join(tempfile.mkdtemp(), f"{name}.mov")
    writer = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba",
                               "-s", f"{cw}x{ch}", "-r", str(FPS), "-i", "-", "-an", "-c:v", "prores_ks",
                               "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-alpha_bits", "16", tmp],
                              stdin=subprocess.PIPE)
    for k in keep:
        piece = frames[k, y0:y0+ch, x0:x0+cw].astype(np.float32)
        if scales is not None:
            f = float(scales[k - f0])
            if abs(f - 1) > 0.002:      # 以脚掌为原点缩放，猫才不会离地或陷进地面
                px = shape[k]["anchor"][0] - x0; py = shape[k]["anchor"][1] - y0
                img = Image.fromarray(piece.astype(np.uint8), "RGBA").resize((max(1, int(cw * f)), max(1, int(ch * f))), Image.LANCZOS)
                canvas = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
                canvas.paste(img, (int(round(px - px * f)), int(round(py - py * f))))
                piece = np.array(canvas).astype(np.float32)
        tail = last - k
        if blend and tail < blend:                     # 最后几帧渐渐变成开头那几帧
            mix = (blend - tail) / (blend + 1)
            head = frames[f0 + (blend - 1 - tail), y0:y0+ch, x0:x0+cw].astype(np.float32)
            piece = piece * (1 - mix) + head * mix
        writer.stdin.write(np.clip(piece, 0, 255).astype(np.uint8).tobytes())
    writer.stdin.close(); writer.wait()
    target = os.path.join(out, f"{name}.mov")
    if os.path.exists(target): os.remove(target)
    subprocess.run(["avconvert", "--source", tmp, "--preset", "PresetHEVCHighestQualityWithAlpha",
                    "--output", target, "--replace"], check=True, capture_output=True)
    print(f"{name}: 帧 {f0}-{last}（{count} 帧 {count/FPS:.2f}s）裁剪 {cw}x{ch}+{x0}+{y0} -> {os.path.getsize(target)//1024} KB")
    return clip

def trim_still(f0, f1, margin=3):
    """掐掉片段头尾一动不动的部分：素材里每段前后都有一两秒静坐，留着只是让反应变慢、体积变大。"""
    small = (alpha > 120)[:, ::6, ::6]
    def moved(i, ref): return (small[i] ^ small[ref]).sum() > small[ref].sum() * 0.03
    a = f0
    while a < f1 and not moved(a + 1, f0): a += 1
    b = f1
    while b > a and not moved(b - 1, f1): b -= 1
    return max(f0, a - margin), min(f1, b + margin)

def ball_at(k):
    """画面里的粉色毛线球（猫的鼻子舌头也是粉的，用面积挡掉）。"""
    rgb = frames[k, ..., :3].astype(np.int16)
    pink = (rgb[..., 0] > 150) & (rgb[..., 2] > 110) & (rgb[..., 1] < rgb[..., 0] - 30) & (alpha[k] > 120)
    if pink.sum() < 3000: return None
    ys, xs = np.where(pink)
    # 球出画时只剩一半，质心会往回缩，速度就会算反：只认还完整在画面里的球
    if xs.min() <= 2 or xs.max() >= W - 3 or ys.max() >= H - 3: return None
    return float(xs.mean()), float(ys.mean())

os.makedirs(out, exist_ok=True)
clips = []
if mode == "walk":
    # 猫先坐着，起身，走，停下，坐回去。找走路段中间最吻合的一对帧作为循环。
    moving = [i for i in range(n) if shape[i]["x1"] - shape[i]["x0"] > (shape[0]["x1"] - shape[0]["x0"]) * 1.4]
    lo, hi = moving[0] + 6, moving[-1] - 6
    # 开头的静坐不要带进片段：从画面真正开始变化的前几帧起
    begin = 0
    for i in range(1, n):                      # 开头连续不动的那一段
        if (silhouette(i) ^ silhouette(0)).sum() > silhouette(0).sum() * 0.04:
            begin = max(0, i - 3); break
    start, period, score = find_loop(lo, hi)
    series = np.array(paw_series())
    smooth = np.convolve(series, np.ones(5) / 5, mode="same")
    speed = float(np.median(smooth[start:start + period * 2])) * FPS
    walking = smooth > abs(speed / FPS) * 0.45      # 这一帧猫是不是真的在往前走
    print("逐帧地面速度（px/帧）:", " ".join(f"{v:.0f}" for v in smooth[::10]))
    print(f"走路段 {lo}-{hi}，循环 {start}→{start+period}（{period} 帧，吻合 {score:.3f}），地面速度 {speed:.0f}px/秒")
    # 三段首尾相接：起身到循环起点，一个完整步态，从同相位的那一帧开始坐下
    # 收尾从「还在走」的最后一个同相位帧开始，否则会切在转身途中，和走路循环对不上
    last_walking, gap = start, 0
    for i in range(start, min(n, len(walking))):        # 走到第一次连续停下来为止，转身时爪子的动作不算
        if walking[i]: last_walking, gap = i, 0
        else:
            gap += 1
            if gap >= 3: break
    settle = start + ((last_walking - start) // period) * period
    print(f"开头静坐到第 {begin} 帧")
    def moving_window(f0, f1):
        """片段里真正在走的那一段（秒），窗口只在这段时间里跟着移动。"""
        on = [i for i in range(f0, f1 + 1) if i < len(walking) and walking[i]]
        if not on: return None, None
        return round((on[0] - f0) / FPS, 3), round((on[-1] - f0 + 1) / FPS, 3)

    up = write_clip(prefix + "standUp", begin, start)
    a, b = moving_window(begin, start)
    if a is not None: up.update(speed=round(speed, 1), moveFrom=a, moveTo=b)
    clips.append(up)
    clips.append(write_clip(prefix + "walk", start, start + period, loop=True, speed=speed))
    down = write_clip(prefix + "sitDown", settle, n - 1)
    a, b = moving_window(settle, n - 1)
    if a is not None: down.update(speed=round(speed, 1), moveFrom=a, moveTo=b)
    clips.append(down)
elif mode == "inout":
    # 一段「坐 → 道具进画 → 有规律地做事（可循环）→ 道具出画 → 坐回来」：切成进场 / 循环 / 退场三段
    names = (sys.argv[4] + "In", sys.argv[4], sys.argv[4] + "Out")
    lo, hi = int(n * 0.2), int(n * 0.85)
    start, period, score = find_loop(lo, hi)
    print(f"循环 {start}→{start+period}（{period} 帧 {period/FPS:.2f}s，接缝 {score:.3f}）")
    # 还在循环里的最后一帧：和循环中同相位的那一帧还对得上，就算还在做同一件事
    last = start
    for i in range(start + period, n):
        if aligned_iou(i, start + (i - start) % period) > score - 0.08: last = i
        elif i - last > period: break
    settle = start + ((last - start) // period) * period
    begin, _ = trim_still(0, start)
    _, finish = trim_still(settle, n - 1)
    clips.append(write_clip(names[0], begin, start))
    clips.append(write_clip(names[1], start, start + period, loop=True))
    clips.append(write_clip(names[2], settle, finish))
elif mode == "split":
    # 一段「坐 → 趴下 → 睡着」：动作停下来的地方切开，后半段做成循环
    small = (alpha > 120)[:, ::6, ::6]
    motion = np.array([0.0] + [float((small[i] ^ small[i-1]).sum()) / max(1, small[i].sum()) for i in range(1, n)])
    calm = np.convolve(motion, np.ones(12) / 12, mode="same")
    settled = next((i for i in range(n // 3, n) if calm[i] < calm.max() * 0.15), n * 2 // 3)
    names = (sys.argv[4], sys.argv[5])
    print(f"动作在第 {settled} 帧（{settled/FPS:.1f}s）停下来")
    a, _ = trim_still(0, settled)
    clips.append(write_clip(names[0], a, settled))
    clips.append(write_clip(names[1], settled, n - 1, loop=True, pingpong=True))
elif mode == "settle":
    # 结尾要接回待机的画猫：把模型自己推近造成的放大拉回去
    a, b = trim_still(0, n - 1)
    ratio = best_scale_against(sys.argv[5], b) if len(sys.argv) > 5 else None
    clips.append(write_clip(prefix, a, b, rescale=ratio))
elif mode == "ball":
    a, b = trim_still(0, n - 1)
    clips.append(write_clip(prefix, a, b, ball=True))
else:
    a, b = trim_still(0, n - 1)
    clips.append(write_clip(prefix or os.path.splitext(os.path.basename(src))[0], a, b))

path = os.path.join(out, "clips.json")
library = {"sitHeight": sit_height, "clips": clips}
if os.path.exists(path):
    previous = json.load(open(path))
    fresh = {c["name"]: c for c in clips}
    merged = [fresh.pop(c["name"], c) for c in previous["clips"]]
    library["clips"] = merged + [c for c in clips if c["name"] in fresh]
    library["sitHeight"] = sit_height
json.dump(library, open(path, "w"), ensure_ascii=False, indent=2)
print("写出", path)
