# Band intro asset notices

## Hand and forearm skin

The hand and forearm in `band-intro.mp4` and `band-intro-poster.png` (in `Loopr/Loopr/Resources/Onboarding/`) come from BodyParts3D.

BodyParts3D, © The Database Center for Life Science, licensed under CC Attribution-Share Alike 2.1 Japan.

- Source: https://dbarchive.biosciencedbc.jp/en/bodyparts3d/download.html
- License: https://creativecommons.org/licenses/by-sa/2.1/jp/deed.en

We took the skin surface (FMA7163) from the Crimpwell hand model, which already adds a rig to the BodyParts3D mesh. For the film we smoothed the skin's rig weights at the wrist, posed the fingers and wrist, subdivided the skin, drew it as a see-through shell with a pale cyan edge, animated it, and rendered it with a band that we modelled ourselves. `build_scene.py` can also render the earlier realistic skin with nails (`LOOPR_SKIN=real`), only the bones inside the shell (`LOOPR_SKIN=ghost-bones`), or the BodyParts3D bones, muscles and wrist tendons inside it (`LOOPR_SKIN=ghost-anatomy`). The same credit and license apply to those renders. The film and the poster are adaptations of BodyParts3D, so they are licensed under CC BY-SA 2.1 JP. If you reuse or change them, give the same credit and share your version under the same license.

## Everything else

`build_scene.py` generates the band procedurally: the pod, knit strap, titanium frame, cap and slider, materials, lights and camera. `backdrop.py` draws the dark studio backdrop behind the hand from a formula. Neither file uses logos, text or third-party product assets. The band is a generic fitness band design, and its shapes are our own.

## Band product stills

`band-product.png`, `band-product-pairing.png` and `band-product-tap.png` (in `Loopr/Loopr/Resources/Onboarding/`) show the band on its own, with no hand. The band is our own model. `build_scene.py` builds it and `product_stills.py` renders it on a transparent background, so the stills contain no BodyParts3D data and the CC BY-SA terms above don't apply to them. The pairing still adds a small blue light on the side of the pod. The band carries no logo or text.
