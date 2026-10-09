# Band intro: render/app contract

Shared between the Blender lane (renders the film) and the iOS lane (plays it, adds text and haptics).
Change a value here only if both sides are updated in the same change.

## Beats (seconds from first frame)

| Beat | Time | What happens |
|---|---|---|
| Hand in | 0.00 to 1.40 | Dark scene. The backdrop's pool of light fades up with the lights over the first 0.35 s, so the hand reads from its first frames in view. Hand and forearm glide in from lower right and settle, slight rotation, fingers relax. |
| Band in | 1.40 to 1.90 | The band flies in open from the right, pod first, and lands on the back of the wrist. The strap trails from the pod's slider end and lies out to the side of the wrist with its cap end free. The frame stands open at the other end. |
| Wrap | 1.90 to 3.00 | The strap swings in and wraps the wrist from the slider end. It runs down one side, across the underside and up the other side, a small constant distance off the skin. At 2.47 s its cap reaches the frame's tip. The frame then swings over the pod and pulls the strap across the top, and the loop tightens. Motion accelerates into the close. |
| Click | 3.00 | The cap lands over the far end of the pod and snaps shut. Hard stop, a tiny overtravel and recoil of the band, micro reaction of the hand, a glint along the frame and cap, sensor pod light pulses once. |
| Settle | 3.00 to 4.60 | Camera eases back slightly. Upper third of the frame becomes clean negative space for text. |
| Hold | 4.60 | Last frame. The app holds it as the background. |

## Files (all under `Loopr/Loopr/Resources/Onboarding/` in the app target)

- `band-intro.mp4`: HEVC, 60 fps, 1080 x 2340 (iPhone aspect), no audio, <= 8 MB, composited onto the studio backdrop below. The backdrop's border is exactly the background color below, so the edges are seamless against the SwiftUI background.
- `band-intro-poster.png`: the final frame (used for Reduce Motion and as the held frame).
- Anatomy cut: `LOOK=anatomy ./render.sh all` renders the same film in the anatomy look (see Look) as `band-intro-anatomy.mp4` and `band-intro-anatomy-poster.png`, same format, beats and background. The app doesn't ship it: Pascal chose the ghost film on 2026-09-29.
- `band-intro.timings.json`: `{"fps":60,"duration":4.6,"handInEnd":1.4,"bandIn":1.4,"wrapStart":1.9,"click":3.0,"settleEnd":4.6,"background":"#RRGGBB","textSafeTopFraction":0.36}`. `textSafeTopFraction` is the fraction of frame height from the top that stays free of hand/band in the final frame. `render.sh encode` measures it on the last frame and fails if the film reaches above the committed value. It never rewrites the file, so the file stays byte-identical while the film keeps the text area clear.
- `band-product.png`, `band-product-pairing.png`, `band-product-tap.png`: the closed band alone, 1024 px square, transparent, for the pairing sheet and the band setup screen (`./render.sh product`, `product_stills.py`). The pairing still lights a small blue LED on the pod's side edge. The film's pod has no side LED.

## Background

The Blender lane renders with a transparent film and composites onto the backdrop with `composite.py`. The iOS lane uses the hex from the timings JSON for the screen background. Default `#07090B` unless the app's DesignSystem onboarding background says otherwise (the iOS lane decides and records it here first; the Blender lane reads this file before its final composite).

**Final: `#0A0D11`.** Decided by the iOS lane. This is the DesignSystem `background` token in dark mode (`LooprPackages/Sources/DesignSystem/DesignTokens.swift`), the color behind every onboarding screen, so the film's edges meet the app with no seam. Write it into `band-intro.timings.json` as `"background":"#0A0D11"`. The intro screen always renders this color, even when the phone is in light mode.

**Studio backdrop.** The film sits on a dark studio backdrop, not on a flat color. `backdrop.py` defines it. It's one cool hue over `#0A0D11`, a soft pool of light behind the wrist. At its brightest it's `#26323F`, and it falls off to exactly `#0A0D11` well before every edge of the frame. It never reaches the top 43.8% (`textSafeTopFraction`), so the text area is flat `#0A0D11`. The pool fades up from nothing with the lights over the first 0.35 s, so frame 1 is plain `#0A0D11`.

- The hand and band are composited over the pool. Colour is floored at `#0A0D11`, not at the pool, so the near-black strap and pod stay dark in front of the light.
- Where the pool has light, `composite.py` adds a fine grain of about three 10-bit codes, and the encoder runs with `-tune grain`. Without it the gradient bands on 8-bit displays. The border gets no grain, so the edges stay exactly `#0A0D11`.
- `backdrop.py` also has the two candidates that lost: a haze with a light shaft, and a cyclorama with a horizon and a floor glow (`LOOPR_BG=haze|cyc`). Both put structure into the text area or read as a floor under a floating hand. `review/bg_candidates.png` shows all three.

## Look

The hand and forearm render as a see-through shell with a pale cyan edge (`LOOPR_SKIN=ghost`, the default in `build_scene.py`). The band stays solid and lit. At the click the sensor's green light also glows through the wrist. The look doesn't change any time or the background.

The ghost reads as dark, clear glass. Camera rays that pass through the skin see the backdrop at 35% of its light (`LOOPR_GLASS_SEE`), so the hand is a darker glass shape with a bright rim against the pool, not a milky one. The same shader ramp that draws the backdrop in Blender is solved against the view transform. The glass also carries a faint 3% veil of the rim colour (`LOOPR_GHOST_OPACITY`), so on a phone the hand reads as a shape and not as a hole in the pool. The veil fades out toward the elbow with the rim, so the forearm still meets the frame edge at `#0A0D11`.

The rim is tight to the silhouette (`LOOPR_GHOST_POWER` 10). Where a ray passes through one skin fold and meets another, such as a finger behind a finger or the palm behind the curled fingers, the second fold gets 45% of the rim (`LOOPR_GHOST_LAYER2`), so the fingers read as separate shapes. The fingers fan out slightly, a little more toward the little finger. The skin renders at subdivision level 2 and the lens stops down to f/11 (f/8.8 at the click), with the focus 15 mm from the clasp toward the knuckles, so the fingers 7 to 9 cm behind the band stay sharp. Parts of the band seen through the skin, such as the strap's far run under the wrist, keep half their light. That reads as "behind the glass", not "inside the arm".

The anatomy film (`LOOPR_SKIN=ghost-anatomy`) puts the bones, the muscles and the tendons that cross the wrist inside the same shell, in Crimpwell's colors, on the same backdrop. The muscles are a see-through red, thin where they face the camera and denser at their edges. Everything fades out toward the elbow with the skin. As the strap wraps, the tissue under it thins out, so the strap reads in front of it. All of it stays at least 0.75 mm inside the skin (`--verify` checks this at six frames, the finger twitch after the click included).

## Band mechanics

The band closes the way a WHOOP 4.0 band does (research: `research/whoop4-band-mechanics.md`), but its parts are generic and carry no marks. The sensor pod sits on the back of the wrist, about a finger-width above the wrist bone, with its window against the skin. A thin U-shaped metal frame hinges on pins at one end of the pod (end A, on the little-finger side). A blank cap on the strap's fixed end hooks onto the frame's free end and pivots there. The strap's other end sits in a slider at the pod's other end (end B), and the spare tail stays hidden inside it.

The film simplifies one thing. On a real band the cap stays on the frame, so the band is always a closed loop. Here the cap end starts free, and the strap wraps before the cap meets the frame. The loop never passes over the hand.

- Band in: the pod lands on the wrist. The frame stands about 150° open at end A. The strap hangs from the slider at end B, lying out beside the wrist.
- Wrap: the strap swings in and curls around the wrist, then snugs onto it from end B. It runs down one side, across the underside and up the other, on the snug fit described below. At 2.47 s (frame 149) its cap reaches the frame's tip.
- Close: the frame swings about the hinge, up and over the pod, and drags the strap over the pod's top. The strap goes from about 159 mm around the wrist to 180 mm, so the loop goes taut exactly at the click.
- Click: the cap lands over end B at full speed, overtravels by under a degree and is back at rest five frames later.
- Closed: the knit covers the pod's top, with metal rails along both long edges and the cap across end B. The cap is a plate, 2.45 mm thick and 0.45 mm proud of the knit, that holds the strap's end and follows the pod's end rounding down over end B, so it sits nearly flush with the pod's end.

**Snug fit.** The strap is fitted to the wrist, not to a hull around it. `build_scene.py` slices the skin every 0.5 mm across the band and offsets each slice by 0.7 mm (an exact disc offset, taken along rays from the wrist's centre). Across the band the forearm tapers by 1 to 7 degrees, so the strap's inner face at each angle is a line across its width, fitted to the slices and raised until it clears all of them. The strap and the pod's hardware follow that taper. Around the wrist the strap follows the offset skin, dents included. It only bridges the two corners where the pod's ends meet the wrist. Closed, the strap's inner face sits 0.7 to 1.0 mm off the skin at both edges and 0.75 to 1.3 mm at its centre line. The palm side is slightly hollow across the width. The loop's plane is within 1.1 degrees of the forearm's local axis.

`build_scene.py` bakes this per frame. `--verify` checks every frame and every half frame from `bandIn` to 10 frames after the click, plus the last frame. The half frames are there because the motion-blur shutter sees the band between baked frames. It checks against the skin at its render subdivision, the surface the camera sees, and reports the smallest band-to-skin distance before the click and from the click on. At no checked frame does the strap, frame, cap, slider or pod enter the skin. The minimum is +0.67 mm before the click (the strap, frame 159) and +0.55 mm from the click on (the pod, frame 183).

## Band model

The band has to read as a real product at film size, where it's about 300 px wide in the last frame. `build_scene.py` models it in millimetres.

- Pod: 36 x 26 x 7.5 mm. Every edge is rounded, 3.3 mm over the top and bottom and 6 mm at the four corners seen from above, and the top domes by 0.55 mm. The plastic is near-black, matte and bead-blasted, with no coat and only a faint sheen, so it never turns mid-grey under the film's lights. The top carries a 0.05 mm step in the same plastic, not a separate panel. A fine parting line runs round the sides 2.6 mm up, and the shell below it has a smoother satin finish.
- Strap: knit, 22 mm wide and 1.9 mm thick. The edges are rounded right over and carry a tighter, smoother binding. The knit has fine V stitches, a raised rib on every second column, heathered yarn and a microfibre sheen. It has almost no gloss, so it stays near black.
- Frame: each side is one bent bar. It runs along the pod's long edge as a rail, 2.8 mm tall and 1.3 mm deep, flat toward the pod and rounded on the outside. Over end A it turns down in a tight bend, 0.25 mm inside radius, and stops just past the hinge pin. Both tips are rounded.
- Cap: a plate with 0.7 mm edges and 2.2 mm corners, brushed across the band. It's a darker anodised finish than the rails, so it never outshines them.
- Metal: anodised titanium, brushed along each part.
- Light: a strip behind the band and a low fill under it light the strap, rails and slider. Both leave out the pod and the cap, because the strip turned their tops grey. Five reflection cards sit where the camera sees their mirror image in the band. Only glossy rays see them, and light linking limits four of them to the metal and one to the pod. They put a line along the rail tops, a band along the near rail and a gradient over the cap. `product_stills.py` places its own cards for each view.
- Settle: the camera ends 10% closer than the first film did (distance factor 0.90) with the band lower in the frame, so the text area keeps its margin. The last frame's subject top is at 0.450 by mesh, against the committed `textSafeTopFraction` of 0.438.

## Haptics (iOS lane)

- Approach: soft continuous swell from `bandIn` to `wrapStart` (sharpness 0.03), a bell that follows the start of the rise sound and lands on 0.15, where the rise starts.
- Rising: continuous haptic from `wrapStart` to `click`, intensity 0.15 to 0.85 and sharpness 0.05 to 0.3 along an ease-in curve, synced to video time. Deep and dull, to match the sound.
- Click: transient at `click`, intensity 1.0, sharpness 0.9, plus a softer latch tick 45 ms later (intensity 0.5, sharpness 1.0), then a short soft decay (intensity 0.3, sharpness 0.1) from 60 ms that fades over 200 ms on the event's own envelope. No control curve runs after the click.
- Text reveal starts at `click` + 0.12 s.

## Sound (iOS lane)

`sound/make_sounds.py` writes `band-intro-approach.caf` and `band-intro-click.caf` next to the film. They are generated from `band-intro.timings.json`, so rerun it after any change to the beats or the latch delay.

- Approach, from `bandIn`: a deep rise. A detuned saw climbs an octave from E1 while its filter opens, over a sub and a rumble. Most of the climb happens during the wrap. It goes silent 12 ms before the click.
- Click, from `click`: a clean latch click (snap, short hard shell resonances, a little body), a latch tick 45 ms later and a short small room. No echo. Its RMS sits about 8 dB above the end of the rise.
- Both play on the haptic engine in the same pattern as the haptics, in an ambient audio session: they mix with the user's music and the silent switch mutes them. Reduce Motion plays the click sound at 0.55 volume with the single light click.

## Copy (final, already checked against the unslop rules)

- Wordmark: `Loopr`
- Line: `Own your health data. Free, forever.`
- Button: `Get started`
