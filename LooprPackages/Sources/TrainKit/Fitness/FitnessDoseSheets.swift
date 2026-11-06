import DesignSystem
import SwiftUI

/// Behind the dose verdict's info button (R2-DES-07, R2-NEW-04, R2-VET-08): what "on pace" means, the even pace for
/// today, and what each row counts. The row definitions moved here from under every row (R2-DES-08).
struct FitnessDoseBasisSheet: View {
    @Environment(\.dismiss) private var dismiss
    let dose: FitnessDose

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    LooprText(FitnessDoseBasis.explanation, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-basis-explanation")
                    if let pace = dose.basis.paceLine {
                        LooprText(pace, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("fitness-basis-pace")
                    }
                    LooprSectionHeader("What counts", identifier: "fitness-basis-counts")
                    LooprCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            ForEach(Array(dose.basis.definitions.enumerated()), id: \.offset) { _, line in
                                LooprText(line, style: .caption, color: .inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LooprText(dose.zoneLine, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.vertical, LooprSpacing.md)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle(FitnessDoseBasis.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("fitness-basis-done")
                }
            }
        }
        .tint(Color.loopr(.fitnessTab))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("fitness-basis-sheet")
    }
}

/// Behind a tap on Zone 2 or Hard minutes (R2-VET-03, R2-WOD-08): the week day by day, newest first, with the
/// minutes, where they came from and what each session that day added. A day nothing measured says so instead of 0.
struct FitnessDoseDaysSheet: View {
    @Environment(\.dismiss) private var dismiss
    let days: [FitnessDoseDayRow]
    let zoneLine: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                    LooprText(zoneLine, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if days.isEmpty {
                        LooprText("Nothing this week yet.", style: .prose, color: .inkSecondary)
                    }
                    ForEach(days) { day in dayCard(day) }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.vertical, LooprSpacing.md)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Minutes by day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("fitness-days-done")
                }
            }
        }
        .tint(Color.loopr(.fitnessTab))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("fitness-days-sheet")
    }

    private func dayCard(_ day: FitnessDoseDayRow) -> some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    LooprText(day.title, style: .rowTitle)
                    Spacer(minLength: LooprSpacing.sm)
                    LooprText(day.minutesLine, style: .caption, color: day.zone2Minutes == nil ? .inkMuted : .inkSecondary)
                        .multilineTextAlignment(.trailing)
                }
                if let source = day.source {
                    LooprText(source, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(day.sessions.enumerated()), id: \.offset) { _, session in
                    VStack(alignment: .leading, spacing: 2) {
                        LooprText(session.title, style: .body)
                        LooprText(session.added, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, LooprSpacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.spokenLabel)
        .accessibilityIdentifier("fitness-day-\(day.id)")
    }
}
