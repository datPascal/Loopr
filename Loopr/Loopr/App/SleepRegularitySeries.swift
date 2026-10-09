import Foundation
import DomainKit

extension CanonicalDailyAnalytics {
    /// One main sleep, keyed by the local day it ended on.
    struct RegularityNight: Sendable, Equatable {
        let day: DayIdentity
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Minute-by-minute asleep flags for the sleep regularity index, one
    /// 1,440-minute block per night, oldest first.
    ///
    /// Each block runs from noon the day before the wake day to noon of the
    /// wake day, so it holds exactly the night that belongs to that day. The
    /// earlier blocks ran midnight to midnight: the evening of the newest day
    /// then stood for a night that had not happened yet and was scored as
    /// awake against the previous evening's bedtime. Two identical nights with
    /// a 22:00 bedtime read 83 instead of 100.
    nonisolated static func regularityMinutes(_ nights: [RegularityNight], calendar: Calendar) -> [Bool] {
        let windows = nights.map { ($0.start, $0.end) }
        var asleep: [Bool] = []
        asleep.reserveCapacity(nights.count * 1_440)
        for night in nights {
            guard let midnight = calendar.date(from: DateComponents(era: night.day.era, year: night.day.year,
                                                                    month: night.day.month, day: night.day.day)),
                  let noonBefore = calendar.date(byAdding: .hour, value: -12, to: midnight) else { continue }
            let origin = noonBefore.timeIntervalSince1970
            for minute in 0..<1_440 {
                let instant = origin + Double(minute * 60)
                asleep.append(windows.contains { instant >= $0.0 && instant < $0.1 })
            }
        }
        return asleep
    }
}
