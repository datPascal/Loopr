import DesignSystem
import Foundation
import RoutineKit

/// What the person's protocol asks of Food on a day: the kitchen-closes time, a fibre target and a protein target.
/// Each is nil when no rule sets it. Only rules checked by Food count, so a manual "kitchen closed" tick never moves
/// the rail.
public struct FoodProtocolTargets: Equatable, Sendable {
    /// Minutes after local midnight from a `last_meal_time` "at most" rule, 0 to 1439.
    public let kitchenClosesMinute: Int?
    /// Grams a day from a `fibre_g` "at least" rule.
    public let fibreGrams: Double?
    /// Grams a day from a `protein_g` "at least" rule.
    public let proteinGrams: Double?

    public static let none = FoodProtocolTargets(kitchenClosesMinute: nil, fibreGrams: nil, proteinGrams: nil)

    public init(kitchenClosesMinute: Int?, fibreGrams: Double?, proteinGrams: Double?) {
        self.kitchenClosesMinute = kitchenClosesMinute.flatMap { (0..<1_440).contains($0) ? $0 : nil }
        self.fibreGrams = fibreGrams.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.proteinGrams = proteinGrams.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Reads the food rules of one protocol version. With two kitchen rules the earlier time wins; with two amount
    /// rules the larger target wins, since keeping it keeps both.
    public init(rules: [ProtocolRule]) {
        func values(_ metric: RoutineMetric, _ kinds: Set<RuleTargetKind>) -> [Double] {
            rules.filter { $0.source == .food && $0.target.metric == metric.rawValue && kinds.contains($0.target.kind) }
                .compactMap(\.target.value).filter(\.isFinite)
        }
        let closes = values(.lastMealTime, [.atMost, .exactly]).map { Int($0.rounded(.down)) }.filter { (0..<1_440).contains($0) }.min()
        self.init(kitchenClosesMinute: closes, fibreGrams: values(.fibreG, [.atLeast, .exactly]).max(),
                  proteinGrams: values(.proteinG, [.atLeast, .exactly]).max())
    }
}

/// The kitchen-closes words in Food's header meta line.
public enum FoodKitchenClock {
    /// "Kitchen closes in 5 h 26 m", "Kitchen closes in 40 m" or "Kitchen closed at 18:30" on today. Nil on any other
    /// day and without a rule, so the meta line shows the date only.
    public static func phrase(closesAtMinute: Int?, now: Date, isToday: Bool, calendar: Calendar, locale: Locale = .current) -> String? {
        guard isToday, let closes = closesAtMinute else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard minute < closes else { return "Kitchen closed at \(LooprClockFormat.text(minuteOfDay: closes, locale: locale))" }
        let left = closes - minute
        let hours = left / 60, minutes = left % 60
        if hours == 0 { return "Kitchen closes in \(minutes) m" }
        return minutes == 0 ? "Kitchen closes in \(hours) h" : "Kitchen closes in \(hours) h \(minutes) m"
    }
}

extension FoodStore {
    /// The targets of the active protocol's version in force at `date`, or `.none` without an active protocol or
    /// before its first version. Pass the end of a past day, so a version saved that evening applies to it.
    public func protocolTargets(at date: Date) throws -> FoodProtocolTargets {
        let routine = RoutineStore(database: database)
        guard let active = try routine.activeProtocol(),
              let version = try routine.versionInForce(protocolID: active.routineProtocol.id, at: date) else { return .none }
        return FoodProtocolTargets(rules: version.rules)
    }

    /// The supplement and medication stack in the same database.
    public var supplementStore: SupplementStore { SupplementStore(database: database) }
}
