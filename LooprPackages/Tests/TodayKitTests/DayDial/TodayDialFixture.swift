import DesignSystem
import DomainKit
import Foundation
@testable import TodayKit

/// Fixed zones, days and instants for the day dial tests. Berlin has both daylight saving days in 2026: 29 March is
/// 23 hours and 25 October is 25 hours.
enum DialFixture {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let perth = TimeZone(identifier: "Australia/Perth")!
    static let utc = TimeZone(identifier: "UTC")!
    static let locale = Locale(identifier: "en_GB")
    /// Thursday 22 October 2026, an ordinary 24-hour day.
    static let day = DayIdentity(year: 2026, month: 10, day: 22)
    static let springDay = DayIdentity(year: 2026, month: 3, day: 29)
    static let autumnDay = DayIdentity(year: 2026, month: 10, day: 25)

    static func calendar(_ zone: TimeZone = berlin) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func date(_ day: DayIdentity, _ hour: Int, _ minute: Int = 0, zone: TimeZone = berlin) -> Date {
        calendar(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    static func shifted(_ day: DayIdentity, by days: Int) -> DayIdentity {
        let cal = calendar(utc)
        let base = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        let parts = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: days, to: base)!)
        return DayIdentity(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    static func inputs(day: DayIdentity = day, now: Date? = nil, zone: TimeZone = berlin) -> TodayDialInputs {
        TodayDialInputs(day: day, now: now ?? date(day, 7, 12, zone: zone), calendar: calendar(zone), locale: locale)
    }

    static func model(_ inputs: TodayDialInputs) -> TodayDialModel {
        TodayDialModel(inputs)!
    }

    /// Last night, 22:30 to 06:18, with 468 minutes asleep (7 h 48 m).
    static func night(on day: DayIdentity = day, zone: TimeZone = berlin) -> TodayDialNightInput {
        let before = shifted(day, by: -1)
        let start = date(before, 22, 30, zone: zone)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        let spans = [
            LooprStageSpan(id: 0, stage: .light, start: at(0), end: at(30)),
            LooprStageSpan(id: 1, stage: .deep, start: at(30), end: at(90)),
            LooprStageSpan(id: 2, stage: .rem, start: at(90), end: at(120)),
            LooprStageSpan(id: 3, stage: .awake, start: at(120), end: at(125)),
            LooprStageSpan(id: 4, stage: .light, start: at(125), end: at(468))
        ]
        return TodayDialNightInput(spans: spans, start: start, end: at(468), asleepMinutes: 468, provenance: .band(device: "WHOOP 4.0"))
    }

    /// 14 nights ending on `day`, every bedtime at `bed` minutes after noon.
    static func nights(ending day: DayIdentity = day, beds: [Double?]) -> [TodayDialNightTiming] {
        beds.enumerated().map { index, bed in
            TodayDialNightTiming(day: shifted(day, by: index - beds.count + 1), bedMinuteAfterNoon: bed)
        }
    }

    static let inBedRule = TodayDialRuleInput(key: "in-bed", title: "In bed", metric: "in_bed_time", targetValue: 1_350,
                                              source: .band, state: .pending)
    static let kitchenRule = TodayDialRuleInput(key: "kitchen", title: "Kitchen closes", metric: "last_meal_time",
                                                timeOfDayMinutes: 1_080, targetValue: 1_110, isEvening: true, source: .food,
                                                state: .pending)
    static let screensOffRule = TodayDialRuleInput(key: "screens-off", title: "Screens off", timeOfDayMinutes: 1_305, isEvening: true,
                                                   state: .pending)
    static let zone2Rule = TodayDialRuleInput(key: "zone2", title: "Zone 2, 45 min", metric: "zone2_minutes", timeOfDayMinutes: 1_050,
                                              targetValue: 45, source: .band, state: .pending)

    static func meal(_ id: String, _ at: Date, sticker: Bool = true) -> TodayDialMealInput {
        TodayDialMealInput(id: id, title: id, at: at,
                           sticker: sticker ? TodayDialSticker(photoID: UUID(), fileName: "\(id).jpg") : nil,
                           provenance: .food(.photoEstimate))
    }

    static func close(_ lhs: Double?, _ rhs: Double, tolerance: Double = 1e-6) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < tolerance
    }
}
