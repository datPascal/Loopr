import SwiftUI

/// The Train components in the gallery. Open it directly with
/// `--loopr-open-design-system --loopr-design-system-section=train`.
struct LooprTrainGallerySection: View {
    @State private var days: Set<LooprWeekday> = [.tuesday, .saturday]
    @State private var kg = 80.0
    @State private var reps = 8.0
    @State private var describeTaps = 0

    private static let restEnd = Date(timeIntervalSince1970: 1_700_000_105)
    private static let restNow = Date(timeIntervalSince1970: 1_700_000_000)

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Week strip", detail: "Today outlined. Dot mode: a dot per session")
                LooprWeekStrip(days: LooprWeekStrip.sampleDays, identifier: "gallery-week-strip") { _ in }
                LooprWeekStrip(days: LooprWeekStrip.sampleDays, identifier: "gallery-week-strip-dots",
                               selection: "train-day-2023-11-14") { _ in }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Programs and templates", detail: "Progress, mono value and one chevron")
                LooprCard(density: .flush) {
                    VStack(spacing: LooprSpacing.none) {
                        LooprNavigationRow(title: "Strength block", caption: "8 weeks · 5 days a week", progress: 3.0 / 8.0,
                                           value: "3", valueUnit: "of 8", accessibilityLabel: "Strength block, week 3 of 8",
                                           identifier: "gallery-program-row") {}
                        LooprNavigationRow(title: "Upper A", caption: "Bench press, Pull-up and 4 more",
                                           accessibilityLabel: "Upper A, 6 exercises", identifier: "gallery-template-row",
                                           showsDivider: false) {}
                    }
                }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Ask field and weekday picker")
                LooprAskField("Describe it: \"push day, 50 min\"", accessibilityLabel: "Describe it",
                              identifier: "gallery-ask-field") { describeTaps += 1 }
                LooprWeekdayPicker(selection: $days, identifier: "gallery-weekdays")
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Exercise rows", detail: "A superset shows rest on its last member")
                LooprCard(density: .flush) {
                    VStack(spacing: LooprSpacing.none) {
                        LooprExerciseRow(name: "Bench press", spec: "4 × 6–8 · 80 KG", rest: "2:30",
                                         identifier: "gallery-exercise-0",
                                         accessibilityLabel: "Bench press, 4 sets of 6 to 8 reps at 80 kilograms, rest 2 minutes 30 seconds",
                                         onMoveDown: {}) {}
                        LooprExerciseRow(members: [
                            .init(id: "a", name: "Incline dumbbell press", spec: "3 × 10 · 28 KG", rest: "1:30",
                                  identifier: "gallery-exercise-1a",
                                  accessibilityLabel: "Incline dumbbell press, 3 sets of 10 reps at 28 kilograms"),
                            .init(id: "b", name: "Chest-supported row", spec: "3 × 10 · 30 KG", rest: "1:30",
                                  identifier: "gallery-exercise-1b",
                                  accessibilityLabel: "Chest-supported row, 3 sets of 10 reps at 30 kilograms, rest 1 minute 30 seconds")
                        ], identifier: "gallery-exercise-group", onSelect: { _ in }, onMoveUp: {}, onMoveDown: {})
                        LooprInlineActionRow("Add exercise", symbol: "plus", identifier: "gallery-add-exercise") {}
                    }
                }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Live session")
                HStack(spacing: LooprSpacing.cardStack) {
                    LooprValueStepper("kg", label: "Weight", spokenUnit: "kilograms", value: $kg, step: 2.5, range: 0...500,
                                      identifier: "gallery-kg", decrementIdentifier: "gallery-kg-minus",
                                      incrementIdentifier: "gallery-kg-plus")
                    LooprValueStepper("reps", label: "Reps", spokenUnit: "reps", value: $reps, step: 1, range: 0...100,
                                      identifier: "gallery-reps", decrementIdentifier: "gallery-reps-minus",
                                      incrementIdentifier: "gallery-reps-plus")
                }
                LooprSetLogTable(rows: [
                    .init(number: 1, weight: "80", reps: "8", rpe: "7", status: .logged),
                    .init(number: 2, weight: "–", reps: "–", status: .skipped),
                    .init(number: 3, weight: "80", reps: "8", status: .current)
                ], rowIdentifierPrefix: "gallery-set-row", rpeIdentifierPrefix: "gallery-set-rpe",
                   onSelectRPE: { _ in }, onEdit: { _ in })
                LooprRestTimerCard(endDate: Self.restEnd, now: Self.restNow, totalSeconds: 150,
                                   caption: "Rest · the band buzzes at zero",
                                   identifier: "gallery-rest-timer", addIdentifier: "gallery-rest-add",
                                   doneIdentifier: "gallery-rest-done", onAdd: {}, onDone: {})
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Week target bar", detail: "One pair per session done, outlines for the rest")
                LooprBarbellGraphic(plates: [20, 20], outlines: 1, tint: .strain)
                    .frame(height: 54)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("2 of 3 sessions")
                    .accessibilityIdentifier("gallery-week-target-bar")
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Program grid", detail: "Weeks 4 and 7 are lighter")
                LooprProgramGrid(weeks: LooprProgramGrid.sampleWeeks, identifier: "gallery-program-grid")
            }
        }
    }
}
