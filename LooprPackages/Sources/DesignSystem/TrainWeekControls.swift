import SwiftUI

/// A day of the week in ISO 8601 order: Monday is 1 and Sunday is 7.
///
/// Train stores a template's days as a set of these. `calendarWeekday` maps to
/// and from `Calendar` numbering, where Sunday is 1.
public enum LooprWeekday: Int, CaseIterable, Sendable, Hashable, Comparable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

    public static func < (lhs: LooprWeekday, rhs: LooprWeekday) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The day for a `Calendar` weekday number, where Sunday is 1 and Saturday is 7.
    public init?(calendarWeekday: Int) {
        switch calendarWeekday {
        case 1: self = .sunday
        case 2...7: self.init(rawValue: calendarWeekday - 1)
        default: return nil
        }
    }

    /// The `Calendar` weekday number, where Sunday is 1 and Saturday is 7.
    public var calendarWeekday: Int { self == .sunday ? 1 : rawValue + 1 }

    /// One letter, as the picker shows it.
    public var initial: String {
        switch self {
        case .monday: "M"
        case .tuesday, .thursday: "T"
        case .wednesday: "W"
        case .friday: "F"
        case .saturday, .sunday: "S"
        }
    }

    /// Three letters, for the picker at accessibility sizes.
    public var shortName: String {
        switch self {
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        case .sunday: "Sun"
        }
    }

    /// The spoken name.
    public var fullName: String {
        switch self {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }

    /// A lowercase three-letter code for accessibility identifiers.
    public var code: String { shortName.lowercased() }
}

// MARK: - Week strip

/// One session on a day of a `LooprWeekStrip` in dot mode: done draws a filled dot, planned a hollow one.
public enum LooprWeekStripMark: Equatable, Sendable {
    case done
    case planned
}

/// One day in a `LooprWeekStrip`.
public struct LooprWeekStripDay: Identifiable, Equatable, Sendable {
    /// Supplied by the caller, for example `train-day-2023-11-14`. Also the
    /// cell's accessibility identifier.
    public let identifier: String
    /// The weekday letter, such as "T". Set uppercase in mono.
    public let weekdayLetter: String
    /// The date numeral, such as "14".
    public let dateNumeral: String
    /// A short caption under the numeral: "Done", "Upper A", "Rest".
    public let caption: String
    public let isDone: Bool
    public let isToday: Bool
    /// What VoiceOver reads, for example "Tuesday 14 November, Upper A, today".
    public let accessibilityLabel: String
    /// A dot per session in dot mode, done first. Empty for a rest day.
    public let marks: [LooprWeekStripMark]

    public var id: String { identifier }

    public init(identifier: String, weekdayLetter: String, dateNumeral: String, caption: String,
                isDone: Bool = false, isToday: Bool = false, accessibilityLabel: String,
                marks: [LooprWeekStripMark] = []) {
        self.identifier = identifier
        self.weekdayLetter = weekdayLetter
        self.dateNumeral = dateNumeral
        self.caption = caption
        self.isDone = isDone
        self.isToday = isToday
        self.accessibilityLabel = accessibilityLabel
        self.marks = marks
    }
}

/// Seven day cells in a row: weekday letter, date numeral and a short caption.
/// Today is outlined in the accent, and a done day colours its caption.
///
/// In dot mode (`selection` is set) a cell shows a dot per session instead of
/// a caption: filled for done, hollow for planned. Today keeps its ring, the
/// selected day gets a tint, and the caller writes the selected day's caption
/// under the strip, where it has the full width and never clips.
///
/// At accessibility text sizes the seven columns would not fit, so the strip
/// becomes a list of seven 56 pt rows, each with its caption.
///
/// ```swift
/// LooprWeekStrip(days: days, accent: .movement, identifier: "train-week-strip", selection: selected) { day in
///     selected = day.identifier
/// }
/// ```
public struct LooprWeekStrip: View {
    public static let minimumCellHeight: CGFloat = LooprSpacing.interactiveRowHeight
    /// Dots a column draws before it adds a plus.
    public static let maximumDots = 3
    static let dotDiameter: CGFloat = 7

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    private let days: [LooprWeekStripDay]
    private let accent: LooprColorToken
    private let identifier: String
    private let selection: String?
    private let onSelect: (LooprWeekStripDay) -> Void

    /// - Parameter selection: the identifier of the selected day. Setting it switches the strip to dot mode.
    public init(days: [LooprWeekStripDay], accent: LooprColorToken = .movement, identifier: String,
                selection: String? = nil, onSelect: @escaping (LooprWeekStripDay) -> Void) {
        self.days = days
        self.accent = accent
        self.identifier = identifier
        self.selection = selection
        self.onSelect = onSelect
    }

    private var showsDots: Bool { selection != nil }

    /// The marks a column draws: at most `maximumDots`, and whether a plus follows for the rest.
    public static func shownMarks(_ marks: [LooprWeekStripMark]) -> (marks: [LooprWeekStripMark], more: Bool) {
        (Array(marks.prefix(maximumDots)), marks.count > maximumDots)
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: LooprSpacing.xxs) { ForEach(days) { listCell($0) } }
            } else {
                HStack(alignment: .top, spacing: LooprSpacing.xxs) { ForEach(days) { columnCell($0) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
    }

    private func captionColor(_ day: LooprWeekStripDay) -> LooprColorToken {
        day.isDone ? accent.textInk : .inkSecondary
    }

    private func columnCell(_ day: LooprWeekStripDay) -> some View {
        cellButton(day) {
            VStack(spacing: LooprSpacing.xxs) {
                Text(day.weekdayLetter.looprLabelCased)
                    .looprTypography(.headerMeta)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                Text(day.dateNumeral)
                    .looprTypography(.title)
                    .foregroundStyle(Color.loopr(.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if showsDots {
                    dots(day.marks)
                } else {
                    Text(day.caption)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(captionColor(day)))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, LooprSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: Self.minimumCellHeight, alignment: .top)
        }
    }

    private func listCell(_ day: LooprWeekStripDay) -> some View {
        cellButton(day) {
            HStack(spacing: LooprSpacing.md) {
                VStack(spacing: LooprSpacing.xxs) {
                    Text(day.weekdayLetter.looprLabelCased)
                        .looprTypography(.headerMeta)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                    Text(day.dateNumeral)
                        .looprTypography(.title)
                        .foregroundStyle(Color.loopr(.ink))
                }
                .frame(minWidth: LooprSpacing.hero)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Text(day.caption)
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(captionColor(day)))
                        .fixedSize(horizontal: false, vertical: true)
                    if showsDots, !day.marks.isEmpty { dots(day.marks) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, LooprSpacing.sm)
            .padding(.horizontal, LooprSpacing.md)
            .frame(maxWidth: .infinity, minHeight: Self.minimumCellHeight, alignment: .leading)
        }
    }

    /// A dot per session, filled for done and hollow for planned. The row keeps its height on a rest day.
    private func dots(_ marks: [LooprWeekStripMark]) -> some View {
        let shown = Self.shownMarks(marks)
        return HStack(spacing: 3) {
            ForEach(Array(shown.marks.enumerated()), id: \.offset) { _, mark in
                Group {
                    switch mark {
                    case .done: Circle().fill(Color.loopr(accent))
                    case .planned: Circle().strokeBorder(Color.loopr(.inkSecondary), lineWidth: 1.2)
                    }
                }
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            }
            if shown.more {
                Image(systemName: "plus")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
        }
        .frame(height: Self.dotDiameter + 2)
        .accessibilityHidden(true)
    }

    private func isSelected(_ day: LooprWeekStripDay) -> Bool {
        showsDots ? day.identifier == selection : day.isToday
    }

    private func cellButton<Label: View>(_ day: LooprWeekStripDay, @ViewBuilder label: () -> Label) -> some View {
        let isDark = LooprAppearance.isDark(colorScheme)
        // Caption mode tints and rings today. Dot mode tints the selected day and rings today, so both read at once.
        let tinted = isSelected(day)
        return Button { onSelect(day) } label: {
            label()
                .background(tinted ? Color.loopr(accent).opacity(isDark ? 0.13 : 0.10) : Color.clear, in: shape)
                .overlay {
                    if day.isToday {
                        shape.strokeBorder(Color.loopr(accent), lineWidth: showsDots ? 1.5 : LooprSpacing.hairline)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.accessibilityLabel)
        .accessibilityAddTraits(isSelected(day) ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(day.identifier)
    }
}

// MARK: - Weekday picker

/// Multi-select Monday to Sunday capsules in one track. Each capsule is 56 pt
/// tall; the seven share the row width, so on a phone each is about 50 pt wide.
///
/// ```swift
/// LooprWeekdayPicker("Days", selection: $days, accent: .movement, identifier: "template-days")
/// ```
///
/// Capsule identifiers are `<identifier>-mon` to `<identifier>-sun`.
public struct LooprWeekdayPicker: View {
    public static let minimumTargetHeight: CGFloat = LooprSpacing.interactiveRowHeight

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding private var selection: Set<LooprWeekday>
    private let title: String
    private let accent: LooprColorToken
    private let identifier: String

    public init(_ title: String = "Days", selection: Binding<Set<LooprWeekday>>,
                accent: LooprColorToken = .movement, identifier: String) {
        self.title = title
        _selection = selection
        self.accent = accent
        self.identifier = identifier
    }

    /// The selection after tapping `day`: added when absent, removed when present.
    public static func toggling(_ day: LooprWeekday, in selection: Set<LooprWeekday>) -> Set<LooprWeekday> {
        var next = selection
        if next.contains(day) { next.remove(day) } else { next.insert(day) }
        return next
    }

    /// What VoiceOver says for the whole control.
    public static func accessibilitySummary(title: String, selection: Set<LooprWeekday>) -> String {
        let names = LooprWeekday.allCases.filter(selection.contains).map(\.fullName)
        return names.isEmpty ? "\(title), none selected" : "\(title), \(names.joined(separator: ", "))"
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: LooprSpacing.xs) { buttons }
            } else {
                HStack(spacing: LooprSpacing.xxs) { buttons }
                    .padding(LooprSpacing.xxs)
                    .background(Color.loopr(.surfaceElevated), in: Capsule())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilitySummary(title: title, selection: selection))
        .accessibilityIdentifier(identifier)
    }

    private var buttons: some View {
        ForEach(LooprWeekday.allCases, id: \.self) { day in
            let selected = selection.contains(day)
            Button {
                selection = Self.toggling(day, in: selection)
            } label: {
                Text(dynamicTypeSize.isAccessibilitySize ? day.shortName : day.initial)
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(selected ? accent.spectralChipLabel : .inkSecondary))
                    .frame(maxWidth: .infinity, minHeight: Self.minimumTargetHeight)
                    .background(selected ? Color.loopr(accent).opacity(0.16) : Color.clear, in: Capsule())
                    .overlay {
                        if selected {
                            Capsule()
                                .strokeBorder(Color.loopr(accent), lineWidth: LooprSpacing.hairline)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(day.fullName)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("\(identifier)-\(day.code)")
        }
    }
}

private struct TrainWeekControlsPreview: View {
    @State private var days: Set<LooprWeekday> = [.tuesday, .saturday]
    var body: some View {
        VStack(spacing: LooprSpacing.lg) {
            LooprWeekStrip(days: LooprWeekStrip.sampleDays, identifier: "preview-week") { _ in }
            LooprWeekStrip(days: LooprWeekStrip.sampleDays, identifier: "preview-week-dots",
                           selection: "train-day-2023-11-14") { _ in }
            LooprWeekdayPicker(selection: $days, identifier: "preview-days")
        }
        .padding(LooprSpacing.screenGutter)
        .background(Color.loopr(.background))
    }
}

#Preview("Week strip and weekday picker") { TrainWeekControlsPreview() }

extension LooprWeekStrip {
    /// Fixture days for previews, the gallery and tests.
    static var sampleDays: [LooprWeekStripDay] {
        let rows: [(String, String, String, Bool, Bool, String, [LooprWeekStripMark])] = [
            ("M", "13", "Done", true, false, "Monday 13 November, done", [.done, .done]),
            ("T", "14", "Upper A", false, true, "Tuesday 14 November, Upper A, today", [.planned, .planned]),
            ("W", "15", "Zone 2", false, false, "Wednesday 15 November, Zone 2", [.planned]),
            ("T", "16", "Lower B", false, false, "Thursday 16 November, Lower B", [.planned]),
            ("F", "17", "Rest", false, false, "Friday 17 November, rest", []),
            ("S", "18", "Upper B", false, false, "Saturday 18 November, Upper B", [.planned]),
            ("S", "19", "Long run", false, false, "Sunday 19 November, long run", [.planned])
        ]
        return rows.map { row in
            LooprWeekStripDay(identifier: "train-day-2023-11-\(row.1)", weekdayLetter: row.0, dateNumeral: row.1,
                              caption: row.2, isDone: row.3, isToday: row.4, accessibilityLabel: row.5, marks: row.6)
        }
    }
}
