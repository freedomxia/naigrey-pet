# Windows animation assets

`cats.png` is an unchanged copy of `docs/images/cat-poses.png`. Crop its original pose cells in Canvas for idle rendering.

`clips/*.webm` are full-motion VP9 videos with an alpha channel, converted from all 16 original `Assets/clips/*.mov` clips. `clips/clips.json` retains the original dimensions, foot anchors, movement speeds, loop flags, timing, and ball coordinates; only `.mov` filenames become `.webm`.

Rebuild on macOS from the repository root:

```sh
python3 Windows/scripts/convert-assets.py
```

Requirements: Xcode command-line tools (`swiftc`), Python 3, and `ffmpeg` on PATH built with the libvpx encoder and decoder. The script compiles `export-clips.swift` in a temporary directory. AVFoundation reads Apple's HEVC alpha into raw BGRA. ffmpeg encodes native-resolution VP9 `yuva420p`, CRF 32, preserving nominal source frame rate (approximately 24 fps). Alpha-enabled HEVC must be decoded with AVFoundation: ffmpeg's ordinary HEVC decoder can silently discard that alpha plane.

The conversion verifies input dimensions/duration against the source metadata, source alpha ranging from 0 to 255, exact decoded frame counts, more than one distinct frame per animation, and output alpha ranging from 0 to 255. The result is recorded in `clips/conversion-report.json`. Output verification explicitly selects `-c:v libvpx-vp9`, because ffmpeg's native VP9 decoder does not expose the WebM alpha plane. Electron/Chromium supports VP9 WebM transparency without requiring a Windows HEVC codec extension.

These checks verify asset integrity. Final playback, interaction, and appearance still require application-level validation.
