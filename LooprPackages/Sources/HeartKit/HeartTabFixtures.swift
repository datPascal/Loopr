import Foundation
import DesignSystem
import DomainKit

/// Fixture data for the Heart tab's cards and day timeline. Used by fixture
/// launch modes, previews and tests only; production reads storage.
public extension HeartFixtures {
    /// Age used for the fixture zone scale (maximum 184 bpm).
    static let fixtureAge = 34

    /// Services that answer from `LooprFixtureMetrics` and a synthetic day
    /// built around `LooprSampleNight`, so the cards end on the values the
    /// fixture rows show and the timeline's night matches the Sleep fixture.
    static func tabServices(calendar: Calendar = .current) -> HeartTabServices {
        HeartTabServices(
            history: { id, days, end in
                LooprFixtureMetrics.history(id, days: days, endingOn: end, calendar: calendar)
            },
            timeline: { day in dayTimeline(for: day, calendar: calendar) },
            lastReading: {
                let day = LooprDay(year: HeartFixtures.day.year, month: HeartFixtures.day.month, day: HeartFixtures.day.day)
                guard let last = daySamples(for: day, calendar: calendar).last else { return nil }
                return HeartLastReading(bpm: last.bpm, at: Date(timeIntervalSince1970: last.time))
            },
            zones: .agePredicted(age: fixtureAge),
            age: fixtureAge,
            zoneSettings: HeartRateZoneSettings()
        )
    }

    /// Minutes after local midnight when the fixture day's recording ends.
    static let fixtureRecordingEndMinute = 21 * 60 + 30

    /// The fixture day: last night 23:18 to 07:46 (the Sleep fixture's 8 h 28 m
    /// night), a desk day, a lunchtime walk and a 44-minute run at 17:30.
    static func dayTimeline(for day: LooprDay, calendar: Calendar = .current) -> HeartDayTimeline? {
        guard let start = day.start(in: calendar),
              let end = day.adding(days: 1, calendar: calendar)?.start(in: calendar) else { return nil }
        let samples = daySamples(for: day, calendar: calendar)
        guard !samples.isEmpty else { return nil }
        let sleepStart = start.addingTimeInterval(-42 * 60)
        let sleepEnd = sleepStart.addingTimeInterval(Double(LooprSampleNight.timeInBedMinutes) * 60)
        let run = start.addingTimeInterval((17 * 60 + 30) * 60)
        return HeartTimelineBuilder.build(
            samples: samples, dayStart: start, dayEnd: end,
            sleep: [DateInterval(start: sleepStart, end: sleepEnd)],
            workouts: [HeartTimelineWorkout(start: run, end: run.addingTimeInterval(44 * 60), title: "Run")]
        )
    }

    /// Per-second readings for the fixture day, deterministic per day.
    static func daySamples(for day: LooprDay, calendar: Calendar = .current) -> [HeartRateSample] {
        guard let start = day.start(in: calendar) else { return [] }
        var generator = FixtureNoise(seed: UInt64(day.year * 10_000 + day.month * 100 + day.day))
        let dayStart = start.timeIntervalSince1970
        // Stage for each minute of the night, from 23:18 the evening before.
        var stageByMinute: [SleepStage] = []
        for segment in LooprSampleNight.segments {
            stageByMinute += Array(repeating: segment.stage, count: segment.durationMinutes)
        }
        let nightOffsetMinutes = 42
        var samples: [HeartRateSample] = []
        samples.reserveCapacity(fixtureRecordingEndMinute * 60)
        var wander = 0.0
        for second in 0..<(fixtureRecordingEndMinute * 60) {
            let minute = second / 60
            // A few short gaps where the band sat loose.
            if (minute >= 611 && minute < 619) || (minute >= 1_005 && minute < 1_011) { continue }
            wander = wander * 0.995 + generator.signed() * 0.35
            let base: Double
            let nightMinute = minute + nightOffsetMinutes
            if nightMinute < stageByMinute.count {
                switch stageByMinute[nightMinute] {
                case .deep: base = 49
                case .light: base = 53
                case .rem: base = 57
                case .awake: base = 63
                }
            } else {
                base = daytimeBase(minute: minute)
            }
            let bpm = base + wander + generator.signed() * 1.6
            samples.append(HeartRateSample(time: dayStart + Double(second), bpm: bpm.rounded()))
        }
        return samples
    }

    private static func daytimeBase(minute: Int) -> Double {
        switch minute {
        case ..<(8 * 60 + 30): 76                                  // getting up, breakfast
        case ..<(12 * 60 + 30): 66                                 // desk
        case ..<(13 * 60 + 10): 92                                 // walk to lunch
        case ..<(17 * 60 + 30): 69                                 // afternoon
        case ..<(17 * 60 + 38): 110 + Double(minute - (17 * 60 + 30)) * 5   // warm-up
        case ..<(18 * 60 + 6): 152 + sin(Double(minute) / 3) * 6   // run
        case ..<(18 * 60 + 14): 150 - Double(minute - (18 * 60 + 6)) * 8    // cool-down
        case ..<(19 * 60): 84                                      // shower, cooking
        default: 71                                                // evening
        }
    }
}

/// A small deterministic noise source for fixtures.
struct FixtureNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Uniform in −1...1.
    mutating func signed() -> Double { Double(next() % 2_000_001) / 1_000_000 - 1 }
}
