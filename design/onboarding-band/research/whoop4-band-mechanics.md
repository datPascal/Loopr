# WHOOP 4.0 SuperKnit band: physical mechanics

Research date: 2026-09-27. Purpose: reference for animating an unbranded look-alike band going onto a wrist and closing.

Tags: **[P]** primary (WHOOP support, WHOOP YouTube channel, WHOOP patents). **[S]** secondary. **[I]** my inference from primary material; treat as unverified. Video timestamps are m:ss, read from frames sampled at 1 fps, so they can be off by about 1 s.

## Sources

| Key | Source | Notes |
|---|---|---|
| SUP-FL | [Changing Bands with the Fast Link™ Slider](https://support.whoop.com/s/article/Changing-Bands-with-the-new-Fast-Link-Slider), WHOOP Support, published 2025-12-12 | Covers 4.0, 5.0 and MG |
| SUP-SET | [Setting Up Your WHOOP](https://support.whoop.com/s/article/Setting-Up-Your-WHOOP-4-0), WHOOP Support | |
| SUP-BAS | [WHOOP Basics](https://support.whoop.com/s/article/WHOOP-Basics), WHOOP Support | |
| V-WEAR | "How to Wear Your WHOOP 4.0", WHOOP channel, 2021-09-23, 0:59, https://www.youtube.com/watch?v=cxVN6zSjWPc | 4.0 |
| V-SWAP | "How to Swap Your WHOOP Band", WHOOP channel, 2022-04-08, 0:43, https://www.youtube.com/watch?v=y4qVoWFiYI8 | 4.0 |
| V-TIGHT | "How To Tighten Your WHOOP Band", WHOOP channel, 2022-01-21, 0:37, https://www.youtube.com/watch?v=iDIEDKbAyIw | 4.0 |
| V-PUT5 | "How to Put On Your WHOOP Band", WHOOP channel, 2026-08-06, 0:38, https://www.youtube.com/watch?v=JuOKxzXdEgg | **5.0/MG hardware**, used only where 4.0 footage is missing |
| V-TIPS5 | "WHOOP Wear Tips and Troubleshooting", WHOOP channel, 2026-08-06, 0:54, https://www.youtube.com/watch?v=O2VKid7WkmM | **5.0/MG hardware**, same caveat |
| PAT-746 | [US12295746B2](https://patents.google.com/patent/US12295746B2/en) "Adjustable strap for wearable monitor", Whoop Inc, priority 2020-10-16, granted 2025-05-13 | Utility patent: clasp, hook and buckle |
| PAT-D350 | [USD1018350S1](https://patents.google.com/patent/USD1018350S1/en) "Wearable strap with linking member", Whoop Inc, filed 2021-06-15, granted 2024-03-19 | Design patent. Cites the 4.0 SuperKnit shop page as prior art |
| S-WHICH | [Which? review of the Whoop 4.0 Superknit Band](https://www.which.co.uk/news/article/whoop-4.0-superknit-band-review-asqDO2W8K5Yd) | [S] |
| S-AA | [Android Authority WHOOP 4.0 review](https://www.androidauthority.com/whoop-4-0-review-3249953/) | [S] |
| S-RCI | "How to Clasp and Unclasp the WHOOP 4.0", RCInsight (not WHOOP), https://www.youtube.com/watch?v=1Vr2NBJ6RbE | [S], auto-captions only |

Not used: US10149518B1 "Clasp assembly for a wearable device" shows up in WHOOP-clasp searches, but it is assigned to **Apple**. I also didn't use FCC filings: I could not confirm the 4.0 sensor's FCC ID, and FCC photos show the electronics, not the band.

## 1. Parts, geometry, materials

The assembly has four rigid parts plus the textile band. WHOOP's own naming is inconsistent: support calls the pivot prongs "the hook", while V-SWAP calls the prong frame "the clasp". This doc uses the functional names below.

| Part | What it is | Evidence |
|---|---|---|
| **Sensor (pod)** | A small rounded rectangular block. The top face is plain and dark. The underside has the optical window (green LEDs). It has a pinhole on each long side near one end (the pivot end) and a transverse channel at the other end for the slider. | SUP-FL: "2 prongs of the hook ... sensor's pinholes, one from either side of the sensor" [P]. V-SWAP 0:03–0:05 exploded render [P]. V-TIGHT 0:14–0:17 mentions the "green LEDs" [P] |
| **Clasp frame** | A rigid U-shaped frame: two thin side arms joined by a cross member at the free end. The arm tips turn inward into prongs that sit in the sensor's pinholes and act as the hinge. It rotates at least 180°: open, it points away from the sensor; closed, it lies over the sensor. | PAT-746 claim 1: "a pair of arms", "cross member", "rotatable ... between a closed position overlapping the monitoring device and an open position extending away from the monitoring device"; claim 14: "at least 180 degrees" [P]. V-SWAP 0:24–0:30 shows the bare frame with bent prong tips being hooked into the sensor [P] |
| **Hook / end cap** | A cap on the band's fixed end that hooks onto the frame's cross member. On 4.0 it carries the engraved "WHOOP" wordmark; this is the "logo end" users press and lift. | PAT-746 claim 1: "a hook affixed to the first end of the band, the hook rotatably coupled to the cross member" [P]. SUP-FL: "The clasp is the part of the band with the WHOOP logo or 'W'" [P]. V-SWAP 0:03–0:08 render shows the cap sitting on the cross member [P] |
| **Fast Link™ slider (buckle)** | A C-section bar on the band's other end. It slides sideways (across the band width, parallel to the hinge axis) into the channel at the sensor end opposite the hinge, and clicks in. The band weaves through two slits in it, which is where you set the length. | PAT-746 claim 1: "c-shaped cross section", "linearly removable ... along the axis transverse to the band", "overlapping path for adjustably securing the band"; claim 6: "two adjacent slits" [P]. SUP-SET: "press it in until it clicks" [P]. SUP-FL: "Slide this part to either side, away from the sensor" [P] |
| **Band** | A single elastic knit strap. Fixed end goes to the hook/cap; adjustable end goes through the slider; the short tail sits past the slider. | PAT-746 claim 4: "elastic woven material"; claim 2: "high friction material on a surface contacting the monitoring device when the clasp is in the closed position" [P] |

**Dimensions**

- **4.0 sensor:** WHOOP publishes no 4.0 dimensions in the sources above. Secondary figures are 25.1 × 36 × 10.3 mm and 27 g with the band [S-WHICH]; a spec site gives 35.97 × 25 × 10.1 mm [S, seen only in a search snippet, not fetched]. WHOOP gives 5.0 as 34.7 × 24 × 10.6 mm and says it is "about 7% smaller than 4.0" [P, SUP-BAS], which fits the ~36 × 25 mm secondary figures.
- **Clasp frame:** no published size. When closed, the arms run the full sensor length [P, PAT-746 claim 1 "overlapping"], so the frame is roughly the sensor's footprint, about 36 × 25 mm [I]. The side arms look wire-thin in V-SWAP 0:24–0:25 [P, visual only].
- **Band:** in every WHOOP 4.0 render and clip, the band looks as wide as the sensor [P, visual]. One secondary spec lists 22 mm [S, unverified]. These disagree, so treat the width as about 22–25 mm. I found no band thickness from any source.
- **Wrist fit range:** a 145–215 mm range appears only in a secondary search snippet [S, unverified].

**Materials and colours**

- The sensor housing looks like dark matte plastic in the videos. S-WHICH says "The plastic feels sturdy" [S]. WHOOP names no 4.0 housing material in these sources.
- S-AA calls the clasp "metallic" [S]. WHOOP's 4.0 footage shows the cap and frame in anodised-looking finishes that match or complement the band: black on black (V-WEAR 0:10–0:17), silver on red (0:46), teal on light teal (0:44–0:45, 0:51), gold on white (V-SWAP 0:07–0:08) [P, visual]. I found no primary statement of the clasp alloy. Treat it as metal-look, alloy unknown.
- The knit is fine, in solid or heathered colours; V-WEAR 0:44–0:47 shows light-teal, red and yellow bands with a raised rib pattern [P, visual]. PAT-746 lists "rubber, nylon, synthetic fiber, or the like" as possible elastic materials [P]. I found no fibre composition for SuperKnit.

## 2. Where the sensor sits and how it attaches

- **Slider end:** the Fast Link slider slides sideways into the channel on one end of the sensor until it sits "flush with both edges of the sensor" and clicks. If it is upside down it won't go in; the right way up, slider and sensor edge "fit together like a jigsaw" [P, SUP-FL; SUP-SET "press it in until it clicks"; V-SWAP 0:31–0:35; V-TIPS5 0:03–0:10].
- **Pivot end:** the clasp prongs push into the two pinholes on the sensor's sides at the opposite end [P, SUP-FL; V-SWAP 0:24–0:30 "Hook the new clasp into the indentations"; V-TIPS5 0:11–0:23 "Locate the 2 small holes on either side of the device, and attach your clasp"].
- **Which side of the wrist:** the top (dorsal) side, window against the skin: "The sensor should always face down on your wrist" [P, V-TIPS5 0:33–0:39, 5.0 footage]. Every 4.0 on-wrist shot shows it on the back of the wrist [P, V-WEAR 0:24–0:36; V-TIGHT 0:07–0:17].
- **Distance from the wrist bone:** "about 1 inch above your wrist bone" [P, V-WEAR 0:26–0:30; V-TIGHT 0:08–0:13], or "one finger-width above your wrist bone" [P, SUP-BAS FAQ]. "Above" means up the forearm, away from the hand.
- **Orientation:** the sensor's long axis runs around the wrist, not along the forearm, and the hinge axis runs along the forearm [P, visual in V-PUT5 0:27–0:31 and V-TIPS5 0:25–0:29]. WHOOP never says whether the hinge end sits on the thumb side or the little-finger side. **Unknown.**

## 3. Putting it on, tightening, taking it off

**Band path when closed** (PAT-746 claim 1 plus the V-SWAP 0:03–0:08 render) [P]:

1. The slider sits in the channel at sensor end B.
2. The band leaves the slider and runs around the underside of the wrist.
3. It comes up at sensor end A (the hinge end).
4. It runs back over the top of the sensor, under the frame arms.
5. It ends at the hook/cap on the frame's cross member, which now sits over end B, on top of the slider. The closed arms overlap the slider's ends, which stops the slider from sliding out (PAT-746 claim 1, claim 7).

**Sequence:**

1. **Open the clasp.** Lift the logo end of the frame. The frame swings about the pinholes at end A and flips outward, away from the sensor. V-WEAR 0:15–0:17: "Open the clasp with the WHOOP logo facing you" [P]. When open, the frame lies along the band's curve: "Make sure the clasp follows the curve of the band" [P, V-TIPS5 0:24–0:29, 5.0].
2. **Slide it on.** The band is a closed loop, and with the clasp open it is big enough to pass over the hand. V-WEAR 0:22–0:24: "Slide your band on" [P]. V-PUT5 0:18–0:27: "Pull tab, then slide onto wrist" [P, 5.0]. S-RCI 0:30–0:35 adds that you can't slide it over while it is closed [S].
3. **Position it** on top of the wrist, about 1 inch above the wrist bone (section 2).
4. **Close.** Swing the frame back up and over, about 180°, until it lies on the sensor. The hooked band end is dragged up and over the sensor top, and the loop tightens [P, V-PUT5 0:27–0:31 frames: frame flat, then raised, then folded down]. Press the logo end down. SUP-FL: "Once the clasp is drawn over the sensor, pressing on the WHOOP logo or 'W' symbol will click the band into place over the sensor." V-PUT5 0:28–0:35: "You'll feel and hear a 'click' when it's in place" [P, 5.0].
   - **The click is at the logo end,** over the slider end of the sensor. PAT-746 describes a spring bar on the sensor whose protrusions engage indents on the clasp arms to hold the clasp closed [P]. (Claim 10 says the spring bar holds the clasp *open*; the description says *closed*. The patent contradicts itself here.) S-RCI 0:53–1:12: "you have to be quite forceful and it pops up ... it just clips on to these little buttons" [S].
   - **How much the loop tightens:** closing moves the frame out of the loop and lays about one frame-length of band on top of the sensor, so the loop shrinks by roughly twice the clasp length, about 70 mm [I, geometry only; no source states a figure].
5. **Set the length.** This happens at the slider, not the clasp. "To tighten the band, pull the short end toward you"; "To loosen your band, pull the longer end toward you" [P, V-TIGHT 0:18–0:26, shown off-wrist with the slider in view]. V-WEAR 0:37–0:40: "Loosen or tighten the fit by gently pulling on the band" [P]. The target fit: "tight enough that you can't slide a finger underneath the band" [P, V-WEAR 0:32–0:36], and no green LED light leaking out [P, V-TIGHT 0:14–0:17]. The set length stays when you swap bands, because the slider holds it [P, PAT-746 abstract].
6. **Take it off.** "Pull up on the band's clasp from beneath ... The band should then open with a click and be loose enough to slip off your hand" [P, SUP-FL]. V-SWAP 0:10–0:14 shows the frame lifted on the wrist; with it up, the sensor's plain dark top is exposed [P].

## 4. At rest on the wrist

- **Top face:** knit band covers the sensor's top. The frame's two thin metal-look side arms border it along the long edges, and the end cap runs across one end (the slider end). No plastic shows on top [P, V-WEAR 0:44–0:47 renders; V-SWAP 0:09–0:10 and 0:36–0:39; V-TIGHT 0:14–0:17].
- **Sides:** the sensor's dark sides show below the frame arms [P, V-SWAP 0:36–0:39].
- **Visible metal:** the cap and both arms, plus the end of the slider bar if seen side-on [P visual; alloy unknown].
- **Excess tail:** the short end left over after the slider folds back and runs along the **inner** face of the loop, starting at the slider end. It is hidden when worn [P, PAT-D350 FIG. 1–2 show the tail running inside the loop; V-TIGHT 0:18–0:21 shows the short end leaving the slider on the skin side]. There is no keeper loop. Confidence is medium: I found no WHOOP text that states where the tail goes.

## 5. WHOOP branding to avoid

- The "WHOOP" wordmark engraved on the 4.0 end cap [P, V-WEAR 0:10–0:17], and the "W" on the 5.0/MG cap [P, SUP-FL; V-TIPS5 0:23].
- The circled-W logo on the battery pack and in video end cards [P, V-PUT5 0:12; V-WEAR 0:55].
- The "WHOOP / 4.0" marks, and the product names Fast Link™ and SuperKnit.
- **The overall ornamental design.** PAT-D350 is an active WHOOP design patent covering the strap with its C-shaped linking member and the doubled-back band look, expiring 2039-03-19 per Google Patents [P]. A look-alike that copies those shapes closely could raise design-patent or trade-dress questions even with no logo on it. **This is not legal advice; have someone qualified check before release.** Ways to stay clearly generic: leave the cap blank and change its proportions, skip the knurled texture on the slider (V-SWAP 0:07–0:08), and don't copy the exact frame silhouette.

## Open gaps

- Which wrist side the hinge sits on (thumb side or little-finger side). Not stated anywhere I found.
- Clasp alloy, band fibre, band thickness, and any official 4.0 dimensions.
- Official band width: the video visuals suggest about 25 mm, a secondary spec says 22 mm.

## Animation beats

A 3–4 s clip for the unbranded look-alike, starting from an empty wrist. Assumes the band length is already set (the real band stores it in the slider).

1. **0.0–0.6 s, approach.** The band arrives as a closed loop with the frame swung open, about 180° out from the hinge end and lying along the loop's curve. The sensor window faces into the loop and the blank cap is on the outside of the open frame.
2. **0.6–1.3 s, slide on.** The loop passes over the hand and settles on the back of the wrist, one finger-width up from the wrist bone. The sensor's long axis runs around the wrist and the window sits flat on the skin.
3. **1.3–2.1 s, swing over.** A fingertip lifts the free (cap) end of the frame. The frame rotates about the hinge axis, which runs along the forearm, up through vertical and down over the sensor. The band hooked to the cap follows it up and over the sensor top, and the loop visibly tightens (about 70 mm of slack gone [I]).
4. **2.1–2.5 s, press and click.** The cap reaches the far end of the sensor, above the slider. The fingertip presses down, there is a tiny overtravel, then a snap into the detent. Sync the click sound and haptic here.
5. **2.5–3.5 s, settle.** The finger lifts away. Final pose: knit band covers the sensor top, thin metal-look rails run along both long edges, the blank cap sits across the slider end, the dark sensor sides show below the rails, and the tail is hidden inside the loop.
