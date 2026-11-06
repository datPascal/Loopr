import DesignSystem
import Foundation

/// The dial's VoiceOver summary: what each layer shows, in the order a person reads the day.
enum TodayDialSpoken {
    static func summary(mode: TodayDialMode, centre: TodayDialCentre, eating: TodayDialLayer<TodayDialEating>,
                        training: TodayDialLayer<[TodayDialTrainingBlock]>, daylight: TodayDialLayer<TodayDialDaylight>,
                        beads: [TodayDialBead], alarm: TodayDialAlarmBead?, clock: TodayDialClock, locale: Locale) -> String {
        func time(_ date: Date) -> String { TodayDialFormat.clock(date, clock: clock, locale: locale) }
        var parts: [String] = []

        switch centre {
        case .asleep(let asleep):
            var line = "\(LooprUnitFormatter.spokenDuration(minutes: asleep.minutes) ?? asleep.text) asleep last night"
            if let nights = asleep.onTimeNights, nights > 0 { line += ", \(TodayDialReadoutRules.onTimeStreak(nights))" }
            parts.append(line + ".")
        case .countdown(let countdown):
            let left = LooprUnitFormatter.spokenDuration(minutes: countdown.remaining / 60) ?? countdown.text
            parts.append(countdown.isPastBedtime ? "\(left) past bedtime at \(countdown.bedtimeText)."
                                                 : "\(left) until bed at \(countdown.bedtimeText).")
        case .absent(let absence):
            parts.append(absence.message + ".")
        }

        switch eating {
        case .present(let value):
            let count = value.meals.count == 1 ? "1 meal" : "\(value.meals.count) meals"
            parts.append(value.meals.count == 1 ? "\(count) at \(time(value.window.start))."
                                                : "\(count), from \(time(value.window.start)) to \(time(value.window.end)).")
        case .absent(let absence):
            parts.append(absence.message)
        }

        switch training {
        case .present(let blocks):
            for block in blocks {
                let span = block.arc.sweep > 0 ? "\(time(block.arc.start)) to \(time(block.arc.end))" : "at \(time(block.arc.start))"
                parts.append(block.isPlanned ? "\(block.title) planned \(span)." : "\(block.title) \(span).")
            }
        case .absent(let absence):
            parts.append(absence.message)
        }

        switch daylight {
        case .present(let value):
            parts.append("\(LooprUnitFormatter.spokenDuration(minutes: value.minutes) ?? "") in daylight.")
        case .absent(let absence):
            parts.append(absence.message)
        }

        if !beads.isEmpty {
            let kept = beads.filter { $0.state == .kept }.count
            parts.append("\(beads.count == 1 ? "1 timed rule" : "\(beads.count) timed rules"), \(kept) kept.")
        }
        if let alarm {
            parts.append("Alarm at \(time(alarm.wake))\(alarm.isTomorrow ? " tomorrow" : "").")
        }
        return (mode == .evening ? "Day dial, evening. " : "Day dial, morning. ") + parts.joined(separator: " ")
    }
}
