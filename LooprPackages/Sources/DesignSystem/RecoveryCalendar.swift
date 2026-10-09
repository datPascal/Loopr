import SwiftUI

/// A year of recovery at a glance: one row per month, one square per day,
/// each square in its recovery band colour (`LooprRecoveryBand`). Days
/// without a score are faint outlines; days after the last day shown are not
/// drawn. Tap a square to read the day.
///
/// Only for recovery: the band colours mean nothing for other metrics.
///
/// ```swift
/// let model = LooprRecoveryCalendarModel(points: recoveryHistory, endingOn: today)
/// if model.isWorthShowing {
///     LooprRecoveryCalendar(model: model)
/// }
/// ```
public struct LooprRecoveryCalendarModel: Sendable {
    public struct Day: Hashable, Sendable, Identifiable {
        public let date: Date
        public let dayOfMonth: Int
        public let score: Double?

        public var id: Date { date }
        public var band: LooprRecoveryBand? { LooprRecoveryBand(score: score) }
    }

    public struct Month: Hashable, Sendable, Identifiable {
        public let start: Date
        /// "SEP". At most 12 rows, so a month name never repeats.
        public let title: String
        /// Every day from the 1st to the month's last day shown, in order.
        public let days: [Day]

        public var id: Date { start }
    }

    /// Fewer scored days than this and the calendar is mostly empty squares.
    public static let minimumScoredDays = 7
    /// Squares per row: the longest month.
    public static let columns = 31

    public let months: [Month]
    public let counts: [LooprRecoveryBand: Int]
    public let scoredDays: Int
    public let latestScored: Day?
    private let calendar: Calendar

    public var isWorthShowing: Bool { scoredDays >= Self.minimumScoredDays }

    /// - Parameters:
    ///   - points: Recovery scores, one per day (0 to 100).
    ///   - endingOn: The last day shown.
    ///   - maximumMonths: Rows at most. The first row is the month of the
    ///     first score inside that window, so a short history draws only the
    ///     months it covers.
    public init(points: [LooprChartPoint], endingOn: Date, maximumMonths: Int = 12, calendar: Calendar = .current) {
        self.calendar = calendar
        let last = calendar.startOfDay(for: endingOn)
        var byDay: [Date: Double] = [:]
        for point in points where point.value.isFinite {
            let day = calendar.startOfDay(for: point.date)
            if day <= last { byDay[day] = point.value }
        }
        let lastMonth = calendar.dateInterval(of: .month, for: last)?.start ?? last
        let earliestAllowed = calendar.date(byAdding: .month, value: -(max(1, maximumMonths) - 1), to: lastMonth) ?? lastMonth
        let firstScored = byDay.keys.filter { $0 >= earliestAllowed }.min()
        let firstMonth = firstScored.flatMap { calendar.dateInterval(of: .month, for: $0)?.start } ?? lastMonth

        var months: [Month] = []
        var counts: [LooprRecoveryBand: Int] = [:]
        var scored = 0
        var latest: Day?
        var cursor = firstMonth
        while cursor <= lastMonth {
            var days: [Day] = []
            let length = calendar.range(of: .day, in: .month, for: cursor)?.count ?? 30
            for offset in 0..<length {
                guard let date = calendar.date(byAdding: .day, value: offset, to: cursor), date <= last else { break }
                let day = Day(date: date, dayOfMonth: offset + 1, score: byDay[date])
                if let band = day.band {
                    counts[band, default: 0] += 1
                    scored += 1
                    latest = day
                }
                days.append(day)
            }
            let title = LooprChartDateText.string(cursor, "MMM", calendar: calendar).uppercased()
            months.append(Month(start: cursor, title: title, days: days))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        self.months = months
        self.counts = counts
        self.scoredDays = scored
        self.latestScored = latest
    }

    /// The day in `month` under a horizontal position, or nil past its end.
    public static func dayIndex(x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0, x >= 0, x <= width else { return nil }
        return min(Int(x / (width / CGFloat(columns))), columns - 1)
    }

    /// Every shown day in order.
    public var allDays: [Day] { months.flatMap(\.days) }

    public func day(on date: Date) -> Day? {
        let key = calendar.startOfDay(for: date)
        return allDays.first { $0.date == key }
    }

    /// "TUE 22 SEP · 74% · READY", or "TUE 22 SEP · NO SCORE".
    public func readout(for day: Day) -> String {
        let date = LooprChartDateText.day(day.date, calendar: calendar)
        guard let score = day.score, let band = day.band else { return "\(date) · NO SCORE" }
        return "\(date) · \(Int(score.rounded()))% · \(band.verdict.uppercased())"
    }

    public func spokenReadout(for day: Day) -> String {
        let date = LooprChartDateText.string(day.date, "EEEE d MMMM", calendar: calendar)
        guard let score = day.score, let band = day.band else { return "\(date), no score" }
        return "\(date), \(Int(score.rounded())) percent, \(band.spokenDescription)"
    }

    /// "60 days scored: 21 ready, 30 steady, 9 recover".
    public var spokenSummary: String {
        let parts = LooprRecoveryBand.allCases.map { "\(counts[$0, default: 0]) \($0.verdict.lowercased())" }
        return "\(scoredDays) days scored: " + parts.joined(separator: ", ")
    }
}

public struct LooprRecoveryCalendar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selected: Date?

    private let model: LooprRecoveryCalendarModel
    private let identifier: String

    private let rowHeight: CGFloat = 12
    /// Room above and below each row's squares for the selection ring;
    /// together they make the 4 pt gap between rows.
    private let ringRoom: CGFloat = 2
    private let rowGap: CGFloat = 0
    private let cellGap: CGFloat = 2

    public init(model: LooprRecoveryCalendarModel, identifier: String = "loopr-recovery-calendar") {
        self.model = model
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            grid
            readout
            legend
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Grid

    private var grid: some View {
        VStack(alignment: .leading, spacing: rowGap) {
            ForEach(model.months) { month in
                HStack(spacing: LooprSpacing.xs) {
                    Text(month.title)
                        .looprTypography(.confidence)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: labelWidth, alignment: .leading)
                    row(month)
                        .frame(height: rowHeight + ringRoom * 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery calendar")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            let scored = model.allDays.filter { $0.score != nil }
            guard !scored.isEmpty else { return }
            let current = scored.firstIndex { $0.date == shownDay?.date } ?? scored.count - 1
            let next = direction == .increment ? min(current + 1, scored.count - 1) : max(current - 1, 0)
            selected = scored[next].date
        }
        .accessibilityIdentifier("\(identifier)-grid")
    }

    private var labelWidth: CGFloat {
        dynamicTypeSize >= .xLarge ? 42 : 32
    }

    private func row(_ month: LooprRecoveryCalendarModel.Month) -> some View {
        let isDark = LooprAppearance.isDark(colorScheme)
        let selectedDate = shownDay?.date
        let colours: [LooprRecoveryBand: Color] = Dictionary(uniqueKeysWithValues: LooprRecoveryBand.allCases.map { ($0, Color.loopr($0.token)) })
        let empty = Color.loopr(.ink).opacity(isDark ? 0.08 : 0.07)
        let ring = Color.loopr(.ink)
        return GeometryReader { proxy in
            Canvas { context, size in
                let slot = size.width / CGFloat(LooprRecoveryCalendarModel.columns)
                let width = max(slot - cellGap, 1)
                for (index, day) in month.days.enumerated() {
                    let rect = CGRect(x: CGFloat(index) * slot, y: ringRoom, width: width, height: size.height - ringRoom * 2)
                    let path = Path(roundedRect: rect, cornerRadius: min(2.5, width / 3), style: .continuous)
                    if let band = day.band, let colour = colours[band] {
                        context.fill(path, with: .color(colour))
                    } else {
                        context.fill(path, with: .color(empty))
                    }
                    if day.date == selectedDate {
                        // The gap between squares is 2 pt, so the ring stays
                        // inside it and never covers a neighbour.
                        let outline = Path(roundedRect: rect.insetBy(dx: -0.75, dy: -ringRoom + 0.6), cornerRadius: 3, style: .continuous)
                        context.stroke(outline, with: .color(ring), lineWidth: 1.25)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard let index = LooprRecoveryCalendarModel.dayIndex(x: location.x, width: proxy.size.width),
                      index < month.days.count else { return }
                selected = month.days[index].date
            }
        }
    }

    // MARK: Readout and legend

    private var shownDay: LooprRecoveryCalendarModel.Day? {
        if let selected, let day = model.day(on: selected) { return day }
        return model.latestScored
    }

    @ViewBuilder
    private var readout: some View {
        if let day = shownDay {
            HStack(spacing: LooprSpacing.xs) {
                Circle()
                    .fill(day.band.map { Color.loopr($0.token) } ?? Color.loopr(.ink).opacity(0.12))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(model.readout(for: day))
                    .looprTypography(.confidence)
                    .foregroundStyle(Color.loopr(.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .sensoryFeedback(.selection, trigger: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.spokenReadout(for: day))
            .accessibilityIdentifier("\(identifier)-readout")
        }
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LooprSpacing.md) { legendItems }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) { legendItems }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.spokenSummary)
    }

    @ViewBuilder
    private var legendItems: some View {
        ForEach(LooprRecoveryBand.allCases, id: \.self) { band in
            HStack(spacing: LooprSpacing.xs - 2) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.loopr(band.token))
                    .frame(width: 10, height: 10)
                Text("\(band.verdict) · \(model.counts[band, default: 0])")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize()
            }
        }
    }

    private var accessibilityValue: String {
        var parts = [model.spokenSummary]
        if let day = shownDay { parts.append(model.spokenReadout(for: day)) }
        return parts.joined(separator: ". ")
    }
}

#Preview("Recovery calendar") {
    let calendar = Calendar.current
    let end = calendar.startOfDay(for: Date())
    let points = (0..<200).compactMap { offset -> LooprChartPoint? in
        guard offset % 9 != 4, let date = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
        return LooprChartPoint(date: date, value: Double((offset * 37) % 100))
    }
    return LooprSurface {
        LooprRecoveryCalendar(model: LooprRecoveryCalendarModel(points: points, endingOn: end))
    }
    .padding()
    .background(Color.loopr(.background))
}
