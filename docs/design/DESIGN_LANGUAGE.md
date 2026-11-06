# Loopr design language (ratified 2026-08-29, restyled 2026-10-22, premium 2026-10-24)

Read this before writing any screen code. It is the contract for every screen
in the app. The visual contract for the longevity build is
`design/longevity-vision/index.html` (open it with `#still` for final states,
without it for the motion). DEC-09 set the tokens, DEC-12 the tabs and accents.

The acceptance word is **premium**. A screen is done when it is premium, as
defined below, in light and dark, and its capture sits next to the contract
phone with a review line in `docs/execution/visual-reviews/longevity/README.md`.

## Reference implementations, in order of usefulness

| Pattern you need | Read this |
|---|---|
| The craft bar: an object, dots that fly, haptics, tilt | `Loopr/Loopr/App/FoodLensView.swift`, `FoodLensArt.swift`, `FoodMacroBurst.swift` |
| A tab-level screen: header, lens, list, cards | `LooprPackages/Sources/BodyKit/BodyScreens.swift` |
| A dense metric screen with sections and charts | `LooprPackages/Sources/HeartKit/HeartScreens.swift` |
| A form, list or preferences screen, sheets, destructive actions | `LooprPackages/Sources/SettingsKit/SettingsScreens.swift` |
| A screen built from a hero graphic | `LooprPackages/Sources/SleepKit/SleepScreens.swift` |
| The shared vocabulary itself | `LooprPackages/Sources/DesignSystem/` and its gallery (`ComponentGallery.swift`) |

## Premium: the eight checks

1. **One signature object, live.** Each tab has one object drawn from real
   data: the day dial (Today), rings and the eating window (Food), the dose
   field (Fitness), rosettes and the deck (Protocol), the age ruler (Data).
   The object is the data; everything else on the tab is supporting text.
   It has a designed rendering for empty, learning, partial and absent. Each
   of those draws the object's shape with a sentence saying what is missing
   and how it fills in.
2. **Dots land where they count.** Logging food, training, a check-in or a lab
   value sends dots from the source to the object through `LooprDotFlight`.
   The haptic tick per landing dot is capped at 30 a second.
3. **Numbers arrive.** Hero numbers use `LooprHeroNumber`: Space Grotesk Light,
   44 to 76 pt, tabular figures. They count up as their dots land, through
   `contentTransition(.numericText())`.
4. **Light and material.** One drifting colour field per tab in its accent,
   with a faint grain (`LooprColorField`). Cards are solid fills with a lit
   top edge (`LooprSurface`, `.hero(accent)` for the lead card). Controls and
   the tab bar use iOS 26 glass (`LooprGlassButton`, `glassEffect`). Light
   mode is warm paper with the same objects.
5. **Touch.** Rulers and dials snap to detents with a `.selection` haptic. A
   kept rule plays a soft `.success`. Press and hold on an object tilts it up
   to 4° in 3D (`looprPressTilt`), as on the food sticker.
6. **Fast.** Entrance animations run once per tab per day (`LooprEntranceStore`);
   a second visit shows the final state at once. The colour field pauses when
   its screen is hidden, in Low Power Mode and under Reduce Motion. Each tab
   has one animated object and one colour field; everything else is still.
   Scrolling holds 120 Hz. `LaunchPerformanceTests` and
   `ScrollPerformanceUITests` stay within budget.
7. **Accessible.** Reduce Motion fades to the final state. Reduce Transparency
   swaps glass for solid fills. Increase Contrast uses the high-contrast
   tokens. Dynamic Type works up to AX5 without clipping. Each object has a
   VoiceOver summary of what it shows. Interactive rows are at least 56 pt.
   Every existing accessibility identifier is kept, and every new control
   gets one.
8. **Honest and plain.** Every number shows where it came from through
   `ProvenanceChip`. Missing data stays missing: `MetricState.absent`, never a
   0 and never a blank. Copy is sentence case, with no exclamation marks and
   no em dashes, and passes the `unslop` skill
   (`~/.claude/skills/unslop/SKILL.md`).

## Tabs and accents (DEC-12)

| Tab | Accent token | Signature object |
|---|---|---|
| Today | `brand` | Day dial |
| Food | `energy` | Rings and the eating-window rail |
| Fitness | `strain` | Dose field |
| Protocol | `protocol` (resolves to the `cyclePlum` values) | Week of rosettes and the check-in deck |
| Data | `brand` | Age ruler |

Domain accents inside a tab stay as before: `heart` for heart, stress and
cycle; `sleep` for sleep; `strain` for load and warnings; `critical` for
destructive actions.

## Tokens and type

Everything comes from `LooprColorToken`, `LooprTextStyle`, `LooprSpacing`,
`LooprRadius` and `LooprMotion`. Colours, fonts, sizes, corner radii and
spacing are read from those types, so a token change restyles every screen.

- Dark is warm black (`background` `#0B0A08`) with cards filled a few percent
  lighter, no outline and no shadow. Light is warm paper (`#F6F3EE`) with
  white `sheetFill` cards and a soft `ink.opacity(0.05)` shadow. Cards use the
  26 pt radius.
- Space Grotesk sets words and numbers; numeric styles set tabular figures.
  Hero numbers use the Light weight through `LooprHeroNumber`. Use
  `looprTypography(_:)` or `LooprText` for every text style.
- Labels are sentence case. `LooprText`, `StatusChip` and `LooprSectionHeader`
  turn an all-caps string into sentence case through `looprLabelCased`,
  keeping acronyms (HRV, GPS) and writing units as in prose (bpm, ms, kg).
- The one number a detail page is about is the hero in the domain accent,
  with a plain sentence under it saying what it means.

## Screen skeleton

A top-level tab screen:

```swift
ZStack {
    LooprColorField(accent: .protocol)      // pauses itself when hidden
    VStack(spacing: 0) {
        StickyHeader(title: "Protocol", meta: "Version 7 · day 21 · 14 rules")
            .zIndex(1)
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                // the signature object first, then supporting cards
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .accessibilityIdentifier("protocol-screen")
    }
}
.background(Color.loopr(.background).ignoresSafeArea())
.navigationTitle("")
```

A pushed detail screen keeps `navigationTitle(...)` and drops the
`StickyHeader`, as `BodyLoadScreen` does. A focus screen (the set log, a
capacity test timer) hides the tab bar with `.toolbar(.hidden, for: .tabBar)`
and pins its one action in a bottom `safeAreaInset`.

## Component vocabulary

Craft components (LV-01):

- `LooprColorField(accent:)`: the drifting colour field and grain, a
  `ShaderLibrary` effect with its pause rules built in.
- `LooprHeroNumber`: the Light hero numeral that counts up.
- `LooprDotFlight`: dots from a source rect along a target path, a colour
  per dot, a landing callback and capped haptics. `FoodMacroBurst` draws
  through it.
- `ProvenanceChip`: where a number came from (band, Apple Health and the
  source app, Food, a lab, typed in, estimated), with its age.
- `LooprCoachOrb`: the coach's mark on notes and the header Ask button.
- `looprPressTilt()`: the 3D tilt on press and hold, up to 4°.
- `LooprDetent`: snapping for rulers and dials with a selection haptic;
  `LooprRulerPicker` and `ScrubGesture` use it.
- `LooprEntranceStore` and `looprEntrance(tab:animates:)`: remembers which
  tab already played its entrance today, on an injected clock. Tab ids are
  `LooprColorFieldTab.rawValue` ("today", "food", "fitness", "protocol",
  "data"). `--loopr-entrance-final-state` forces final states for UI tests
  and captures.
- `LooprDotFlightCoordinator` (`looprDotFlightHost()`,
  `looprDotFlightSource(_:)`, `looprDotFlightTarget(_:)`, `fly(from:to:...)`):
  dots from a source in one view to a target in another on the same screen.
- `LooprCountUp` drives `LooprHeroNumber` from landing dots;
  `.heroNumeralUnit` sets the unit beside a hero number.
- `LooprDetentTracker`, `looprDetentFeedback(_:)` and
  `LooprHaptic.ruleKept`, `.detent`, `.majorDetent`: detents and the kept-rule
  success.
- The source files in `LooprPackages/Sources/DesignSystem/` are the API
  reference for every craft component; read them before using one.
- `LooprGlassButton` (round icon, pill, prominent pill) and
  `LooprGlassSegmentedControl`: glass controls through `looprGlass(in:)`,
  solid `surfaceElevated` under Reduce Transparency, a `surfaceEdge` outline
  under Increase Contrast. Callers pass every identifier.
- `surfaceEdge`: the token for a card's lit top edge (a white highlight in
  dark, a warm hairline on paper). `LooprSurface` applies it; screens never
  draw their own.

Existing components:

- `StickyHeader(title:meta:status:)`: screen title and a sentence-case meta
  line, for example `"Tue 14 Nov · Synced 2 min ago"`.
- `LooprSurface(emphasis:)`: the card. `.standard`, `.elevated`, or
  `.hero(token)` for the accent card lit from its top edge.
- `HairlineMetricList` of `HairlineMetricRow`: the grouped list of numbers.
- `MetricCard`, `StatusChip`, `StateMessage`, `LooprSkeleton`, `LooprRow`,
  `LooprButtonStyle(prominent:)` (the 56 pt buttons).
- Graphics: `SpectralLens`, `ScoreArc`, `TrendChart`, `LooprStageTimeline`,
  `ZoneChart`, `RouteGraphic`, `RecapChart`, `LooprProgressRing`,
  `LooprRingHero`.
- Train: `TrainRailChip` (the start rail and sheet), `LooprLoadPicker` with `LooprBarbellGraphic`
  (plates by identity, the bar never resizes), `LooprPlateColor`.

Sections open with `LooprSectionHeader`: a sentence-case `.title` with an
optional plain action word ("Edit", "All").

## Where shared code goes

A capability two screens could use lives in `DesignSystem` as a shared
component with a gallery entry (`ComponentGallery.swift`) and tests in
`DesignSystemTests`. Feature code imports it. When your package needs a
component that is missing, add it to `DesignSystem` inside the paths your
brief allows, with its gallery entry and tests, and name it in your report.

## Copy

Plain and specific. These are measurement screens, so describe what a number
is and where it came from. Coach text names its days and its comparison group
and says "differed", never "caused". Health and lab screens use general
wellness wording and carry the line "Loopr is not a medical device." where a
value could be read as a diagnosis. Lab values show the lab's own range and
never a Loopr judgement. The product never names Bryan Johnson, "Don't Die"
or "Blueprint".

## Keep stable

- Every `accessibilityIdentifier` keeps its exact string: UI tests and the
  screenshot harness depend on them. DEC-10 and DEC-11 list the Train and
  Food identifiers.
- Public API signatures other packages call change only inside the package
  that owns them, with every caller updated in the same change.
