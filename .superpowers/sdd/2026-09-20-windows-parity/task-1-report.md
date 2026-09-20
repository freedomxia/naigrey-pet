# Task 1 — rig, animation and interaction

Implemented original Swift rig export, WebGL2 renderer and CatMotion numeric port. Eight layers retain exact baked masks, base art and slot wiring; idle no longer scales a flat PNG or crossfades whole faces to blink. Eye squeezing and closed-eye mask swap, gaze, pupils, breathing, petting, ears, delayed tail bends, sniff, meow/yawn reveals, sleeping and walking mechanics are ported. Video actions remain the default for large actions, as in the Mac release.

Renderer integrates exact idle, pointer attention and strokes, carried sway/squash and landing. Drag interrupts clips safely, including in-flight video loading. Movement now honors every clip's moveFrom/moveTo, including standUp/sitDown; walking mirrors with the Mac 180 ms turn. Sleep exits through wake. Company typing/music loops continue while desired state matches, update typing speed, and leave through their exit clips. AI blink is supported without a large action. Fallback autonomous selection now uses Mac meow, drowsy probabilities and typing suppression.

Ball physics is a dependency-free port of Source/Ball.swift, including gravity 1500, bounce .42, floor damping .96, wall damping .6, friction 240, 100 ms fling history and 1400 speed cap. New standalone ball HTML/JS/CSS draws the same yarn design and sends drag commands. Root owns native window placement, life cycle, play chase and ball visibility.

## Integration interface

- `state.prefs.catHeight`: 72/100/130/140/170 CSS pixels; ground 307 in a 520×320 window (CENTER_X 260).
- `state.prefs.systemCompanion=true`: disable renderer fallback autonomous controller.
- `state.company`: typing/type/music or none/null. Continuous loop while matching; exits through typeOut/musicOut.
- `state.typeRate`: typing rate, clamped .25–3.
- `state.facingRight` or `state.direction`: mirror walk/stand/sit; play art naturally faces right.
- `state.senses.pointer`: local CSS {x,y}; fixated optional. Root may feed global cursor transformed into local coordinates, or ball gaze.
- action blink/meow/stop supported alongside named clip actions.
- phase emitted for each clip and idle on settle/error/cancel. walk-step is signed and includes transitional movement windows.
- play clip end: `ball-hand-off` value `{point:{x,y},velocity:{x,y}}`, local CSS coordinates and desktop y-down velocity.
- ball UI accepts `state.ball = YarnBall.snapshot()`, sends ball-grab/move/release with screen {x,y}.

## Verification

Tests were written first and failed on missing motion/ball modules. 30 subsystem tests now pass, including 1232 parameters compared with the unchanged Swift reference, all packed map sizes/alpha channels, per-part idle activation, all pose parameter finiteness, planted stride, mouth busy gates, ball trajectories/fling cap, company indefinite loops, hand-off mirroring, and clip movement windows.

Live Electron smoke on macOS compiled WebGL2, loaded/decompressed masks, rendered hundreds of changing idle frames, decoded all 16 transparent clips and completed playback. A real Chromium screenshot was captured and visually inspected: original cat art renders at expected ground and size. Root will run integrated smoke after wiring the controller.

## Limits

Actual Windows GPU, native pointer hit-testing, multiple monitors and installed NSIS execution require Windows CI/manual validation. Export requires macOS but shipped data/rendering are portable. Stochastic schedules preserve Swift distributions, not Swift RNG bit identity. GLSL/WebGL and Metal may differ slightly at transparent sampling edges. Main-process routine/session/ball controller behavior is root-owned and outside this commit.

## Review fixes

Expanded the logical viewport to 520×320 (ground307, center260) after decoding every frame of all 16 clips and finding both vertical and horizontal visible-pixel clipping at size170. The alpha-bound fixture includes SHA256 media hashes and tests all supported sizes, both orientations and both anchor endpoints. Added an actual-pet.js VM regression proving that a cancelled decoder error cannot reset a newer action. Renderer catch now rejects stale generation failures before changing state.
