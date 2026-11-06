import DesignSystem
import DomainKit
import Foundation

/// Where everything on the day dial sits, in the contract's 340-point view box
/// (`design/longevity-vision/index.html`, function `dial()`). The view scales the box to its frame.
///
/// Angles are degrees clockwise from the top. Noon is at the top, 18:00 on the right, midnight at the bottom and
/// 06:00 on the left, as the contract's `pol(c, r, h)` draws them: `h / 24 * 360 + 180`.
public enum TodayDialGeometry {
    public static let viewBox: Double = 340
    public static let centre: Double = 170

    // Face and frame.
    public static let faceRadius: Double = 162
    public static let innerRingRadius: Double = 68
    /// Ticks run from these radii out to `tickOuterRadius`: every 6 hours, every hour, every quarter hour.
    public static let tickOuterRadius: Double = 158
    public static let sixHourTickInnerRadius: Double = 146
    public static let hourTickInnerRadius: Double = 150
    public static let quarterTickInnerRadius: Double = 153
    /// The "00", "06", "12" and "18" labels.
    public static let hourLabelRadius: Double = 168

    // Layer rings, outermost first.
    /// Daylight dots and rule beads.
    public static let rimRadius: Double = 142
    /// The hypnogram, tonight's window, the wind-down arc and the bedtime gem.
    public static let sleepRadius: Double = 120
    /// The eating window, the meal stickers and the kitchen-closes bead. The "tonight" label sits here too.
    public static let eatingRadius: Double = 96
    public static let trainingRadius: Double = 80

    // Stroke widths.
    public static let tonightWindowWidth: Double = 24
    public static let windDownWidth: Double = 10
    public static let eatingPlannedWidth: Double = 3
    public static let eatingWindowWidth: Double = 3.4
    public static let trainingWidth: Double = 7

    // Marks.
    public static let daylightDotRadius: Double = 1.9
    public static let ruleBeadRadius: Double = 4.2
    public static let kitchenBeadRadius: Double = 4
    /// The side of the bedtime gem, a square turned 45 degrees: smaller in the morning, larger in the evening.
    public static let morningBedtimeGemSide: Double = 10
    public static let eveningBedtimeGemSide: Double = 12
    /// A meal sticker: a white rim and the photo inside it.
    public static let stickerRadius: Double = 16.5
    public static let stickerImageRadius: Double = 14
    /// The "tonight" label sits 48 minutes past bedtime on the eating ring (contract: 23.3 h for a 22.5 h bedtime).
    public static let tonightLabelMinutesAfterBedtime: Double = 48

    // The hand.
    public static let handInnerRadius: Double = 70
    public static let handOuterRadius: Double = 160
    public static let handTipRadius: Double = 5

    /// Daylight measured with times gets one dot every 1.5 minutes (the contract's `1/60*1.5` step).
    public static let daylightMinutesPerTimedDot: Double = 1.5
    /// A daily total without times gets one dot per 5 minutes, spread over the daytime rim.
    public static let daylightMinutesPerSpreadDot: Double = 5
    /// Above this many dots the layer stops adding more: 12 hours of daylight at the timed step.
    public static let maximumDaylightDots = 480

    /// Stroke width per stage, all centred on `sleepRadius`. Deep is widest, awake a thin line. The contract's "core"
    /// stage is Loopr's light sleep.
    public static func stageWidth(_ stage: SleepStage) -> Double {
        switch stage {
        case .deep: 22
        case .light: 13
        case .rem: 16
        case .awake: 5
        }
    }

    /// Degrees clockwise from the top for a wall-clock minute after midnight. Any minute wraps round the clock.
    public static func angle(minuteOfDay minutes: Double) -> Double {
        normalized(minutes / 1_440 * 360 + 180)
    }

    /// The point at `radius` and `angle` in the view box. y grows downwards, as in SVG and SwiftUI.
    public static func point(radius: Double, angle: Double) -> TodayDialPoint {
        let radians = angle * .pi / 180
        return TodayDialPoint(x: centre + radius * sin(radians), y: centre - radius * cos(radians))
    }

    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}

/// A point in the dial's view box.
public struct TodayDialPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A stretch of time on the dial: where it starts and how far it sweeps clockwise.
public struct TodayDialArc: Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// Degrees clockwise from the top.
    public let startAngle: Double
    /// Degrees the arc sweeps clockwise, 0 for an instant and never more than 360.
    public let sweep: Double

    public init(start: Date, end: Date, startAngle: Double, sweep: Double) {
        self.start = start
        self.end = end
        self.startAngle = startAngle
        self.sweep = sweep
    }

    public var endAngle: Double { TodayDialGeometry.normalized(startAngle + sweep) }
}

/// One local calendar day on the dial, and the mapping from instants to angles.
///
/// The dial is a wall clock. An instant sits at the angle of its wall-clock time in the dial's time zone, whatever
/// zone it was recorded in, so the hand, the hour labels and every layer agree after a flight. On a 25-hour day the
/// repeated hour lands on the same angles twice. On a 23-hour day the skipped hour is an empty stretch of the face,
/// and an arc across it is drawn through it, because its ends sit at their wall-clock times.
public struct TodayDialClock: Equatable, Sendable {
    public let day: DayIdentity
    public let calendar: Calendar
    /// Local midnight that opens the day.
    public let start: Date
    /// Local midnight that ends it.
    public let end: Date

    /// - Parameter calendar: Its time zone is the dial's zone.
    public init?(day: DayIdentity, calendar: Calendar) {
        guard let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) else {
            return nil
        }
        let start = calendar.startOfDay(for: noon)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        self.day = day
        self.calendar = calendar
        self.start = start
        end = calendar.startOfDay(for: next)
    }

    public var timeZone: TimeZone { calendar.timeZone }

    /// 23, 24 or 25 on daylight saving days.
    public var hoursInDay: Double { end.timeIntervalSince(start) / 3_600 }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Wall-clock minutes after this day's midnight, counting whole days before or after it: 22:30 the evening
    /// before is -90 and 01:00 the next morning is 1,500.
    public func dialMinutes(of date: Date) -> Double {
        let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(offset * 1_440 + (parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
    }

    /// The wall-clock minute of `date` on its own day, 0 to 1439.
    public func minuteOfDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    public func angle(of date: Date) -> Double {
        TodayDialGeometry.angle(minuteOfDay: dialMinutes(of: date))
    }

    /// The instant a wall-clock minute names, on this day or `dayOffset` days later. A time the clocks skip moves to
    /// the next time that exists.
    public func date(minuteOfDay minute: Int, dayOffset: Int = 0) -> Date? {
        guard let base = calendar.date(byAdding: .day, value: dayOffset, to: start) else { return nil }
        let wrapped = ((minute % 1_440) + 1_440) % 1_440
        return calendar.date(bySettingHour: wrapped / 60, minute: wrapped % 60, second: 0, of: base, matchingPolicy: .nextTime,
                             repeatedTimePolicy: .first, direction: .forward)
    }

    /// The arc from `start` to `end`, or nil when `end` is before `start`.
    ///
    /// The sweep is the wall-clock distance between the ends, so the arc meets the hour labels. When the clocks go
    /// back inside the stretch and the wall-clock distance is zero or less, the elapsed time is used instead.
    public func arc(from start: Date, to end: Date) -> TodayDialArc? {
        guard end >= start else { return nil }
        let wall = dialMinutes(of: end) - dialMinutes(of: start)
        let elapsed = end.timeIntervalSince(start) / 60
        let minutes = min(wall > 0 ? wall : elapsed, 1_440)
        return TodayDialArc(start: start, end: end, startAngle: angle(of: start), sweep: minutes / 1_440 * 360)
    }
}
