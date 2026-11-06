# Third-party notices

Loopr incorporates or derives portions of its Bluetooth, protocol, and analytics behavior from MIT-licensed OpenStrap work. The current source tree does not include the OpenStrap Edge, protocol, or analytics source trees. Removing those trees does not remove the attribution requirement.

Loopr is an independent open-source project. It is not affiliated with, sponsored by, endorsed by, or connected to WHOOP, Inc. "WHOOP" is a trademark of WHOOP, Inc. The name appears only to identify hardware that Loopr is designed to communicate with.

Loopr does not include WHOOP source code, binaries, firmware, logos, or other copyrighted product assets.

## OpenStrap

Sources:

- [OpenStrap Edge](https://github.com/OpenStrap/edge)
- [OpenStrap protocol](https://github.com/OpenStrap/protocol)
- [OpenStrap analytics](https://github.com/OpenStrap/analytics)

The reviewed source repositories carry the following license notice:

```text
MIT License

Copyright (c) 2026 OpenStrap

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## GRDB

Loopr uses [GRDB.swift](https://github.com/groue/GRDB.swift), licensed under the MIT License. The complete notice is bundled at `Loopr/Loopr/Resources/Licenses/GRDB-LICENSE.txt`.

## Fonts

Loopr bundles these fonts under the SIL Open Font License 1.1. Each complete license is stored beside its font files.

| Font | License file |
| --- | --- |
| Barlow Condensed | `Loopr/Loopr/Resources/Fonts/BarlowCondensed/BarlowCondensed-OFL.txt` |
| IBM Plex Mono | `Loopr/Loopr/Resources/Fonts/IBMPlexMono/IBMPlexMono-OFL.txt` |
| Manrope | `Loopr/Loopr/Resources/Fonts/Manrope/Manrope-OFL.txt` |
| Space Grotesk | `Loopr/Loopr/Resources/Fonts/SpaceGrotesk/SpaceGrotesk-OFL.txt` |

`SpaceGrotesk-Light.ttf` is the unmodified `ttf/static/SpaceGrotesk-Light.ttf` from the official [Space Grotesk 2.0.0 release](https://github.com/floriankarsten/space-grotesk/releases/tag/2.0.0) ([zip](https://github.com/floriankarsten/space-grotesk/releases/download/2.0.0/SpaceGrotesk-2.0.0.zip), SHA-256 `53b415577d4139248555300710bea0d268c7a5be67b93de53b716a9736cabffd`). The font reports "Version 2.000" and the PostScript name `SpaceGrotesk-Light`. Its SHA-256 is `48ebce72bd4fc089b7750a2a56c3424103f95c63fb4a25f39ca672bb39bb1913`. It carries the same copyright and SIL Open Font License 1.1 as the other Space Grotesk files, so `SpaceGrotesk-OFL.txt` covers it.

## BodyParts3D

The hand and forearm in the onboarding film (`Loopr/Loopr/Resources/Onboarding/band-intro.mp4`) and its poster (`band-intro-poster.png`) are adapted from BodyParts3D.

BodyParts3D, © The Database Center for Life Science, licensed under CC Attribution-Share Alike 2.1 Japan ([source](https://dbarchive.biosciencedbc.jp/en/bodyparts3d/download.html), [license](https://creativecommons.org/licenses/by-sa/2.1/jp/deed.en)).

The film and the poster are adaptations and are licensed under CC BY-SA 2.1 JP. `design/onboarding-band/ASSET_NOTICES.md` lists what we changed.

## Open Food Facts

Barcode product data comes from [Open Food Facts contributors](https://world.openfoodfacts.org/). The database is available under the [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/), and individual database contents under the [Database Contents License 1.0](https://opendatacommons.org/licenses/dbcl/1-0/).

Loopr caches unchanged product responses separately from private meal corrections. Confirmed barcode entries retain the source URL, response, lookup time and licence references in exports. The client does not download product images. Recorded test responses and their request metadata are in `LooprPackages/Tests/FoodKitTests/Fixtures/OpenFoodFacts/`.

## USDA FoodData Central

The food table behind typed and spoken logging (`LooprPackages/Sources/FoodKit/FoodReference.json`) is built from USDA FoodData Central, SR Legacy (April 2018), by `Tools/food-reference/build.py`. U.S. Department of Agriculture, Agricultural Research Service. FoodData Central, 2019. [fdc.nal.usda.gov](https://fdc.nal.usda.gov/). FoodData Central data are in the public domain under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).

## Free Exercise DB

The bundled exercise library (`Loopr/Loopr/Resources/ExerciseLibrary/exercises.v1.json`) is derived from [Free Exercise DB](https://github.com/yuhonas/free-exercise-db) by yuhonas, at commit `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5`. The repository states that the dataset is in the public domain and publishes it under The Unlicense. The complete text is bundled at `Loopr/Loopr/Resources/Licenses/free-exercise-db-LICENSE.txt`. Its data derives from [wrkout/exercises.json](https://github.com/wrkout/exercises.json), which is also published under The Unlicense.

Loopr bundles exercise metadata only: id, name, category, equipment, level, force, mechanic, and primary and secondary muscles. It does not bundle the instructions or any images. `scripts/trim-exercise-library.py` produces the file, and `exercises.v1.provenance.json` records the source hash, the output hash and the exercise count.

Loopr adds movements the dataset lacks (CrossFit and gymnastics movements, holds, carries, beginner variations and mobility drills) in a separate file, `Loopr/Loopr/Resources/ExerciseLibrary/exercises.loopr.v1.json`. Loopr contributors wrote those entries and they are not part of Free Exercise DB. They use the same fields, every id starts with `loopr-`, and they are covered by Loopr's MIT licence. The dataset file is unchanged, so its provenance hash still holds. Other names for exercises in both files, such as "RDL" for Romanian deadlift, are listed in `LooprPackages/Sources/TrainKit/Library/ExerciseSearch.swift`.

```text
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <https://unlicense.org>
```
