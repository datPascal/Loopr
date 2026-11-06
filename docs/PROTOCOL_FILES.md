# Protocol files

A protocol file holds a protocol's rules, targets and experiment designs in one plain JSON document. You can share it, open someone else's, change it and run it. This page is the format. The code is `LooprPackages/Sources/RoutineKit/Files/`, and DEC-12.5 in `docs/PRODUCT_DECISIONS.md` is the decision behind it.

A file never holds health data, check history, experiment results or anything that identifies a person. `author` is text the person typed into their own protocol, and Loopr never fills it in.

## At a glance

| | |
|---|---|
| Format | `loopr-protocol` |
| Schema version | 1 |
| File extension | `.looprprotocol` (a plain `.json` file that validates also opens) |
| Type identifier | `com.loopr.protocol`, conforms to `public.json` |
| Media type | `application/vnd.loopr.protocol+json` |
| Encoding | UTF-8 JSON, one object at the top |
| Largest file | 256 KB (262,144 bytes) |
| Most rules | 50 |
| Most experiment designs | 10 |

Key order does not matter. Loopr writes keys in alphabetical order, so the same protocol always produces the same bytes.

## Example

```json
{
  "format": "loopr-protocol",
  "schemaVersion": 1,
  "name": "Sleep first, my way",
  "author": "Sam",
  "lineage": { "forkedFrom": "Sleep first", "version": 1, "url": "https://example.org/sleep-first" },
  "version": 3,
  "createdAt": "2026-10-25T08:30:00Z",
  "rules": [
    {
      "key": "in-bed",
      "title": "In bed by 22:30",
      "group": "sleep",
      "source": "band",
      "target": { "kind": "atMost", "metric": "in_bed_time", "value": 1350, "unit": "min" },
      "timeOfDay": "21:45",
      "evening": true
    },
    {
      "key": "zone-2",
      "title": "Zone 2, 150 minutes a week",
      "group": "fitness",
      "source": "band",
      "target": { "kind": "atLeast", "metric": "zone2_minutes", "value": 150, "unit": "min" },
      "cadence": { "unit": "week", "every": 1 },
      "why": "Steady exercise where you can still talk keeps your heart and lungs fit.",
      "evidence": "WHO guidelines from 2020 ask adults for 150 to 300 minutes of moderate activity a week."
    },
    {
      "key": "magnesium",
      "title": "Magnesium",
      "group": "supplements",
      "source": "manual",
      "target": { "kind": "done" },
      "timeOfDay": "21:00"
    }
  ],
  "experiments": [
    {
      "title": "Magnesium and deep sleep",
      "interventionRuleKey": "magnesium",
      "design": { "kind": "blocks", "length": 7 },
      "washout": 1,
      "minimumNightsPerArm": 7,
      "plannedNights": 28,
      "outcome": { "metric": "deepSleepMinutes", "title": "Deep sleep", "unit": "min", "betterWhen": "higher" }
    }
  ]
}
```

## Top-level fields

| Field | Type | Required | Allowed values and notes |
|---|---|---|---|
| `format` | string | yes | Exactly `loopr-protocol`. |
| `schemaVersion` | integer | yes | `1`. See "Future versions". |
| `name` | string | yes | 1 to 80 characters, no control characters. |
| `author` | string | no | Up to 80 characters. Free text. A blank value counts as absent. |
| `lineage` | object | no | Where this protocol was forked from. See below. |
| `version` | integer | yes | 1 or more. The protocol version number the file was exported from. |
| `createdAt` | string | yes | ISO 8601 date and time, for example `2026-10-25T08:30:00Z`. When that version was saved. Loopr writes whole seconds in UTC and reads fractional seconds. |
| `rules` | array | yes | Up to 50 rule objects, in the order the person sees them. May be empty. |
| `experiments` | array | no | Up to 10 experiment designs. |

### `lineage`

| Field | Type | Required | Notes |
|---|---|---|---|
| `forkedFrom` | string | yes | The name of the protocol this one came from. Up to 80 characters. |
| `version` | integer | no | 1 or more. The version it was forked at. |
| `url` | string | no | An `https` link to the original, up to 300 characters. |

When Loopr imports a file it makes a new protocol that is a fork of the file. The new protocol's lineage names the file's `name` and `version`. Loopr keeps one step of lineage, so the file's own `lineage` is read and shown but is not carried into the new protocol.

"Use this protocol" on the Rules segment works the same way for the person's own protocol: the file's rules become its next version, and the protocol takes the file's `name`, `author` and lineage. Check history and experiments stay with the protocol. With no protocol yet, the file becomes version 1.

## Rules

Each item in `rules` is an object.

| Field | Type | Required | Allowed values and notes |
|---|---|---|---|
| `key` | string | yes | 1 to 64 characters from `A-Z a-z 0-9 . _ -`. Unique in the file. The key is the rule's identity: history follows it when the title or target changes. |
| `title` | string | yes | 1 to 80 characters, no line breaks. Sentence case. |
| `group` | string | yes | `sleep`, `food`, `fitness`, `supplements`, `tests` or `custom`. |
| `source` | string | yes | What decides the rule: `band`, `food`, `fitness`, `appleHealth` or `manual`. |
| `target` | object | yes | See below. |
| `timeOfDay` | string | no | `HH:mm` on a 24-hour clock, for example `21:45`. When the person is reminded. It never decides a result. |
| `evening` | boolean | no | Default `false`. Marks an evening rule. |
| `rebuttal` | string | no | Up to 280 characters. Loopr never writes it and ignores it on import. See "Rebuttals stay on the phone". |
| `why` | string | no | Up to 280 characters. Why the rule is on the list, in one plain sentence. Shown under the rule, in full. Unlike `rebuttal`, it travels with the file. Keep it short and leave the rule's number out of it, so it stays true when someone changes the target. The templates keep theirs to 16 words. |
| `evidence` | string | no | Up to 500 characters, no control characters. Where the rule comes from: the study or guideline behind it, named in words, in a sentence or three. Shown as "Where this comes from" in the template preview and the rule editor. It travels with the file like `why`. An app from before this field lists it as ignored and drops it. |
| `cadence` | object | no | How often the rule is due. Absent means every day. See below. |

### Rebuttals stay on the phone

An evening rule can carry a rebuttal: a line the person writes in the morning that the rule's reminder quotes back at its time (DEC-12.18). It is personal text, so it never goes into a file. Loopr leaves `rebuttal` out of every file it writes, and drops a `rebuttal` it finds in a file it opens. When a file replaces the person's rules, an evening rule with the same `key` keeps the rebuttal the person wrote. The field stays in schema 1 so that files written before this rule still validate.

### `target`

| Field | Type | Required | Allowed values and notes |
|---|---|---|---|
| `kind` | string | yes | `done` (done or not, no amount), `atLeast`, `atMost` or `exactly`. |
| `metric` | string | yes unless `source` is `manual` | A name from the metric vocabulary below, and it must belong to the rule's `source`. A `manual` rule has no metric, or the name `done`. |
| `value` | number | yes unless `kind` is `done` | 0 to 1,000,000,000. Not a string. |
| `unit` | string | no | A label such as `g`, `min` or `drinks`. Up to 16 characters. |

A time-of-day metric holds minutes after local midnight of the rule's day. `1350` is 22:30. A night that starts after midnight counts past 1440, so 00:30 is 1470.

### `cadence`

| Field | Type | Required | Allowed values |
|---|---|---|---|
| `unit` | string | yes | `day`, `week` or `month`. |
| `every` | integer | no | 1 to 24. Default 1. Six months is `{ "unit": "month", "every": 6 }`. |
| `days` | array of strings | no | Only with `unit` `day` and `every` 1. The weekdays the rule is due on: `mon`, `tue`, `wed`, `thu`, `fri`, `sat`, `sun`, each once. Monday, Wednesday and Friday is `{ "unit": "day", "days": ["mon", "wed", "fri"] }`. All seven days mean every day. |
| `times` | integer | no | Only with `unit` `week` and `every` 1. How many times a week, 1 to 7: three times a week is `{ "unit": "week", "times": 3 }`. 1 is the same as each week and 7 the same as every day. |

A rule with `days` is due on those days only. On the other days Loopr makes no check for it, so an off day is neither kept nor missed. On its days it is checked like a daily rule.

A rule with `times` counts the days it was kept in the week (Monday to Sunday) against `times`.

Loopr scores a rule checked by a source over its whole period. Until the weekly dose and the tests screens do that, the day view shows a weekly or monthly source rule as unknown, never as missed. The Rules list shows how far the week has come ("112 of 150 min this week", "Done 2 of 3 times this week") and when a longer rule is due next. A manual rule can be ticked on any day.

`days` and `times` came after schema 1 was first published, inside schema 1. An app from before them opens the file, lists the field as ignored, and reads the rule as every day (with `days`) or each week (with `times`).

### Metric vocabulary

| Source | Metric | What it measures | Unit |
|---|---|---|---|
| `food` | `protein_g` | Protein logged on the day | g |
| `food` | `fibre_g` | Fibre logged on the day | g |
| `food` | `energy_kcal` | Energy logged on the day | kcal |
| `food` | `last_meal_time` | Time of the last meal | minutes after midnight |
| `food` | `alcohol_drinks` | Alcohol units logged | drinks |
| `food` | `last_caffeine_time` | Time of the last item with caffeine | minutes after midnight |
| `food` | `supplements_all_taken` | 1 when every supplement dose due that day was ticked taken on the Food tab's stack, 0 when any was skipped | tick |
| `food` | `medication_all_taken` | The same for the medication list, which is kept apart from supplements | tick |
| `food` | `supplement_adherence` | Taken supplement doses over due doses, once every due dose has a tick | 0 to 1 |
| `food` | `supplement_taken:<key>` | 1 when every due dose of one supplement was taken, 0 when any was skipped | tick |
| `food` | `medication_taken:<key>` | The same for one medicine | tick |
| `band` | `sleep_onset_time` | When sleep started | minutes after midnight |
| `band` | `in_bed_time` | Start of the main sleep period | minutes after midnight |
| `band` | `zone2_minutes` | Minutes in heart-rate zone 2 | min |
| `band` | `zone45_minutes` | Minutes in zones 4 and 5 together | min |
| `band` | `sleep_hr` | Sleeping heart rate | bpm |
| `fitness` | `strength_sessions` | Completed strength sessions | sessions |
| `fitness` | `mobility_sessions` | Completed yoga sessions | sessions |
| `fitness` | `workout_minutes` | Minutes of completed workouts | min |
| `appleHealth` | `steps` | Steps | steps |
| `appleHealth` | `daylight_minutes` | Time in daylight | min |
| `appleHealth` | `vo2max` | VO2 max | mL/kg/min |
| `appleHealth` | `weight_kg` | Weight | kg |
| `manual` | `done` | A tick | none |

A name that is not in this table is refused, and so is a name listed under a different source than the rule's.

`<key>` is the item's key in the stack: 1 to 48 characters of `a` to `z`, `0` to `9` and `-`, such as `supplement_taken:vitamin-d3`. Loopr makes it from the name when the item is first saved and keeps it after a rename. A dose with no tick gives no reading, so a stack rule stays unknown on that day and never counts as missed.

## Experiment designs

An experiment design says how to test one rule. It is a plan, not a started experiment. The file holds no nights, dates, adherence or results.

| Field | Type | Required | Allowed values and notes |
|---|---|---|---|
| `title` | string | yes | 1 to 80 characters. |
| `interventionRuleKey` | string | yes | The `key` of a rule in the same file. |
| `design` | object | yes | `kind` is `alternating`, `blocks` or `beforeAfter`. `blocks` and `beforeAfter` need an integer `length` of 1 or more (the block length, or the baseline nights). `alternating` has no `length`. |
| `washout` | integer | yes | 0 or more. Nights skipped after each switch. It must be shorter than a block. |
| `minimumNightsPerArm` | integer | yes | 2 or more. Included nights each side needs. |
| `plannedNights` | integer | yes | 2 or more. The plan has to give each side at least `minimumNightsPerArm` nights. |
| `outcome` | object | yes | `metric` (a key such as `deepSleepMinutes`, same characters as a rule key), `title`, `unit` (may be empty) and `betterWhen` (`higher` or `lower`). The outcome is fixed before night 1. |

Importing a file does not start an experiment. The experiment screen starts one after the person reads the design.

## What Loopr checks

Loopr checks a file before it saves anything. A refused file changes nothing. The checks, in order:

1. The file is no larger than 256 KB.
2. It is valid JSON with an object at the top.
3. `format` is `loopr-protocol`.
4. `schemaVersion` is 1 (see "Future versions").
5. Every required field is present, and every field has the type and range above.
6. Every metric is in the vocabulary and belongs to its rule's source.
7. No two rules share a key.
8. There are at most 50 rules and 10 experiment designs.
9. Every experiment names a rule in the file and describes a plan that can run.

| Refusal | Message the person sees |
|---|---|
| Too large | This file is larger than 256 KB, so Loopr will not open it. |
| Not JSON, or wrong `format` | This file is not a Loopr protocol. |
| Newer `schemaVersion` | This file needs a newer version of Loopr. |
| `schemaVersion` of 0 or below | This file uses a format version Loopr does not know. |
| Missing field | The file is missing "rules[2].title". |
| Bad value | The value for "rules[1].target.value" is not one Loopr can use. |
| Unknown metric | The rule "protein" checks "kale_g", which Loopr does not know. |
| Metric under the wrong source | The rule "protein" names "steps" under a source that cannot measure it. |
| Duplicate key | Two rules share the key "in-bed". |
| Too many rules | This protocol has more than 50 rules, which is more than Loopr opens. |
| Too many experiments | This protocol has more than 10 experiments, which is more than Loopr opens. |
| Experiment names no rule | Experiment 1 tests "nothing", and no rule has that key. |
| Experiment cannot run | Experiment 1 cannot run, followed by the reason. |

## Future versions

`schemaVersion` changes only when a change would make an old reader misread a file, such as a renamed field or a new meaning for a value. A Loopr that reads schema version 1 refuses any higher number with "This file needs a newer version of Loopr", and it does not try to read the rest.

A change that older readers can safely skip is a minor revision and keeps `schemaVersion` at 1. It adds optional fields. A reader ignores every field it does not know, at any level, drops it on import, and lists it for the person as ignored (for example `rules[2].mood`). A new required field, a new allowed value for an existing field or a new metric name is not a minor revision. It needs a new schema version.

## What a file never holds

A file never holds check history, measured values, days, experiment nights or results, device names, identifiers, accounts, notes or any health reading. Export builds the file from the protocol's rules and the designs of its experiments, and a test checks that an export from a protocol with history contains none of that.

## Import

Importing makes a new protocol with version 1 from the file's rules. It never replaces the protocol the person is using. Making the new protocol the active one is a separate choice the person confirms.

## Bundled templates

Five protocols ship with Loopr as files in this format, in `LooprPackages/Sources/RoutineKit/Templates/`, with the same files in the repo's `protocols/` folder. They go through the same checks as any file. Every target is a default the person can change. Every rule has a short `why` and an `evidence` sentence drawn from the sources below.

| Template | Rules |
|---|---|
| A gentle start | In bed by 22:30, walk 6,000 steps, one drink at most. The one the start screen marks "Start here". |
| Sleep first | In bed by 22:30, screens off an hour before bed, kitchen closes at 19:00, no caffeine after 14:00, 30 minutes in daylight, track your sleeping heart rate |
| Fitness for the long run | Zone 2 for 150 minutes a week, two strength sessions a week, 30 hard minutes a week, two mobility sessions a week, a monthly grip strength retest, a monthly one-leg balance retest |
| Everything at once | A balanced set across sleep, food, fitness, supplements and tests, with a blood test every 6 months |
| Start empty | No rules |

### Where the defaults come from

| Default | Evidence |
|---|---|
| Zone 2, 150 minutes a week | WHO guidelines on physical activity and sedentary behaviour recommend 150 to 300 minutes of moderate activity a week (Bull et al., Br J Sports Med 2020;54:1451-1462). The low end is the default. |
| Two strength sessions a week | The same WHO guidelines: muscle-strengthening activity on 2 or more days a week. |
| 30 hard minutes a week | WHO counts 75 to 150 minutes of vigorous activity as equal to the moderate range. 30 minutes is a start below that. |
| Two mobility sessions a week | ACSM position stand: flexibility exercise on 2 or more days a week (Garber et al., Med Sci Sports Exerc 2011;43:1334-1359). |
| No caffeine after 14:00 | 400 mg of caffeine 6 hours before bed cut sleep by more than an hour (Drake et al., J Clin Sleep Med 2013;9:1195-1200). 14:00 is 8.5 hours before 22:30. |
| In bed by 22:30 | No study fixes a bedtime. 22:30 leaves 7 to 9 hours for a 06:30 to 07:30 wake time, the adult range in the AASM and Sleep Research Society consensus (Watson et al., Sleep 2015;38:843-844). |
| Grip strength retest | Grip strength predicts death from all causes (Leong et al., Lancet 2015;386:266-273). |
| One-leg balance retest | Failing a 10-second one-leg stand predicts higher mortality in people 51 to 75 (Araujo et al., Br J Sports Med 2022;56:975-980). |
| Protein, 80 grams | About 1.0 to 1.2 g per kg for a person near 70 kg, the range proposed for older adults (Bauer et al., J Am Med Dir Assoc 2013;14:542-559). The RDA is 0.8 g per kg. Body weight varies, so edit it. |
| Fibre, 25 grams | The EFSA adequate intake for adults (EFSA Journal 2010;8:1462). |
| One drink at most | Alcohol before bed fragments sleep in the second half of the night (Ebrahim et al., Alcohol Clin Exp Res 2013;37:539-549). The US Dietary Guidelines for 2020 to 2025 cap drinking at 1 a day for women and 2 for men. WHO says no level of alcohol is without risk (2023). |
| 7,000 steps, walk 6,000 steps | Mortality risk fell until about 6,000 to 8,000 steps a day at 60 and over, and 8,000 to 10,000 below that (Paluch et al., Lancet Public Health 2022;7:e219-e228). A gentle start uses the low end for 60 and over. |
| Kitchen closes at 19:00, 30 minutes in daylight, screens off, supplements, blood test every 6 months | No published target. These are modest habits, and the blood test interval is a common one. Ask your clinician what suits you. |

## Experiment result files

A result file is the summary of one finished or stopped experiment, for sharing from the result screen. It is a separate format from a protocol file, with its own schema version. The code is `LooprPackages/Sources/RoutineKit/Experiments/ExperimentResultFile.swift`, and DEC-12.13 is the decision behind the experiments.

The file holds the design, the outcome fixed on day 1, the call and its label, the effect, the likely range, your night-to-night spread, the night counts and the first and last day. It holds no night's value and no other measure, so "Also moved" stays on the phone. It also holds no identifier, no time zone and no other health data. A running experiment has no result file.

| | |
|---|---|
| Format | `loopr-experiment-result` |
| Schema version | 1 |
| File name | `Loopr experiment result.json` |
| Type identifier | `public.json` |
| Encoding | UTF-8 JSON, one object at the top |
| Largest file | 64 KB (65,536 bytes) |

Loopr writes keys in alphabetical order and rounds every number to two decimals, so the same result always gives the same bytes.

### Example

```json
{
  "format": "loopr-experiment-result",
  "schemaVersion": 1,
  "title": "No caffeine after 12:00",
  "intervention": "caffeine-free afternoon",
  "ruleKey": "caffeine-cutoff",
  "design": { "kind": "alternating" },
  "washout": 0,
  "minimumNightsPerArm": 8,
  "plannedNights": 28,
  "outcome": { "metric": "deepSleepMinutes", "title": "Deep sleep", "unit": "min", "betterWhen": "higher" },
  "status": "finished",
  "startDay": "2026-09-11",
  "endDay": "2026-10-08",
  "nights": { "completed": 28, "onCounted": 14, "offCounted": 14, "leftOut": 0 },
  "result": {
    "call": "result",
    "label": "clear",
    "effect": 14,
    "range": { "low": 11.43, "high": 16.57 },
    "spread": 5,
    "rangeOutsideSpread": true,
    "favors": "better"
  },
  "policyVersion": "experiment.v1"
}
```

### Fields

| Field | Type | Required | Allowed values and notes |
|---|---|---|---|
| `format` | string | yes | Exactly `loopr-experiment-result`. |
| `schemaVersion` | integer | yes | `1`. A higher number is refused with "This file needs a newer version of Loopr", 0 or below with "This file uses a format version Loopr does not know". |
| `title` | string | yes | 1 to 80 characters, no control characters. The experiment's title. |
| `intervention` | string | yes | 1 to 80 characters. How a night reads in a sentence, such as `magnesium`. |
| `ruleKey` | string | yes | 1 to 64 characters. The protocol rule the experiment tested. |
| `design` | object | yes | `kind` is `alternating`, `blocks` or `beforeAfter`, with `length` as in "Experiment designs" above. |
| `washout` | integer | yes | 0 or more, shorter than a block. |
| `minimumNightsPerArm` | integer | yes | 2 or more. |
| `plannedNights` | integer | yes | 2 or more. Design, washout, minimum and planned nights must make a plan that can run. |
| `outcome` | object | yes | `metric`, `title`, `unit` (up to 16 characters, may be empty) and `betterWhen` (`higher` or `lower`). |
| `status` | string | yes | `finished` or `stopped`. |
| `startDay` | string | yes | Night 1, as `YYYY-MM-DD`. |
| `endDay` | string | yes | The last night that counts, as `YYYY-MM-DD`. On or after `startDay`, and inside the planned nights. |
| `nights` | object | yes | `completed`, `onCounted`, `offCounted` and `leftOut`, each an integer of 0 or more. Counted and left-out nights add up to `completed`, which is at most `plannedNights`. |
| `result` | object | yes | See below. |
| `policyVersion` | string | yes | 1 to 40 characters. The version of the rules that made the call, such as `experiment.v1`. |

### `result`

| Field | Type | Required | Notes |
|---|---|---|---|
| `call` | string | yes | `result` (there is a label), `notCalled` (enough nights, but the range is wider than the spread), `notEnoughNights` (a side ended below the minimum) or `cannotReport` (too few nights before day 1 to learn the spread). |
| `label` | string | with `result` only | `strong`, `clear`, `early` or `noChange`. |
| `effect` | number | with `result` | The average of the counted on nights minus the average of the counted off nights, in the outcome's unit. |
| `range` | object | with `result` and `notCalled` | `low` and `high`, the likely range of the effect, with `low` at most `high`. Absent for the other calls. |
| `spread` | number | with `result` and `notCalled` | 0 or more. Your night-to-night spread of the outcome before day 1. Absent with `cannotReport`. |
| `rangeOutsideSpread` | boolean | yes | True when the whole likely range sits beyond the spread on one side. |
| `favors` | string | no | `better` or `worse`: whether the effect points the way `betterWhen` says. Absent when the effect is 0 or unknown. |

### What Loopr checks

Reading a result file has no side effects. Loopr checks it, then shows it or refuses it, and saves nothing. The checks, in order:

1. The file is no larger than 64 KB.
2. It is JSON with an object at the top, and `format` is `loopr-experiment-result`.
3. `schemaVersion` is 1.
4. Every required field is present, with the type above.
5. Every value is in its range, the plan can run, the dates and night counts agree, and the result fields match the call.

| Refusal | Message the person sees |
|---|---|
| Too large | This file is larger than 64 KB, so Loopr will not open it. |
| Not JSON, or wrong `format` | This file is not a Loopr experiment result. |
| Newer `schemaVersion` | This file needs a newer version of Loopr. |
| `schemaVersion` of 0 or below | This file uses a format version Loopr does not know. |
| Missing field | The file is missing "result.range". |
| Bad value | The value for "nights" is not one Loopr can use. |

A reader ignores fields it does not know. A new required field or a new allowed value needs a new schema version.
