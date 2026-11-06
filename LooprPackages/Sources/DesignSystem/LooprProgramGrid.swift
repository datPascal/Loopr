import SwiftUI

/// What kind of session sits in a program cell.
public enum LooprProgramCellKind: CaseIterable, Sendable, Equatable {
    /// A regular strength slot.
    case normal
    /// A heavy slot: more load or a test set.
    case heavy
    /// A lighter slot, as in a deload week.
    case light
    /// Zone 2, a run or a ride.
    case cardio
    /// A day with nothing planned.
    case empty

    /// The token behind the cell fill. Nil for an empty day.
    public var fillToken: LooprColorToken? {
        switch self {
        case .normal: .ink
        case .heavy: .strain
        case .light: .sleep
        case .cardio: .movement
        case .empty: nil
        }
    }

    /// How strongly the fill token shows. Every kind is a wash over the card, so the label stays readable.
    /// `normal` is a faint ink wash: lighter than the card in dark mode, as in mock 13, and grey in light mode.
    public var fillOpacity: Double {
        switch self {
        case .normal: 0.08
        case .heavy, .light, .cardio: 0.18
        case .empty: 0
        }
    }

    /// The token for the two-letter label.
    public var labelToken: LooprColorToken {
        switch self {
        case .normal, .empty: .ink
        case .heavy: LooprColorToken.strain.textInk
        case .light: LooprColorToken.sleep.textInk
        case .cardio: LooprColorToken.movement.textInk
        }
    }

    /// The legend word, and the word VoiceOver adds to a cell.
    public var title: String {
        switch self {
        case .normal: "Normal"
        case .heavy: "Heavy"
        case .light: "Light"
        case .cardio: "Cardio"
        case .empty: "Rest"
        }
    }
}

/// One day in a program week.
public struct LooprProgramCell: Equatable, Sendable {
    /// Two or three letters: "LA", "Z2", "MAX". Empty for a rest day.
    public let code: String
    public let kind: LooprProgramCellKind
    /// What VoiceOver says instead of the code: "Lower A".
    public let spokenName: String?
    /// The cell for today. It gets an accent outline.
    public let isCurrent: Bool

    public init(code: String, kind: LooprProgramCellKind = .normal, spokenName: String? = nil, isCurrent: Bool = false) {
        self.code = code
        self.kind = kind
        self.spokenName = spokenName
        self.isCurrent = isCurrent
    }

    /// A day with nothing planned.
    public static let empty = LooprProgramCell(code: "", kind: .empty)
}

/// One row of the grid: a week label and seven cells, Monday first.
public struct LooprProgramWeek: Identifiable, Equatable, Sendable {
    /// "W1".
    public let label: String
    /// Seven cells Monday to Sunday. Shorter lists are padded with empty days
    /// and longer ones are cut at seven.
    public let cells: [LooprProgramCell]
    /// A spoken summary. When nil the grid writes one from the cells.
    public let summary: String?

    public var id: String { label }

    public init(label: String, cells: [LooprProgramCell], summary: String? = nil) {
        self.label = label
        self.cells = Array((cells + Array(repeating: .empty, count: max(0, 7 - cells.count))).prefix(7))
        self.summary = summary
    }
}

/// A program at a glance: a weekday header, one row per week (W1 to Wn),
/// two-letter cells coloured by kind, today outlined, and a legend.
///
/// ```swift
/// LooprProgramGrid(weeks: weeks, accent: .movement, identifier: "program-grid")
/// ```
///
/// The grid is a picture of the plan. VoiceOver reads each week as one
/// element ("Week 3. Monday, Lower A. Tuesday, Upper A, current. ...") and
/// does not walk the 56 cells. Cell labels stay at or below the extra large
/// text size so a week still fits one row, and the week summaries carry the
/// full text at every size.
public struct LooprProgramGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    private let weeks: [LooprProgramWeek]
    private let accent: LooprColorToken
    private let identifier: String

    public init(weeks: [LooprProgramWeek], accent: LooprColorToken = .movement, identifier: String) {
        self.weeks = weeks
        self.accent = accent
        self.identifier = identifier
    }

    /// The kinds the legend lists, in order.
    public static let legendKinds: [LooprProgramCellKind] = [.normal, .heavy, .light, .cardio]

    /// A spoken summary of one week. A week's own `summary` wins.
    public static func accessibilitySummary(for week: LooprProgramWeek) -> String {
        if let summary = week.summary { return summary }
        let number = week.label.drop { !$0.isNumber }
        var sentences = ["Week \(number.isEmpty ? Substring(week.label) : number)"]
        for (index, cell) in week.cells.enumerated() where cell.kind != .empty {
            let day = LooprWeekday.allCases[index].fullName
            var parts = [day, cell.spokenName ?? cell.code]
            if cell.kind != .normal { parts.append(cell.kind.title.lowercased()) }
            if cell.isCurrent { parts.append("today") }
            sentences.append(parts.joined(separator: ", "))
        }
        if sentences.count == 1 { sentences.append("Nothing planned") }
        return sentences.joined(separator: ". ")
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
    private var cellShape: RoundedRectangle { RoundedRectangle(cornerRadius: LooprSpacing.xs, style: .continuous) }
    private static let labelWidth: CGFloat = LooprSpacing.xl + LooprSpacing.xxs

    public var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                weekdayHeader
                ForEach(weeks) { weekRow($0) }
                legend.padding(.top, LooprSpacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
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

    private func weekRow(_ week: LooprProgramWeek) -> some View {
        HStack(spacing: LooprSpacing.xxs) {
            Text(week.label)
                .looprTypography(.headerMeta)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .frame(width: Self.labelWidth, alignment: .leading)
            ForEach(Array(week.cells.enumerated()), id: \.offset) { _, cell in
                cellView(cell)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilitySummary(for: week))
        .accessibilityIdentifier("\(identifier)-\(week.label.lowercased())")
    }

    private func cellView(_ cell: LooprProgramCell) -> some View {
        Text(cell.code)
            .looprTypography(.metricUnit)
            .foregroundStyle(Color.loopr(cell.kind.labelToken))
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.hero)
            .background {
                if let token = cell.kind.fillToken {
                    cellShape.fill(Color.loopr(token).opacity(cell.kind.fillOpacity))
                }
            }
            .overlay {
                if cell.isCurrent {
                    cellShape.strokeBorder(Color.loopr(accent), lineWidth: LooprSpacing.xxs / 2)
                }
            }
    }

    private var legend: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    ForEach(Self.legendKinds, id: \.self) { legendItem($0) }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LooprSpacing.md) { ForEach(Self.legendKinds, id: \.self) { legendItem($0) } }
                    Grid(alignment: .leading, horizontalSpacing: LooprSpacing.md, verticalSpacing: LooprSpacing.xs) {
                        GridRow { legendItem(.normal); legendItem(.heavy) }
                        GridRow { legendItem(.light); legendItem(.cardio) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: " + Self.legendKinds.map(\.title).joined(separator: ", "))
    }

    private func legendItem(_ kind: LooprProgramCellKind) -> some View {
        HStack(spacing: LooprSpacing.xs) {
            RoundedRectangle(cornerRadius: LooprRadius.calendarCell, style: .continuous)
                .fill(Color.loopr(kind.fillToken ?? .surfaceSunk).opacity(kind.fillOpacity))
                .frame(width: LooprSpacing.lg, height: LooprSpacing.sm)
            Text(kind.title.looprLabelCased)
                .looprTypography(.headerMeta)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize()
        }
    }
}

extension LooprProgramGrid {
    /// Eight weeks as in the Strength block fixture, for previews, the gallery and tests.
    static var sampleWeeks: [LooprProgramWeek] {
        func week(_ number: Int, heavy: Set<Int> = [], light: Bool = false, current: Int? = nil) -> LooprProgramWeek {
            let plan: [(String, String)?] = [("LA", "Lower A"), ("UA", "Upper A"), ("Z2", "Zone 2"), ("LB", "Lower B"), nil, ("UB", "Upper B"),
                                              (number == 3 || number == 5 || number == 6 ? ("LR", "Long run") : nil)]
            let cells = plan.enumerated().map { index, item -> LooprProgramCell in
                guard let item else { return .empty }
                let kind: LooprProgramCellKind = item.0 == "Z2" || item.0 == "LR" ? .cardio
                    : light ? .light : heavy.contains(index) ? .heavy : .normal
                return LooprProgramCell(code: item.0, kind: kind, spokenName: item.1, isCurrent: current == index)
            }
            return LooprProgramWeek(label: "W\(number)", cells: cells)
        }
        return [
            week(1), week(2), week(3, heavy: [3, 5], current: 1), week(4, light: true),
            week(5, heavy: [0, 1, 3, 5]), week(6, heavy: [0, 1, 3, 5]), week(7, light: true),
            LooprProgramWeek(label: "W8", cells: [
                LooprProgramCell(code: "MAX", kind: .heavy, spokenName: "Max test"), LooprProgramCell(code: "UA", spokenName: "Upper A"),
                LooprProgramCell(code: "Z2", kind: .cardio, spokenName: "Zone 2"),
                LooprProgramCell(code: "MAX", kind: .heavy, spokenName: "Max test")
            ])
        ]
    }
}

#Preview("Program grid") {
    LooprProgramGrid(weeks: LooprProgramGrid.sampleWeeks, identifier: "preview-grid")
        .padding(LooprSpacing.screenGutter)
        .background(Color.loopr(.background))
}
