import DesignSystem
import FoodKit
import JournalKit
import SwiftUI

struct FoodAssociationScreen: View {
    let report: FoodAssociationReport
    let comparisonsEnabled: Bool
    /// Patterns' result for a last meal after 21:00, when it found one. It leads the card and the row.
    var latePattern: FoodLatePattern? = nil
    /// The fibre target Food's tile uses. One target on both screens (ICP R2-OPT-21: 35 g there, 30 g here).
    var fibreTarget: Double? = nil
    let open: (FoodAssociationKind) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                if comparisonsEnabled {
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprSectionHeader("Last meal and deep sleep", detail: "Each dot is one night, last 30 days")
                        if report.points.isEmpty {
                            StatusChip("Learning", accent: .energy)
                            LooprText("Complete your food logs and record sleep to compare meal times with deep sleep.", style: .body, color: .inkSecondary)
                        } else {
                            LooprScatterChart(points: report.points.map { .init(id: $0.id, x: $0.lastMealHour, y: $0.deepSleepMinutes) },
                                title: "Last meal and deep sleep", xTitle: "Last meal", yTitle: "Deep sleep minutes",
                                xDomain: min(18.5, report.points.map(\.lastMealHour).min() ?? 18.5)...max(22.5, report.points.map(\.lastMealHour).max() ?? 22.5),
                                yDomain: max(0, (report.points.map(\.deepSleepMinutes).min() ?? 40) - 10)...max(90, (report.points.map(\.deepSleepMinutes).max() ?? 80) + 10),
                                threshold: 21, accent: .sleep,
                                xFormat: { value in String(format: "%02d:%02d", Int((value * 60).rounded()) / 60, Int((value * 60).rounded()) % 60) },
                                yFormat: { "\(Int($0))m" })
                        }
                        if let latePattern {
                            StatusChip(latePattern.caption, accent: .sleep)
                            LooprText(latePattern.headline + ".", style: .body)
                            LooprText(FoodAssociationCopy.patternNote(pattern: latePattern, dots: report.points.count), style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("food-body-pattern-note")
                        } else {
                            LooprText(report.row(.lateMeal).detail.replacingOccurrences(of: "the day after Yes answers", with: "after days with a last meal after 21:00"), style: .body)
                        }
                    }
                }.accessibilityIdentifier("food-body-scatter")
                }
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    // The days behind every average, so 6 logged days never read as a month (ICP R2-OPT-20).
                    LooprSectionHeader("Averages", detail: report.recentDays.count == 1 ? "1 logged day in the last 30" : "\(report.recentDays.count) logged days in the last 30")
                        .accessibilityHint("Completed logs with known nutrients. Training days have a saved workout; rest days have none recorded. Eating window spans the first and last logged meals.")
                    LooprCard(density: .flush) {
                        VStack(spacing: 0) {
                            metric("Protein on training days", value: number(report.protein(training: true)), unit: "g", detail: proteinTarget)
                            Divider().padding(.horizontal, LooprSpacing.cardHorizontal)
                            metric("Protein on rest days", value: number(report.protein(training: false)), unit: "g")
                            Divider().padding(.horizontal, LooprSpacing.cardHorizontal)
                            metric("Fibre", value: number(report.fiber), unit: "g", detail: "Under \(Int(fibreLine)) g on \(report.fiberValues.filter { $0 < fibreLine }.count) of \(report.fiberValues.count) complete days")
                            Divider().padding(.horizontal, LooprSpacing.cardHorizontal)
                            metric("Eating window", value: report.eatingWindowMinutes.map { "\(Int($0) / 60) h \(Int($0) % 60) m" } ?? "Unavailable")
                            Divider().padding(.horizontal, LooprSpacing.cardHorizontal)
                            metric("Days logged", value: String(report.recentDays.count), unit: "of 30")
                        }
                    }
                }
                if comparisonsEnabled {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprSectionHeader("What moves with food")
                    LooprCard {
                        VStack(spacing: 0) {
                            ForEach(FoodAssociationKind.foodScreenKinds, id: \.rawValue) { kind in
                                let row = report.row(kind)
                                LooprAssociationRow(title: kind.title, detail: kind == .lateMeal ? latePattern?.caption ?? row.evidence : row.evidence, evidence: nil,
                                    share: row.difference.map { max(-1, min(1, $0 / (kind == .lateMeal ? 30 : 10))) },
                                    accent: .energy, identifier: "food-association-\(kind.rawValue)") { open(kind) }
                                if kind != FoodAssociationKind.foodScreenKinds.last { Divider() }
                            }
                        }
                    }
                }
                }
                if report.recentDays.contains(where: \.isEstimated) { StatusChip("Includes estimates", accent: .energy) }
            }.padding(LooprSpacing.screenGutter)
        }.background(Color.loopr(.background))
    }
    private var fibreLine: Double { fibreTarget.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30 }
    private var proteinTarget: String? { report.recentDays.last?.settings?.protein.map { "Target \(Int($0)) g" } }
    private func number(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "Unavailable" }
    private func metric(_ title: String, value: String, unit: String? = nil, detail: String? = nil) -> some View {
        HairlineMetricRow(title: title, confidence: detail, value: value, unit: value == "Unavailable" ? nil : unit, captionStyle: .caption)
            .padding(.horizontal, LooprSpacing.cardHorizontal)
    }
}

enum FoodAssociationCopy {
    /// Why the dots and the pattern can count different nights: the chart shows the last 30 days, Patterns reads every
    /// night Loopr holds. Same pattern, two windows, said out loud.
    static func patternNote(pattern: FoodLatePattern, dots: Int) -> String {
        let shown = dots == 1 ? "1 night" : "\(dots) nights"
        guard pattern.nights != dots else { return "From Patterns, over the same \(shown) the chart shows." }
        return "From Patterns, which reads \(pattern.nights) nights with a logged last meal and sleep. The chart shows the last 30 days, \(shown) of them."
    }
}
