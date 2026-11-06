import DesignSystem
import Foundation
import StorageKit

/// One body weight reading. The local day is worked out from the time and zone, like a meal's.
public struct FoodWeightEntry: Codable, Equatable, Sendable, Identifiable {
    public static let validRange: ClosedRange<Double> = 20...400

    public let id: UUID
    public let measuredAt: Date
    public let timeZoneIdentifier: String
    public let localDay: String
    public let kilograms: Double

    public init(id: UUID = UUID(), measuredAt: Date, timeZoneIdentifier: String, kilograms: Double) throws {
        self.id = id; self.measuredAt = measuredAt; self.timeZoneIdentifier = timeZoneIdentifier
        self.kilograms = kilograms
        localDay = try FoodMeal.day(at: measuredAt, timeZoneIdentifier: timeZoneIdentifier)
        try validate()
    }

    public func validate() throws {
        guard kilograms.isFinite, Self.validRange.contains(kilograms),
              try FoodMeal.day(at: measuredAt, timeZoneIdentifier: timeZoneIdentifier) == localDay else { throw FoodError.invalidRecord }
    }

    private enum CodingKeys: String, CodingKey { case id, measuredAt, timeZoneIdentifier, localDay, kilograms }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), measuredAt: values.decode(Date.self, forKey: .measuredAt),
                      timeZoneIdentifier: values.decode(String.self, forKey: .timeZoneIdentifier),
                      kilograms: values.decode(Double.self, forKey: .kilograms))
        guard try values.decode(String.self, forKey: .localDay) == localDay else { throw FoodError.invalidRecord }
    }
}

/// Daily weight swings by a kilogram or more with water and food, so progress reads from a smoothed trend rather than
/// the last reading.
///
/// The trend is an exponentially smoothed moving average of each day's mean reading, the method of John Walker's
/// The Hacker's Diet: each weigh-in day moves the trend 10% of the way to that day's weight (smoothing constant
/// `smoothing` = 0.1 per day). After a gap of n days without a reading, the next one moves it 1 − 0.9ⁿ of the way, as if
/// that weight had been read on every day of the gap. The first day seeds the trend.
///
/// The trend and its weekly change count only with weigh-ins on `minimumDays` of the last `windowDays` days. Below
/// that the card shows the latest day's weight and how many more weigh-ins the trend needs.
public struct FoodWeightTrend: Equatable, Sendable {
    /// Share of the way each day moves the trend toward that day's weight.
    public static let smoothing = 0.1
    /// Weigh-in days the trend needs in the last `windowDays` days.
    public static let minimumDays = 7
    public static let windowDays = 14

    /// The latest reading.
    public let latest: FoodWeightEntry
    /// The smoothed trend on the latest weigh-in day, kilograms.
    public let smoothed: Double
    /// The trend on the latest weigh-in day minus the trend seven days before it, kilograms. Nil when the readings
    /// start less than seven days before the latest.
    public let weeklyChange: Double?
    /// One point per day with a reading, oldest first: the day's mean.
    public let daily: [Point]
    /// Days with a reading in the `windowDays` days up to the latest one.
    public let recentDays: Int

    /// True with weigh-ins on at least `minimumDays` of the last `windowDays` days.
    public var hasEnoughReadings: Bool { recentDays >= Self.minimumDays }
    /// Weigh-in days still missing before the trend counts.
    public var daysNeeded: Int { max(Self.minimumDays - recentDays, 0) }
    /// The weight the card shows: the trend once it counts, otherwise the latest day's mean.
    public var current: Double { hasEnoughReadings ? smoothed : daily.last?.kilograms ?? latest.kilograms }

    /// True when the latest reading is more than seven days before `now`: an average of old readings is not this
    /// week's weight, so the card shows the last reading and its date instead (ICP R2-OPT-21).
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(latest.measuredAt) > 7 * 86_400 }

    public struct Point: Equatable, Sendable, Identifiable {
        public let localDay: String
        public let date: Date
        public let kilograms: Double
        public var id: String { localDay }
    }

    /// Nil without any reading.
    public init?(_ entries: [FoodWeightEntry]) {
        let sorted = entries.sorted { ($0.measuredAt, $0.id.uuidString) < ($1.measuredAt, $1.id.uuidString) }
        guard let latest = sorted.last else { return nil }
        self.latest = latest
        let points = Dictionary(grouping: sorted, by: \.localDay)
            .map { day, readings in Point(localDay: day, date: readings[0].measuredAt, kilograms: Self.mean(readings.map(\.kilograms))) }
            .sorted { $0.localDay < $1.localDay }
        daily = points
        let days = points.map { Self.dayNumber($0) }
        var trend: [Double] = []
        for (index, point) in points.enumerated() {
            guard let previous = trend.last else { trend.append(point.kilograms); continue }
            let gap = Double(max(days[index] - days[index - 1], 1))
            let step = 1 - pow(1 - Self.smoothing, gap)
            trend.append(previous + step * (point.kilograms - previous))
        }
        smoothed = trend.last ?? latest.kilograms
        let lastDay = days.last ?? 0
        recentDays = days.filter { lastDay - $0 < Self.windowDays }.count
        // The trend seven days back is the value after the newest weigh-in on or before that day.
        if let earlier = days.lastIndex(where: { $0 <= lastDay - 7 }) {
            weeklyChange = smoothed - trend[earlier]
        } else {
            weeklyChange = nil
        }
    }

    private static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }

    /// Days since 1970 for a point's "yyyy-MM-dd" local day, or from its time when the key does not parse.
    private static func dayNumber(_ point: Point) -> Int {
        let parts = point.localDay.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        if parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
            return Int((date.timeIntervalSince1970 / 86_400).rounded())
        }
        return Int((point.date.timeIntervalSince1970 / 86_400).rounded(.down))
    }
}

/// What the weight trend says about the plan: when the trend moves at a different weekly rate than the goal aims for,
/// how many kcal a day would close the gap, at 7,700 kcal per kilogram (`FoodGoalPlanner.energyPerKilogram`). It is
/// only a suggestion: Loopr never changes a target by itself.
public struct FoodWeightSuggestion: Equatable, Sendable {
    /// Gaps smaller than this, in kilograms a week, are inside what a trend can tell apart, so no suggestion shows.
    public static let threshold = 0.15

    /// The trend's weekly change, kilograms, negative when falling.
    public let trendPerWeek: Double
    /// The plan's weekly change, kilograms, negative for a loss.
    public let planPerWeek: Double
    public let goal: FoodGoal
    /// Kcal a day that would bring the trend to the plan's rate, rounded to 10. Positive means eat more.
    public let energyPerDay: Double

    /// Nil unless the trend counts, is current, has a weekly change, a plan exists, and the two rates differ by at least
    /// `threshold`.
    public init?(trend: FoodWeightTrend?, goal: FoodGoal, plan: FoodGoalPlan?, now: Date) {
        guard let trend, let plan, trend.hasEnoughReadings, !trend.isStale(at: now), let change = trend.weeklyChange else { return nil }
        let planned: Double = switch goal {
        case .lose: -plan.paceKgPerWeek
        case .build: plan.paceKgPerWeek
        case .maintain: 0
        }
        let gap = change - planned
        guard abs(gap) >= Self.threshold else { return nil }
        trendPerWeek = change; planPerWeek = planned; self.goal = goal
        energyPerDay = (-gap * FoodGoalPlanner.energyPerKilogram / 7 / 10).rounded() * 10
    }

    /// "Your trend fell 0.64 kg a week. Your plan aims for a loss of 0.25 kg a week. Eating about 430 kcal more a day
    /// would match it. That is a gap of 0.39 kg a week at 7,700 kcal per kg." Rates show two decimals, so the shown
    /// numbers subtract to the shown gap.
    public var sentence: String {
        let shownTrend = (trendPerWeek * 100).rounded() / 100
        let trend = abs(shownTrend) < 0.05 ? "Your trend held steady."
            : "Your trend \(shownTrend < 0 ? "fell" : "rose") \(FoodGoalProgress.pace(abs(shownTrend))) kg a week."
        let plan = switch goal {
        case .lose: "Your plan aims for a loss of \(FoodGoalProgress.pace(abs(planPerWeek))) kg a week."
        case .build: "Your plan aims for a gain of \(FoodGoalProgress.pace(abs(planPerWeek))) kg a week."
        case .maintain: "Your plan aims to hold your weight."
        }
        let kcal = LooprUnitFormatter.number(abs(energyPerDay), digits: 0) ?? "0"
        let perKilogram = LooprUnitFormatter.number(FoodGoalPlanner.energyPerKilogram, digits: 0) ?? "7,700"
        let gap = FoodGoalProgress.pace((abs(shownTrend - planPerWeek) * 100).rounded() / 100)
        return "\(trend) \(plan) Eating about \(kcal) kcal \(energyPerDay > 0 ? "more" : "less") a day would match it. "
            + "That is a gap of \(gap) kg a week at \(perKilogram) kcal per kg."
    }
}

// MARK: Body composition typed with a weight

/// Body fat and lean mass a person typed with one weight reading (`storage-022-body-composition`). The weight stays
/// a `FoodWeightEntry` in the Food weight table, so the Food lens keeps reading it. This row shares the weight's id
/// and leaves with it.
public struct FoodBodyComposition: Equatable, Sendable {
    /// Body fat as a share of the weight, in percent.
    public static let bodyFatRange: ClosedRange<Double> = 2...75
    public static let leanMassRange: ClosedRange<Double> = 10...200

    public let weightID: UUID
    public let bodyFatPercent: Double?
    public let leanMassKilograms: Double?

    /// At least one value, each inside its range, and a lean mass below the weight it was typed with.
    public init(weightID: UUID, weightKilograms: Double, bodyFatPercent: Double?, leanMassKilograms: Double?) throws {
        guard bodyFatPercent != nil || leanMassKilograms != nil else { throw FoodError.invalidRecord }
        if let bodyFatPercent, !(bodyFatPercent.isFinite && Self.bodyFatRange.contains(bodyFatPercent)) { throw FoodError.invalidRecord }
        if let leanMassKilograms,
           !(leanMassKilograms.isFinite && Self.leanMassRange.contains(leanMassKilograms) && leanMassKilograms < weightKilograms) {
            throw FoodError.invalidRecord
        }
        self.weightID = weightID; self.bodyFatPercent = bodyFatPercent; self.leanMassKilograms = leanMassKilograms
    }
}

public extension FoodStore {
    /// Saves a weight reading and its body fat and lean mass in one transaction. With neither value, any earlier
    /// composition for the same reading is removed.
    func saveWeight(_ entry: FoodWeightEntry, bodyFatPercent: Double?, leanMassKilograms: Double?, createdAt: Date = Date()) throws {
        var composition: FoodBodyComposition?
        if bodyFatPercent != nil || leanMassKilograms != nil {
            composition = try FoodBodyComposition(weightID: entry.id, weightKilograms: entry.kilograms,
                                                  bodyFatPercent: bodyFatPercent, leanMassKilograms: leanMassKilograms)
        }
        let checked = composition
        try database.write { db in
            try Self.saveWeight(entry, in: db)
            guard let composition = checked else {
                try db.execute(sql: "DELETE FROM body_composition WHERE weight_id = ?", arguments: [entry.id.uuidString])
                return
            }
            try db.execute(sql: """
                INSERT INTO body_composition(weight_id, body_fat_percent, lean_mass_kilograms, created_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(weight_id) DO UPDATE SET body_fat_percent = excluded.body_fat_percent,
                    lean_mass_kilograms = excluded.lean_mass_kilograms
                """, arguments: [entry.id.uuidString, composition.bodyFatPercent, composition.leanMassKilograms,
                                 createdAt.timeIntervalSince1970])
        }
    }

    /// The typed body fat and lean mass, by the id of the weight reading they belong to. Readings measured at or
    /// after `since` only, when given.
    func bodyCompositions(since: Date? = nil) throws -> [UUID: FoodBodyComposition] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.weight_id, c.body_fat_percent, c.lean_mass_kilograms, w.payload
                FROM body_composition c JOIN food_weight w ON w.id = c.weight_id
                """ + (since == nil ? "" : " WHERE w.measured_at >= ?"),
                arguments: since.map { [$0.timeIntervalSince1970] } ?? [])
            var result: [UUID: FoodBodyComposition] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["weight_id"] as String) else { continue }
                let weight = try Self.decodeWeight(row["payload"] as Data)
                result[id] = try FoodBodyComposition(weightID: id, weightKilograms: weight.kilograms,
                    bodyFatPercent: row["body_fat_percent"], leanMassKilograms: row["lean_mass_kilograms"])
            }
            return result
        }
    }
}
