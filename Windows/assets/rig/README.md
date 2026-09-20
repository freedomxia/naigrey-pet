# Original Mac rig assets

Generated without changing `Source/Sprites.swift`, `Source/Rig.swift`, or `Source/Motion.swift`. The sprite crop keeps the original two-pixel transparent margin. All eight layers (idle, wave, sleep, walking body and four independent legs) retain the Swift slot wiring and 20-channel RGBA8 masks.

Rebuild on macOS from the repository root:

```sh
swiftc Source/Sprites.swift Source/Rig.swift Source/Motion.swift Windows/scripts/export-rig.swift -o /tmp/naigrey-export-rig
/tmp/naigrey-export-rig Windows/assets/cats.png Windows/assets/rig
python3 Windows/scripts/pack-rig.py
```

`*.rgba.gz` is gzip-compressed raw RGBA8, top row first. These are data channels, including alpha, not color images. Encoding them as ordinary PNG would subject the fourth channel and RGB to premultiplication/color transforms. `rig.json` supplies dimensions, 154 rest parameters, and slot names. `motion-reference.json` contains all 1232 initial parameters from the unmodified Swift implementation for numeric regression tests. Artwork PNGs use the original atlas, byte-identical to `docs/images/cat-poses.png`; edge pixels are preserved.

`pet-renderer.js` ports Metal inverse displacement to WebGL2 with five map textures, three art textures, trilinear art filtering and premultiplied blending. WebGL clamp-to-zero is implemented explicitly in the shader. `pet-motion.cjs` ports springs, breathing, gaze, blinking, mouth reveals, ears, tail lag, strokes, walking gait, sleep dreaming and waving equations. Random distributions are the same; the injected JS random generator does not claim bitwise equivalence with Swift's seeded RNG.
