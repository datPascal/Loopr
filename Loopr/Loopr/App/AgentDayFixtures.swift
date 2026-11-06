#if DEBUG
import FoodKit
import Foundation

/// DEBUG fixture data that Today's timeline and Sleep's "What was different" card read, from
/// `--loopr-agent-day-fixture`. Alex lives in Australia/Perth and the fixture day is Tue 2023-11-14.
///
/// The flag adds one thing to the populated Food fixture: dinners at 21:00 to 21:45 on the 21 days from 27 to 7 days
/// before the fixture day. The populated fixture already has dinner at 19:00 on the six days before it, so the
/// night that ends on the fixture day follows an early dinner. The other inputs come from fixtures that exist:
/// `--loopr-journal-fixture=checkin` (alcohol on 19 of the last 28 days, none the evening before),
/// `--loopr-train-fixture` (Upper A planned at 18:30 on the fixture day, a Lower A session the day before) and
/// `--loopr-patterns-fixture=found` (found patterns, no running test).
///
/// Nothing here touches a real store or the network, and nothing here is health data of a real person.
nonisolated enum AgentDayFixtures {
    static let flag = "--loopr-agent-day-fixture"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    /// Late dinners on `-27...-7` days before `today`, in `calendar`'s zone.
    static func seedLateDinners(_ store: FoodStore, today: Date, calendar: Calendar) throws {
        for (index, offset) in (-27...(-7)).enumerated() {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let time = day.addingTimeInterval((21 + Double(index % 4) * 0.25) * 3_600)
            let dinner = FoodItem(name: "Pasta and salad", amount: 1, unit: .serving,
                nutrients: .init([.energy: 820, .protein: 38, .carbs: 96, .fat: 28, .fibre: 7, .sugar: 8, .salt: 1.4,
                                  .caffeine: 0, .alcoholUnits: 0]),
                provenance: [.init(source: .typed, recordedAt: time)])
            try store.confirm(.init(slot: .dinner, occurredAt: time, timeZoneIdentifier: calendar.timeZone.identifier, items: [dinner]), at: time)
        }
    }
}
#endif
