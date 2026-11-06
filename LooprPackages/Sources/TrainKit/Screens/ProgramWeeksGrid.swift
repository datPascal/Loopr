import DesignSystem
import SwiftUI

/// A program at a glance with names in the cells instead of codes (R2-NEW-13): a weekday header, one row per week,
/// each day tinted by its session type, today outlined, and a legend of the types the plan uses (R2-VET-12).
///
/// VoiceOver reads each week as one element ("Week 3. Monday, Lower A, strength. Tuesday, Upper A, strength, today.")
/// and does not walk the cells. Cell text stops growing at the extra large size so a week still fits one row; the
/// week summaries carry the full text at every size.
struct ProgramWeeksGrid: View {
    let model: ProgramScreenModel
    let identifier: String

    private var cellShape: RoundedRectangle { RoundedRectangle(cornerRadius: LooprSpacing.xs, style: .continuous) }
    private static let labelWidth: CGFloat = LooprSpacing.xl + LooprSpacing.xxs

    var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                weekdayHeader
                ForEach(model.grid) { weekRow($0) }
                legend.padding(.top, LooprSpacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// "Week 3. Monday, Lower A, strength. Tuesday, Upper A, strength, today."
    static func spokenSummary(_ week: ProgramScreenModel.Week) -> String {
        var sentences = ["Week \(week.number)"]
        for (weekday, day) in zip(TrainWeekday.allCases, week.days) {
            guard let day else { continue }
            var parts = [weekday.ruleName, day.spokenName, day.type.title.lowercased()]
            if day.intensity != .normal { parts.append(day.intensity.rawValue) }
            if day.isCurrent { parts.append("today") }
            sentences.append(parts.joined(separator: ", "))
        }
        if sentences.count == 1 { sentences.append("Nothing planned") }
        return sentences.joined(separator: ". ")
    }

    /// The wash behind a cell: the dose colours, so an easy day reads like Zone 2 and a hard day like hard minutes.
    static func fill(_ day: ProgramScreenModel.Day) -> (token: LooprColorToken, opacity: Double) {
        switch day.type {
        case .strength:
            switch day.intensity {
            case .heavy: (.ink, 0.22)
            case .light: (.sleep, 0.18)
            case .normal: (.ink, 0.08)
            }
        case .easy: (.strain, 0.16)
        case .long: (.strain, 0.32)
        case .hard: (.heart, 0.24)
        case .mobility: (.protocol, 0.18)
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: LooprSpacing.xxs) {
            Color.clear.frame(width: Self.labelWidth, height: LooprSpacing.hairline)
            ForEach(LooprWeekday.allCases, id: \.self) { day in
                Text(day.initial)
                    .looprTypography(.headerMeta)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func weekRow(_ week: ProgramScreenModel.Week) -> some View {
        HStack(spacing: LooprSpacing.xxs) {
            Text(week.label)
                .looprTypography(.headerMeta)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .frame(width: Self.labelWidth, alignment: .leading)
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                cell(day)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenSummary(week))
        .accessibilityIdentifier("\(identifier)-\(week.label.lowercased())")
    }

    private func cell(_ day: ProgramScreenModel.Day?) -> some View {
        Text(day?.name ?? "")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.loopr(.ink))
            .multilineTextAlignment(.center)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, LooprSpacing.xxs / 2)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.hero)
            .background {
                if let day {
                    let fill = Self.fill(day)
                    cellShape.fill(Color.loopr(fill.token).opacity(fill.opacity))
                }
            }
            .overlay {
                if day?.isCurrent == true {
                    cellShape.strokeBorder(Color.loopr(.fitnessTab), lineWidth: LooprSpacing.xxs / 2)
                }
            }
    }

    /// The legend entries: each type the plan uses, then Heavy and Light when a strength day is either.
    private var legendItems: [(title: String, token: LooprColorToken, opacity: Double)] {
        var items = model.types.map { type -> (String, LooprColorToken, Double) in
            let fill = Self.fill(ProgramScreenModel.Day(name: "", spokenName: "", type: type, intensity: .normal, isCurrent: false))
            return (type.title, fill.token, fill.opacity)
        }
        if model.hasHeavy { items.append(("Heavy", .ink, 0.22)) }
        if model.hasLight { items.append(("Light", .sleep, 0.18)) }
        return items
    }

    private var legend: some View {
        let items = legendItems
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading,
                         spacing: LooprSpacing.xs) {
            ForEach(items, id: \.title) { item in
                HStack(spacing: LooprSpacing.xs) {
                    RoundedRectangle(cornerRadius: LooprRadius.calendarCell, style: .continuous)
                        .fill(Color.loopr(item.token).opacity(item.opacity))
                        .frame(width: LooprSpacing.lg, height: LooprSpacing.sm)
                    Text(item.title.looprLabelCased)
                        .looprTypography(.headerMeta)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: " + items.map(\.title).joined(separator: ", "))
        .accessibilityIdentifier("\(identifier)-legend")
    }
}
