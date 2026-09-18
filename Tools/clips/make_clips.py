"""Cuts the keyed green-screen video into the pet's action clips.

    python3 Tools/clips/make_clips.py <transparent ProRes 4444 master> Assets/clips

For every clip it finds the tightest crop around the cat, the paw anchors at the first and last frame
(centre of the white paws on the floor, the same measure the app uses for the drawn cat), picks loop
points for looping clips, measures how fast planted paws slide while walking, tracks the video's ball
for the hand-off to the real one, then writes transparent HEVC files and clips.json.
"""
import json, os, subprocess, sys, tempfile
import numpy as np

master, out = sys.argv[1], sys.argv[2]
only = set(sys.argv[3:])  # optional clip names to (re)cut; others keep their entry in clips.json

# The walking cat drifts slowly backwards while its legs move, so that clip is cut with a crop that follows the
# drift (px per frame) and loops over exactly one stride (frames 404-426, silhouettes match within 2%).
# Planted paws then slide back 15 px per frame, checked by eye on a gridded strip of consecutive frames
# (the automatic blob matcher paired different paws and under-read it); the window moves at that speed.
WALK_DRIFT = 0.381
WALK_SPEED = 15.0 * 24
W, H, FPS = 1280, 720, 24

# The master is one continuous take: sit, wave, play with the ball, get up, walk, stretch, sit, yawn, lie
# down, sleep, wake, sit. The actions below are cut from it, and so are the moves *between* them, so the pet
# can get up and settle back down instead of jumping from one pose to another.
# name, start s, end s, loop?, play backwards?
CLIPS = [
    ("wave", 6.0, 8.7, False, False),
    ("play", 9.75, 14.15, False, False),
    ("walk", 404 / 24, 427 / 24, True, False),
    ("stretch", 19.6, 22.0, False, False),
    ("yawn", 22.25, 24.6, False, False),
    ("lieDown", 24.6, 25.7, False, False),
    ("sleep", 25.7, 27.9, True, False),
    ("wake", 27.9, 29.6, False, False),
    # Links. The cat never stands up from sitting anywhere in the take, so that one is the sit played
    # backwards - a slow, deliberate move that reads the same either way.
    ("standUp", 21.3, 22.04, False, True),
    ("sitDown", 21.3, 22.04, False, False),
    ("getUp", 14.2, 404 / 24, False, False),   # ends on the frame the walk loop starts from, so it flows straight in
]

print("reading master…", flush=True)
proc = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-i", master, "-f", "rawvideo", "-pix_fmt", "rgba", "-"], stdout=subprocess.PIPE)
info = []   # per frame: bbox, anchor, ball
small = []  # downscaled alpha for loop matching
paws = []   # white-paw blobs near the floor, for walking speed
n = 0
while True:
    raw = proc.stdout.read(W * H * 4)
    if len(raw) < W * H * 4: break
    f = np.frombuffer(raw, np.uint8).reshape(H, W, 4)
    a = f[..., 3].astype(np.float32) / 255
    rgb = f[..., :3].astype(np.float32)
    red = (rgb[..., 0] > 140) & (rgb[..., 1] < 100) & (rgb[..., 2] < 110) & (a > 0.5)
    cat = (a > 0.05) & ~red
    ys, xs = np.where(cat)
    bottom = int(ys.max())
    luma = 0.3 * rgb[..., 0] + 0.59 * rgb[..., 1] + 0.11 * rgb[..., 2]
    band = slice(max(0, bottom - 45), bottom + 1)
    white = (a[band] > 0.5) & (luma[band] > 190) & ~red[band]
    wy, wx = np.where(white)
    anchor = [float(wx.mean()) if len(wx) else float(xs.mean()), float(bottom)]
    ry, rx = np.where(red)
    ball = [float(rx.mean()), float(ry.mean()), float(rx.max() - rx.min())] if len(rx) > 400 else None
    info.append(dict(x0=int(xs.min()), x1=int(xs.max()), y0=int(ys.min()), y1=bottom, anchor=anchor, ball=ball, redbox=[int(rx.min()), int(ry.min()), int(rx.max()), int(ry.max())] if len(rx) > 400 else None))
    small.append((a[::6, ::6] > 0.3).astype(np.float32))
    # Paw blobs: columns of white fur touching the floor band.
    cols = white[-14:].sum(0) > 3
    runs, x = [], 0
    while x < W:
        if cols[x]:
            s = x
            while x < W and cols[x]: x += 1
            if x - s > 12: runs.append((s + x) / 2)
        x += 1
    paws.append(runs)
    n += 1
print(n, "frames", flush=True)

def frame(t): return min(n - 1, int(round(t * FPS)))

# Scale reference: the sitting cat's height a few seconds in (ears to paws).
sit = [info[frame(t)] for t in (2.5, 3.0, 3.5)]
sit_height = float(np.median([f["y1"] - f["y0"] for f in sit]))
print("sitting height", sit_height)

library = {"sitHeight": sit_height, "clips": []}
tmp = tempfile.mkdtemp(prefix="naigrey-clips-")
os.makedirs(out, exist_ok=True)
for name, t0, t1, loop, backwards in CLIPS:
    f0, f1 = frame(t0), frame(t1)
    if only and name not in only:
        continue
    drift = WALK_DRIFT if name == "walk" else 0.0
    if loop and name != "walk":
        # Choose the end frame within the last 0.8 s whose silhouette best matches the first frame.
        candidates = range(max(f0 + FPS, f1 - int(0.8 * FPS)), f1 + 1)
        f1 = min(candidates, key=lambda k: float(np.abs(small[k] - small[f0]).mean()))
        print(f"{name}: loop {f0}->{f1} mismatch {np.abs(small[f1] - small[f0]).mean():.4f}")
    frames = range(f0, f1 + (0 if loop else 1))
    x0 = min(info[k]["x0"] - drift * (k - f0) for k in frames); x1 = max(info[k]["x1"] - drift * (k - f0) for k in frames)
    x0, x1 = int(np.floor(x0)), int(np.ceil(x1))
    y0 = min(info[k]["y0"] for k in frames); y1 = max(info[k]["y1"] for k in frames)
    if name == "play":  # keep the video's ball in view as well
        for k in frames:
            if info[k]["redbox"]:
                bx0, by0, bx1, by1 = info[k]["redbox"]
                x0, y0, x1, y1 = min(x0, bx0), min(y0, by0), max(x1, bx1), max(y1, by1)
    m = 10
    x0, y0 = max(0, x0 - m), max(0, y0 - m)
    x1, y1 = min(W, x1 + m + 1), min(H, y1 + m + 1)
    cw, ch = (x1 - x0) + (x1 - x0) % 2, (y1 - y0) + (y1 - y0) % 2
    x0 = max(0, min(x0, int(W - cw - drift * (f1 - f0)))); y0 = min(y0, H - ch)
    last = f1 - 1 if loop else f1
    first, final = (last, f0) if backwards else (f0, last)   # played backwards, the last frame is what you see first
    clip = dict(name=name, file=f"{name}.mov", duration=round((last - f0 + 1) / FPS, 4), size=[cw, ch],
                start=[round(info[first]["anchor"][0] - x0, 1), round(info[first]["anchor"][1] - y0, 1)],
                end=[round(info[final]["anchor"][0] - x0, 1), round(info[final]["anchor"][1] - y0, 1)])
    if loop: clip["loop"] = True
    if name == "sleep": clip["pingPong"] = True  # breathing reads the same played backwards, so the loop is seamless
    if name == "walk":
        clip["speed"] = WALK_SPEED
        clip["end"] = clip["start"]  # one stride: the loop ends where it began
    if name == "play":
        b0 = info[f0]["ball"]
        if b0: clip["ballStart"] = [round(b0[0] - x0, 1), round(b0[1] - y0, 1)]
        # Last frame where the ball is still whole in the crop, and its velocity over the previous few frames.
        seen = [k for k in frames if info[k]["ball"]]
        k1 = seen[-1]; k0 = max(seen[0], k1 - 4)
        bv = [(info[k1]["ball"][0] - info[k0]["ball"][0]) / ((k1 - k0) / FPS), (info[k1]["ball"][1] - info[k0]["ball"][1]) / ((k1 - k0) / FPS)]
        clip["ballEnd"] = [round(info[k1]["ball"][0] - x0, 1), round(info[k1]["ball"][1] - y0, 1)]
        clip["ballVelocity"] = [round(bv[0], 1), round(bv[1], 1)]
        print("play ball start", clip.get("ballStart"), "end", clip["ballEnd"], "velocity", clip["ballVelocity"])
    count = (f1 - f0) if loop else (f1 - f0 + 1)
    prores = os.path.join(tmp, f"{name}.mov")
    crop_x = f"'{x0}+{drift}*n'" if drift else str(x0)
    steps = f"select='between(n\\,{f0}\\,{f0 + count - 1})',setpts=N/{FPS}/TB,crop={cw}:{ch}:{crop_x}:{y0}" + (",reverse" if backwards else "")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", master, "-vf", steps,
                    "-frames:v", str(count), "-r", str(FPS), "-an", "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-alpha_bits", "16", prores], check=True)
    target = os.path.join(out, f"{name}.mov")
    if os.path.exists(target): os.remove(target)
    subprocess.run(["avconvert", "--source", prores, "--preset", "PresetHEVCHighestQualityWithAlpha", "--output", target, "--replace"], check=True, capture_output=True)
    library["clips"].append(clip)
    print(f"{name}: frames {f0}-{f0 + count - 1} crop {cw}x{ch}+{x0}+{y0} -> {os.path.getsize(target) // 1024} KB", flush=True)

path = os.path.join(out, "clips.json")
if only and os.path.exists(path):
    # Keep the clips this run did not touch, replace the ones it re-cut, and add any that are new.
    previous = json.load(open(path))
    cut = {c["name"]: c for c in library["clips"]}
    merged = [cut.pop(c["name"], c) for c in previous["clips"]]
    library["clips"] = merged + [c for c in library["clips"] if c["name"] in cut]
json.dump(library, open(path, "w"), ensure_ascii=False, indent=2)
print("wrote", os.path.join(out, "clips.json"))
