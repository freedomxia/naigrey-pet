#!/usr/bin/env python3
"""Rebuild Windows alpha assets on macOS. Requires Swift and ffmpeg with libvpx.

Run: python3 Windows/scripts/convert-assets.py
AVFoundation decodes Apple's HEVC alpha (ffmpeg's HEVC decoder drops it).
The raw BGRA stream is encoded as VP9 alpha, retaining native size and 24 fps.
Every result is decoded with libvpx-vp9 and checked for animated frames and alpha.
Metadata coordinates are unchanged because no spatial scaling is performed.
"""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Assets/clips'
DEST = ROOT / 'Windows/assets/clips'
FFMPEG = shutil.which('ffmpeg')
if not FFMPEG:
    raise SystemExit('ffmpeg is required (with libvpx-vp9 encoder and decoder)')
DEST.mkdir(parents=True, exist_ok=True)
metadata = json.loads((SOURCE / 'clips.json').read_text())
report = []
with tempfile.TemporaryDirectory(prefix='naihui-assets-') as temp:
    exporter = str(pathlib.Path(temp) / 'export-clips')
    subprocess.run(['swiftc', '-O', str(ROOT / 'Windows/scripts/export-clips.swift'), '-o', exporter], check=True)
    for clip in metadata['clips']:
        source = SOURCE / clip['file']
        info = json.loads(subprocess.check_output([exporter, str(source), '--inspect']))
        width, height = info['width'], info['height']
        assert [width, height] == clip['size'], (clip['name'], info)
        assert abs(info['duration'] - clip['duration']) < .001
        target = DEST / (clip['name'] + '.webm')
        with tempfile.TemporaryFile() as log:
            decoder = subprocess.Popen([exporter, str(source)], stdout=subprocess.PIPE, stderr=log)
            encoder = subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y',
                '-f', 'rawvideo', '-pixel_format', 'bgra', '-video_size', f'{width}x{height}',
                '-framerate', str(info['fps']), '-i', 'pipe:0', '-an', '-c:v', 'libvpx-vp9',
                '-pix_fmt', 'yuva420p', '-b:v', '0', '-crf', '32', '-deadline', 'good',
                '-cpu-used', '4', '-row-mt', '1', '-auto-alt-ref', '0', str(target)], stdin=decoder.stdout)
            decoder.stdout.close()
            code = decoder.wait()
            log.seek(0)
            decode_log = log.read().decode()
            if code or encoder.returncode:
                raise RuntimeError(f'{source}: {decode_log}')
            original = json.loads(decode_log)
        # Force libvpx: ffmpeg's native VP9 decoder does not expose alpha.
        verify = subprocess.Popen([FFMPEG, '-hide_banner', '-loglevel', 'error', '-c:v', 'libvpx-vp9',
            '-i', str(target), '-f', 'rawvideo', '-pix_fmt', 'rgba', 'pipe:1'], stdout=subprocess.PIPE)
        count = 0
        minimum, maximum = 255, 0
        hashes = set()
        frame_bytes = width * height * 4
        while True:
            frame = verify.stdout.read(frame_bytes)
            if not frame:
                break
            assert len(frame) == frame_bytes, 'truncated frame'
            alpha = frame[3::4]
            minimum, maximum = min(minimum, min(alpha)), max(maximum, max(alpha))
            hashes.add(hashlib.sha256(frame).digest())
            count += 1
        assert verify.wait() == 0
        assert count == original['frames'] and len(hashes) > 1
        assert minimum == 0 and maximum == 255
        clip['file'] = target.name
        record = dict(name=clip['name'], width=width, height=height, fps=info['fps'], frames=count,
            distinctFrames=len(hashes), sourceAlphaMin=original['alphaMin'], sourceAlphaMax=original['alphaMax'],
            webmAlphaMin=minimum, webmAlphaMax=maximum, bytes=target.stat().st_size)
        report.append(record)
        print(json.dumps(record), flush=True)
(DEST / 'clips.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
(DEST / 'conversion-report.json').write_text(json.dumps(report, indent=2) + '\n')
shutil.copyfile(ROOT / 'docs/images/cat-poses.png', ROOT / 'Windows/assets/cats.png')
print(f'Converted {len(report)} clips, {sum(r["bytes"] for r in report):,} bytes')
