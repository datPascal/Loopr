import Foundation
import DesignSystem

/// The last 14 nights, each as minutes slept minus the target, and one thing
/// to do about the total.
///
/// - A night with no main sleep is a gap, never a zero bar and never counted
///   as a full shortfall: a night the band did not record is not a night
///   spent awake.
/// - Every night is measured against today's target (`SleepTarget`). Loopr
///   keeps no per-night history of the need, and the need moves slowly, so the
///   ledger says "against 7 h 50 m" rather than pretending otherwise.
/// - The suggestion spreads a shortfall over the next seven nights, at least
///   10 and at most 60 extra minutes a night, rounded to 5 minutes. That is a
///   plain planning rule, not a physiological claim: the ledger total is the
///   sum of the bars, so a week of slightly longer nights brings it back.
public struct SleepDebtLedger: Equatable, Sendable {
    public static let nights = 14
    /// Fewer measured nights than this and the total is not worth acting on.
    public static let minimumNights = 3
    /// A net total inside ±this many minutes counts as even.
    public static let evenMargin: Double = 15

    public struct Night: Equatable, Sendable, Identifiable {
        public let day: SleepCivilDay
        public let date: Date
        /// Minutes slept minus the target, nil with no main sleep.
        public let balance: Double?
        public var id: Int { day.ordinal }
    }

    public enum Suggestion: Equatable, Sendable {
        /// Too few nights for a fair total.
        case needsNights(measured: Int, needed: Int)
        /// Within `evenMargin` of the target over the fortnight.
        case even
        /// More sleep than the target in total.
        case ahead(minutes: Double)
        /// Short in total, with the extra minutes a night that clears it in a week.
        case behind(minutes: Double, extraPerNight: Double)
    }

    public let nights: [Night]
    public let targetMinutes: Double

    public init(nights: [Night], targetMinutes: Double) {
        self.nights = nights
        self.targetMinutes = targetMinutes
    }

    /// The 14 nights ending on the selected day, oldest first.
    public init(history: SleepNightHistory, target: SleepTarget, calendar: Calendar = .current) {
        targetMinutes = target.minutes
        guard let last = history.day else {
            nights = []
            return
        }
        var byDay: [SleepCivilDay: SleepNightRecord] = [:]
        for record in history.prior { byDay[record.day] = record }
        if let current = history.current { byDay[current.day] = current }
        nights = (0..<Self.nights).reversed().compactMap { offset -> Night? in
            guard let day = last.adding(days: -offset), let date = day.noon(in: calendar) else { return nil }
            let balance = byDay[day]?.asleepMinutes.map { $0 - target.minutes }
            return Night(day: day, date: date, balance: balance)
        }
    }

    public var measuredNights: Int { nights.filter { $0.balance != nil }.count }

    /// Sum of the bars: positive is ahead, negative is behind.
    public var netMinutes: Double { nights.compactMap(\.balance).reduce(0, +) }

    public var bars: [LooprDailyBar] { nights.map { LooprDailyBar(date: $0.date, value: $0.balance) } }

    public var suggestion: Suggestion {
        let measured = measuredNights
        guard measured >= Self.minimumNights else { return .needsNights(measured: measured, needed: Self.minimumNights) }
        let net = netMinutes
        if abs(net) < Self.evenMargin { return .even }
        if net > 0 { return .ahead(minutes: net) }
        return .behind(minutes: -net, extraPerNight: Self.extraPerNight(forShortfall: -net))
    }

    /// Minutes a night that make up `shortfall` over a week: rounded to 5,
    /// between 10 and 60.
    public static func extraPerNight(forShortfall shortfall: Double) -> Double {
        guard shortfall.isFinite, shortfall > 0 else { return 0 }
        let perNight = (shortfall / 7 / 5).rounded() * 5
        return min(max(perNight, 10), 60)
    }

    /// The headline over the chart: "3 h 10 m behind", "1 h 20 m ahead", "Even".
    public var headline: String {
        switch suggestion {
        case .needsNights(let measured, _):
            // A running total over one or two nights says little, so the
            // headline counts nights instead.
            return measured == 0 ? "No nights yet" : measured == 1 ? "1 night so far" : "\(measured) nights so far"
        case .even: return "Even"
        case .ahead, .behind: return netText
        }
    }

    private var netText: String {
        let net = netMinutes
        if abs(net) < 1 { return "Even" }
        let amount = LooprUnitFormatter.duration(minutes: abs(net)) ?? ""
        return net > 0 ? "\(amount) ahead" : "\(amount) behind"
    }

    /// The one actionable line under the chart.
    public var actionLine: String {
        switch suggestion {
        case .needsNights(let measured, let needed):
            let left = needed - measured
            return "A total needs \(needed) nights. \(left == 1 ? "1 more night" : "\(left) more nights") to go."
        case .even:
            return "Over these nights you slept close to the target. Keep your usual bedtime."
        case .ahead(let minutes):
            return "You slept \(LooprUnitFormatter.duration(minutes: minutes) ?? "") more than the target over these nights. No catching up needed."
        case .behind(_, let extra):
            return "Going to bed about \(LooprUnitFormatter.duration(minutes: extra) ?? "") earlier each night this week would make it up."
        }
    }
}
