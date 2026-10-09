import Foundation
import DesignSystem

/// Clock times on a noon-to-noon scale: 0 is 12:00, 660 is 23:00, 780 is
/// 01:00 and 1,140 is 07:00. A night then never wraps round midnight, so
/// medians and ranges of bedtimes work with plain numbers.
public enum SleepClock {
    public static let minutesPerDay: Double = 1_440

    /// Minutes after noon for `date` in `timeZone`.
    public static func minutesAfterNoon(_ date: Date, timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let clock = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        return (clock - 720 + minutesPerDay).truncatingRemainder(dividingBy: minutesPerDay)
    }

    /// "23:05" or "11:05 PM", following the locale, for a noon-based minute.
    public static func text(minutesAfterNoon minutes: Double, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let whole = Int(minutes.rounded())
        let clock = ((whole + 720) % 1_440 + 1_440) % 1_440
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let reference = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: clock / 60, minute: clock % 60)) ?? Date()
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        style.locale = locale
        return reference.formatted(style)
    }
}

/// Bedtime and wake time over the last 14 nights.
public struct SleepConsistency: Equatable, Sendable {
    public static let nights = 14
    /// Below this, the ranges are the earliest and latest nights; from here
    /// on they are the middle half (25th to 75th percentile).
    public static let rangeNights = 5
    /// A bedtime this far from the usual one is worth a line.
    public static let shiftWorthMentioning: Double = 30

    public struct Night: Equatable, Sendable, Identifiable {
        public let day: SleepCivilDay
        public let date: Date
        /// Minutes after noon the main sleep began and ended, nil with no main sleep.
        public let bed: Double?
        public let wake: Double?
        public var id: Int { day.ordinal }
    }

    public let nights: [Night]
    public let timeZone: TimeZone

    public init(nights: [Night], timeZone: TimeZone = .current) {
        self.nights = nights
        self.timeZone = timeZone
    }

    /// The 14 nights ending on the selected day, oldest first.
    public init(history: SleepNightHistory, calendar: Calendar = .current) {
        timeZone = calendar.timeZone
        guard let last = history.day else {
            nights = []
            return
        }
        var byDay: [SleepCivilDay: SleepNightRecord] = [:]
        for record in history.prior { byDay[record.day] = record }
        if let current = history.current { byDay[current.day] = current }
        let zone = calendar.timeZone
        nights = (0..<Self.nights).reversed().compactMap { offset -> Night? in
            guard let day = last.adding(days: -offset), let date = day.noon(in: calendar) else { return nil }
            let record = byDay[day]
            let hasSleep = record?.asleepMinutes != nil
            return Night(day: day, date: date,
                         bed: hasSleep ? record?.start.map { SleepClock.minutesAfterNoon($0, timeZone: zone) } : nil,
                         wake: hasSleep ? record?.end.map { SleepClock.minutesAfterNoon($0, timeZone: zone) } : nil)
        }
    }

    /// Nights with both a bedtime and a wake time.
    public var measured: [Night] { nights.filter { $0.bed != nil && $0.wake != nil } }

    public var bedRange: ClosedRange<Double>? { Self.range(measured.compactMap(\.bed)) }
    public var wakeRange: ClosedRange<Double>? { Self.range(measured.compactMap(\.wake)) }
    public var usesMiddleHalf: Bool { measured.count >= Self.rangeNights }

    /// The middle half from five nights on, the full spread before that, nil
    /// under two nights.
    static func range(_ values: [Double]) -> ClosedRange<Double>? {
        guard values.count >= 2 else { return nil }
        if values.count >= rangeNights,
           let low = SleepUsualRange.percentile(values, 25), let high = SleepUsualRange.percentile(values, 75) {
            return low...high
        }
        guard let low = values.min(), let high = values.max() else { return nil }
        return low...high
    }

    /// Median bedtime of the nights before the last one, for the shift line.
    public var usualBed: Double? {
        let earlier = measured.dropLast().compactMap(\.bed)
        guard earlier.count >= Self.rangeNights - 1 else { return nil }
        return SleepUsualRange.percentile(earlier, 50)
    }

    /// Median wake time over the measured nights.
    public var usualWake: Double? {
        let wakes = measured.compactMap(\.wake)
        guard !wakes.isEmpty else { return nil }
        return SleepUsualRange.percentile(wakes, 50)
    }

    /// Last night's bedtime minus the usual one, when the last night is measured.
    public var lastBedShift: Double? {
        guard let last = nights.last, let bed = last.bed, let usual = usualBed else { return nil }
        return bed - usual
    }

    /// The summary: "Most nights you went to bed between 22:50 and 23:30 and
    /// woke between 06:40 and 07:10."
    public var summary: String? {
        guard let bed = bedRange, let wake = wakeRange else {
            return measured.count == 1 ? "One night so far. Timing shows once there are two." : nil
        }
        let lead = usesMiddleHalf ? "Most nights you went to bed" : "You went to bed"
        return "\(lead) \(between(bed)) and woke \(between(wake))."
    }

    /// One line about last night, only when it moved by half an hour or more.
    public var shiftLine: String? {
        guard let shift = lastBedShift, abs(shift) >= Self.shiftWorthMentioning else { return nil }
        let amount = LooprUnitFormatter.duration(minutes: abs(shift)) ?? ""
        return "This night started \(amount) \(shift > 0 ? "later" : "earlier") than your usual bedtime."
    }

    private func between(_ range: ClosedRange<Double>) -> String {
        let low = SleepClock.text(minutesAfterNoon: range.lowerBound, timeZone: timeZone)
        let high = SleepClock.text(minutesAfterNoon: range.upperBound, timeZone: timeZone)
        if Int(range.lowerBound.rounded()) == Int(range.upperBound.rounded()) { return "at \(low)" }
        return "between \(low) and \(high)"
    }

    /// The vertical scale for the chart, padded half an hour and snapped to
    /// whole hours, at least six hours tall.
    public var chartDomain: ClosedRange<Double>? {
        let beds = measured.compactMap(\.bed), wakes = measured.compactMap(\.wake)
        guard let low = beds.min(), let high = wakes.max(), high > low else { return nil }
        var lower = ((low - 30) / 60).rounded(.down) * 60
        var upper = ((high + 30) / 60).rounded(.up) * 60
        if upper - lower < 360 {
            let pad = (360 - (upper - lower)) / 2
            lower -= (pad / 60).rounded(.up) * 60
            upper += (pad / 60).rounded(.up) * 60
        }
        return max(0, lower)...min(SleepClock.minutesPerDay, upper)
    }
}
