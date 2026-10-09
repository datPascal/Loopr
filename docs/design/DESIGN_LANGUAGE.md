# Loopr design language (ratified 2026-08-29)

The five tab screens plus Settings were redesigned and signed off. As they
render in the app, light and dark, they are the ground truth.

Every other screen in the product now adopts the same language. This file is
the contract. Read it, then read the reference implementations before writing
any code.

## Reference implementations, in order of usefulness

| Pattern you need | Read this |
|---|---|
| A tab-level screen: header, lens, list, cards | `LooprPackages/Sources/BodyKit/BodyScreens.swift` |
| A dense metric screen with sections and charts | `LooprPackages/Sources/HeartKit/HeartScreens.swift` |
| A form / list / preferences screen, sheets, destructive actions | `LooprPackages/Sources/SettingsKit/SettingsScreens.swift` |
| A screen built from a hero graphic | `LooprPackages/Sources/SleepKit/SleepScreens.swift` |
| The shared vocabulary itself | `LooprPackages/Sources/DesignSystem/{Components,Graphics,Typography,DesignTokens}.swift` |

## The five rules

1. **Nothing is hardcoded.** No literal colors, fonts, sizes, corner radii or
   spacing numbers. Everything comes from `LooprColorToken`, `LooprTextStyle`,
   `LooprSpacing`, `LooprRadius`, `LooprMotion`. `Color.red`,
   `.foregroundStyle(.red)`, `.font(.headline)`, `padding(12)` and
   `cornerRadius(8)` are all defects.
2. **Light and dark are two designs, not one design with a switch.** Dark is
   near-black (`background` `#0A0D11`) with 14pt radii, a 1pt
   `surfaceStroke` hairline and no shadow. Light is warm grey (`#F3F4F6`) with
   20pt radii, white `sheetFill` cards, no border and a soft
   `ink.opacity(0.06)` shadow. The shared components already encode this. Do
   not re-derive it; use the components.
3. **Every screen states its data honestly.** `MetricState` has fourteen cases
   and each has a title, a detail line and an SF Symbol. A missing number is
   `.absent` ("Not measured"), never a `0` and never a blank. Render states
   with `StateMessage` or `StatusChip`, never with ad-hoc `Text("Error: ...")`
   or `.foregroundStyle(.red)`.
4. **Type carries the hierarchy, not weight or boxes.** Space Grotesk for
   words, IBM Plex Mono for numbers, labels and metadata. Section eyebrows and
   chips are uppercase mono with wide tracking. Metric values are mono. Prose
   is Space Grotesk at 13. Use `looprTypography(_:)` or `LooprText`, never
   `.font(...)`.
5. **Accessibility is part of the design.** Keep every existing
   `accessibilityIdentifier` exactly as it is: UI tests and the screenshot
   harness depend on them. Interactive rows are at least 56pt tall. Composite
   elements get `.accessibilityElement(children: .ignore)` plus a spoken
   `accessibilityLabel`. Decoration gets `.accessibilityHidden(true)`. Honour
   `LooprMotion` and the reduce-motion flag.

## Screen skeleton

A top-level screen:

```swift
VStack(spacing: 0) {
    StickyHeader(
        title: "Cycle",
        meta: "18 AUG · FOLLICULAR",
        status: StatusChip(state.title, symbol: state.symbol, accent: .cycle)
    )
    .zIndex(1)

    ScrollView {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            // hero first, then lists, then cards
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.bottom, LooprSpacing.tabBarClearance)
    }
    .accessibilityIdentifier("cycle-screen")
}
.background(Color.loopr(.background).ignoresSafeArea())
.navigationTitle("")
```

A pushed detail screen keeps `navigationTitle("Training Load")` and drops the
`StickyHeader`, exactly as `BodyLoadScreen` does.

## Component vocabulary

- `StickyHeader(title:meta:status:)` — screen title, uppercase mono meta line,
  optional status chip. `meta` is uppercase, e.g. `"TUE 14 NOV · SYNCED 2 MIN AGO"`.
- `LooprSurface(emphasis:)` — the card. `.standard`, `.elevated`, or
  `.hero(token)` for the accent-tinted card with the accent hairline.
- `HairlineMetricList(rows:)` of `HairlineMetricRow` — the grouped list:
  title, optional uppercase confidence line, mono value, unit, `›`. This is the
  default way to show a set of numbers. It is not a `List` and not a `Form`.
- `MetricCard(title:value:unit:trend:confidence:state:accent:)` — one number
  with its state.
- `StatusChip(_:symbol:tone:accent:)` — the uppercase mono capsule.
- `StateMessage(_:compact:)` — the honest empty/error/loading block.
- `LooprSkeleton(height:)` — the loading shimmer.
- `LooprRow(title:subtitle:symbol:)` — the icon + title + chevron navigation row.
- `LooprButtonStyle(prominent:)` — the 56pt primary and secondary buttons.
- `SpectralLens`, `ScoreArc`, `TrendChart`, `Hypnogram`, `ZoneChart`,
  `RouteGraphic`, `RecapChart` — the graphics. Reuse; do not draw new ones.

Section eyebrows are uppercase `.sectionLabel` in `.inkSecondary`, as in
`YOUR DAY` and `EXPLORE` on Today.

## Accent per domain

`brand` teal for recovery, movement and neutral. `heart` crimson for heart,
stress and cycle. `sleep` violet. `strain` amber for load, energy and warnings.
`critical` for destructive actions. Pick the accent that matches the screen's
domain and use it consistently for its lens, chip and hero tint.

## Copy

Sentence case for titles and prose. Uppercase only for eyebrows, chips,
confidence lines and header meta. Plain, specific, no filler, no exclamation
marks. No em dashes anywhere. Do not invent marketing language: these are
measurement screens.

## What you must not do

- Do not touch `LooprPackages/Sources/DesignSystem/`. If a component is
  missing, say so in your report; do not fork one into your file.
- Do not change any view model, repository, domain type, or business logic.
  This is a presentation change.
- Do not rename or remove an `accessibilityIdentifier`.
- Do not change public API signatures other packages call.
- Do not edit a file outside the one you were assigned.
