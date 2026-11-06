import DesignSystem
import DomainKit
import Foundation

/// Today's hero (DEC-12.3): a 24-hour dial with noon at the top, built from stored data for one local day and one
/// instant. Pure: the same inputs give the same model, so the view can rebuild it on every clock tick.
///
/// What it decides:
/// - The mode: evening from 18:00 wall-clock time on today's dial, morning otherwise and on every past day.
/// - Each layer, or the sentence that says why it is absent. Missing data is never drawn as zero.
/// - Tonight's bedtime: the protocol's in-bed rule first (or its asleep-by rule), then Sleep's plan. A bedtime before
///   noon is the next calendar day.
/// - The centre: last night asleep in the morning, the bedtime countdown in the evening.
/// - The three readouts for the mode, each with its source.
/// - The render state: empty, learning, partial or complete.
public struct TodayDialModel: Equatable, Sendable {
    public let clock: TodayDialClock
    public let now: Date
    /// The clock is on this day.
    public let isToday: Bool
    public let mode: TodayDialMode
    /// Nil on a past day.
    public let hand: TodayDialHand?
    /// Last night in the morning, tonight's window in the evening.
    public let sleep: TodayDialLayer<TodayDialSleep>
    /// Tonight's bedtime gem, in both modes. Nil with no rule and no plan.
    public let bedtime: TodayDialBedtime?
    public let eating: TodayDialLayer<TodayDialEating>
    public let training: TodayDialLayer<[TodayDialTrainingBlock]>
    public let daylight: TodayDialLayer<TodayDialDaylight>
    public let beads: [TodayDialBead]
    public let alarm: TodayDialAlarmBead?
    public let centre: TodayDialCentre
    public let readouts: [TodayDialReadout]
    /// Recovery in both modes. It is the third readout in the morning; in the evening the dial shows it as a compact
    /// row under the readouts, so "What shaped it" stays one tap away all day (DEC-12.3).
    public let recovery: TodayDialReadout
    public let render: TodayDialRenderState
    /// What VoiceOver says for the whole dial.
    public let accessibilitySummary: String

    /// Nil only when the day cannot be placed on the calendar.
    public init?(_ inputs: TodayDialInputs) {
        guard let clock = TodayDialClock(day: inputs.day, calendar: inputs.calendar) else { return nil }
        let now = inputs.now
        let locale = inputs.locale
        let isToday = clock.contains(now)
        let mode: TodayDialMode = isToday && clock.minuteOfDay(now) >= TodayDialMode.eveningStartMinute ? .evening : .morning
        let rules = inputs.rules.map { TodayDialRule($0) }

        self.clock = clock
        self.now = now
        self.isToday = isToday
        self.mode = mode
        hand = isToday ? TodayDialHand(date: now, angle: clock.angle(of: now)) : nil

        let bedtime = isToday ? Self.bedtime(rules: rules, tonight: inputs.tonight, clock: clock) : nil
        self.bedtime = bedtime
        let lastNight = Self.hypnogram(inputs.lastNight, clock: clock)
        switch mode {
        case .morning:
            if let lastNight {
                sleep = .present(.lastNight(lastNight))
            } else if isToday {
                sleep = .absent(TodayDialAbsence(gap: .noData,
                    message: "No sleep recorded for last night. It fills in after your next tracked night."))
            } else {
                // A past day: no night is coming, only a later sync can still bring one.
                sleep = .absent(TodayDialAbsence(gap: .noData, message: Self.pastDayNoNightMessage))
            }
        case .evening:
            if let bedtime {
                sleep = .present(.tonight(Self.tonight(bedtime, rules: rules, inputs: inputs, clock: clock)))
            } else {
                sleep = .absent(TodayDialAbsence(gap: .noData,
                    message: "No bedtime for tonight yet. Add an in-bed rule, or sleep three nights for a suggested one."))
            }
        }

        let eating = Self.onThisDay(Self.eating(inputs.meals, rules: rules, clock: clock), isToday: isToday)
        self.eating = eating
        let training = Self.onThisDay(Self.training(inputs.workouts, planned: inputs.plannedSessions, rules: rules, now: now,
                                                    clock: clock), isToday: isToday)
        self.training = training
        let daylight = Self.daylight(inputs.daylight, now: now, isToday: isToday, clock: clock)
        self.daylight = daylight
        let beads = Self.beads(rules, clock: clock)
        self.beads = beads
        alarm = isToday ? Self.alarm(inputs.alarm, mode: mode, now: now, clock: clock) : nil

        switch mode {
        case .morning:
            let minutes = lastNight.flatMap { $0.asleepMinutes }
            if let minutes, let night = lastNight {
                let ruleBed = rules.first { $0.role == .bedtime }?.limitMinute.map(Self.minutesAfterNoon)
                centre = .asleep(TodayDialReadoutRules.asleep(
                    minutes: minutes, onTime: TodayDialReadoutRules.onTimeNights(inputs.recentNights, ruleBedMinuteAfterNoon: ruleBed),
                    provenance: night.provenance))
            } else {
                centre = .absent(TodayDialAbsence(gap: .noData,
                                                  message: isToday ? "No sleep recorded for last night" : "No night recorded"))
            }
        case .evening:
            if let bedtime {
                centre = .countdown(TodayDialReadoutRules.countdown(bedtime: bedtime, now: now, clock: clock, locale: locale))
            } else {
                centre = .absent(TodayDialAbsence(gap: .noData, message: "No bedtime set for tonight"))
            }
        }

        // Nights the band measured up to this day: the recent bedtimes, last night, or the sleeping heart rate nights the
        // usual is read from, whichever counts more. A past day without a night still has the nights before it.
        let heartRateNights = inputs.sleepHeartRateBefore.filter { $0.isFinite && $0 > 0 }.count
            + (inputs.sleepHeartRate.value == nil ? 0 : 1)
        let nightsMeasured = max(inputs.recentNights.filter { $0.bedMinuteAfterNoon?.isFinite == true }.count,
                                 inputs.lastNight == nil ? 0 : 1, heartRateNights)
        let recovery = TodayDialReadoutRules.recovery(inputs.recovery, provenance: inputs.recoveryProvenance)
        self.recovery = recovery
        switch mode {
        case .morning:
            readouts = [
                TodayDialReadoutRules.sleepHeartRate(inputs.sleepHeartRate, before: inputs.sleepHeartRateBefore, locale: locale),
                TodayDialReadoutRules.regularity(inputs.regularity, nightsMeasured: nightsMeasured, locale: locale),
                recovery
            ]
        case .evening:
            let kitchen = rules.first { $0.role == .kitchenCloses }
            let zone2Target = rules.first { $0.metric == TodayDialRule.Metric.zone2 }?.input.targetValue.flatMap { $0.isFinite ? $0 : nil }
            readouts = [
                TodayDialReadoutRules.lastMeal(eating.value?.meals.last, bedtime: bedtime, kitchenKept: kitchen?.input.state == .kept,
                                               clock: clock, locale: locale),
                TodayDialReadoutRules.zone2(inputs.zone2Minutes, target: zone2Target, locale: locale),
                TodayDialReadoutRules.steps(inputs.steps, locale: locale)
            ]
        }

        var absentLayers: [TodayDialLayerID] = []
        if sleep.absence != nil { absentLayers.append(.sleep) }
        if eating.absence != nil { absentLayers.append(.eating) }
        if training.absence != nil { absentLayers.append(.training) }
        if daylight.absence != nil { absentLayers.append(.daylight) }
        let nothingToday = absentLayers.count == TodayDialLayerID.allCases.count && beads.isEmpty && bedtime == nil
            && readouts.allSatisfy { $0.text == nil }
        render = Self.render(absentLayers: absentLayers, nightsMeasured: nightsMeasured, nothingToday: nothingToday,
                             learns: isToday || inputs.lastNight != nil)

        accessibilitySummary = TodayDialSpoken.summary(
            mode: mode, centre: centre, eating: eating, training: training, daylight: daylight, beads: beads,
            alarm: alarm, clock: clock, locale: locale)
    }

    /// The hand's angle at another instant, so a view can move the hand between rebuilds.
    public func handAngle(at date: Date) -> Double? {
        clock.contains(date) ? clock.angle(of: date) : nil
    }

    // MARK: Render state

    /// - Parameter learns: false for a past day without a night. Its dial says the night is missing; a "so far" count
    ///   about nights to come does not belong to a day that is over.
    static func render(absentLayers: [TodayDialLayerID], nightsMeasured: Int, nothingToday: Bool,
                       learns: Bool = true) -> TodayDialRenderState {
        let need = TodayDialRenderState.nightsNeeded
        if nothingToday, nightsMeasured == 0 {
            return TodayDialRenderState(kind: .empty, absentLayers: absentLayers, nightsMeasured: 0,
                message: "Nothing recorded yet. Sleep, meals, training and daylight land on this dial as they come in.")
        }
        if nightsMeasured < need, learns {
            let sofar = nightsMeasured == 0 ? "None yet." : nightsMeasured == 1 ? "1 so far." : "\(nightsMeasured) so far."
            return TodayDialRenderState(kind: .learning, absentLayers: absentLayers, nightsMeasured: nightsMeasured,
                                        message: "Your usual and regularity show after \(need) nights. \(sofar)")
        }
        return TodayDialRenderState(kind: absentLayers.isEmpty ? .complete : .partial, absentLayers: absentLayers,
                                    nightsMeasured: nightsMeasured, message: nil)
    }

    // MARK: Sleep

    static func hypnogram(_ night: TodayDialNightInput?, clock: TodayDialClock) -> TodayDialHypnogram? {
        guard let night, night.end > night.start, let arc = clock.arc(from: night.start, to: night.end) else { return nil }
        let spans = night.spans.sorted { $0.start < $1.start }.compactMap { span -> TodayDialStageSpan? in
            guard span.end > span.start, let arc = clock.arc(from: span.start, to: span.end) else { return nil }
            return TodayDialStageSpan(id: span.id, stage: span.stage, arc: arc, radius: TodayDialGeometry.sleepRadius,
                                      width: TodayDialGeometry.stageWidth(span.stage))
        }
        let counted = night.asleepMinutes.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let fromSpans = spans.isEmpty ? nil : LooprStageTimelineModel(spans: night.spans, timeZone: clock.timeZone).asleepMinutes
        return TodayDialHypnogram(night: arc, spans: spans, asleepMinutes: counted ?? fromSpans, isPartial: night.isPartial,
                                  provenance: night.provenance)
    }

    /// The protocol's bedtime first, then Sleep's plan. A time before noon is after midnight, so it is tomorrow.
    static func bedtime(rules: [TodayDialRule], tonight: TodayDialTonightInput?, clock: TodayDialClock) -> TodayDialBedtime? {
        let candidates = rules.filter { $0.role == .bedtime && $0.limitMinute != nil }
        let rule = candidates.first { $0.metric == TodayDialRule.Metric.inBed } ?? candidates.first
        if let rule, let minute = rule.limitMinute, let at = nightDate(minute, clock: clock) {
            return TodayDialBedtime(at: at, angle: clock.angle(of: at), source: .rule(key: rule.input.key, state: rule.input.state),
                                    provenance: .onThisPhone, qualifier: "Your protocol")
        }
        if let tonight, let at = nightDate(tonight.bedtimeMinuteOfDay, clock: clock) {
            return TodayDialBedtime(at: at, angle: clock.angle(of: at), source: .sleepPlan, provenance: .onThisPhone,
                                    qualifier: "Sleep plan")
        }
        return nil
    }

    static func tonight(_ bedtime: TodayDialBedtime, rules: [TodayDialRule], inputs: TodayDialInputs,
                        clock: TodayDialClock) -> TodayDialTonight {
        var wake: (Date, TodayDialWakeSource)?
        if let alarm = inputs.alarm, alarm.ringsTomorrow, let at = clock.date(minuteOfDay: alarm.wakeMinuteOfDay, dayOffset: 1) {
            wake = (at, .alarm)
        } else if let plan = inputs.tonight {
            if let minute = plan.wakeMinuteOfDay, let at = clock.date(minuteOfDay: minute, dayOffset: 1) {
                wake = (at, .sleepPlan)
            } else if let sleep = plan.sleepMinutes, sleep.isFinite, sleep > 0 {
                wake = (bedtime.at.addingTimeInterval(sleep * 60), .sleepPlan)
            }
        }
        if let current = wake, current.0 <= bedtime.at { wake = nil }

        let windDownStart = rules
            .filter { $0.role == .routine && $0.input.isEvening }
            .compactMap { $0.limitMinute.flatMap { nightDate($0, clock: clock) } }
            .filter { $0 < bedtime.at && bedtime.at.timeIntervalSince($0) <= windDownLookback }
            .max()
        let label = bedtime.at.addingTimeInterval(TodayDialGeometry.tonightLabelMinutesAfterBedtime * 60)
        return TodayDialTonight(bedtime: bedtime, window: wake.flatMap { clock.arc(from: bedtime.at, to: $0.0) }, wakeSource: wake?.1,
                                windDown: windDownStart.flatMap { clock.arc(from: $0, to: bedtime.at) },
                                labelAngle: clock.angle(of: label))
    }

    /// Evening rules this close before bed open the wind-down arc.
    static let windDownLookback: TimeInterval = 3 * 3_600

    /// A night-time minute on this dial's evening: before noon means after midnight.
    static func nightDate(_ minute: Int, clock: TodayDialClock) -> Date? {
        clock.date(minuteOfDay: minute, dayOffset: minute % 1_440 < 720 || minute >= 1_440 ? 1 : 0)
    }

    static func minutesAfterNoon(_ minute: Int) -> Double {
        Double(((minute % 1_440) - 720 + 1_440) % 1_440)
    }

    // MARK: Eating

    static func eating(_ inputs: [TodayDialMealInput], rules: [TodayDialRule], clock: TodayDialClock) -> TodayDialLayer<TodayDialEating> {
        let meals = inputs.filter { clock.contains($0.at) }.sorted { $0.at < $1.at }.map { meal in
            TodayDialMeal(id: meal.id, title: meal.title, at: meal.at, angle: clock.angle(of: meal.at),
                          radius: TodayDialGeometry.eatingRadius, sticker: meal.sticker, provenance: meal.provenance,
                          nutrition: meal.nutrition)
        }
        guard let first = meals.first, let last = meals.last, let window = clock.arc(from: first.at, to: last.at) else {
            return .absent(TodayDialAbsence(gap: .noData, message: "No meals logged today. Log one and it lands on the dial."))
        }
        let closes = rules.first { $0.role == .kitchenCloses }?.limitMinute
            .flatMap { clock.date(minuteOfDay: $0, dayOffset: $0 >= 1_440 ? 1 : 0) }
        let planned = closes.flatMap { $0 > first.at ? clock.arc(from: first.at, to: $0) : nil }
        return .present(TodayDialEating(meals: meals, window: window, planned: planned))
    }

    // MARK: Training

    /// A planned block is done once a workout runs within this long of it.
    static let plannedMatchWindow: TimeInterval = 60 * 60

    static func training(_ workouts: [TodayDialWorkoutInput], planned: [TodayDialPlannedSessionInput], rules: [TodayDialRule],
                         now: Date, clock: TodayDialClock) -> TodayDialLayer<[TodayDialTrainingBlock]> {
        var blocks: [TodayDialTrainingBlock] = workouts.compactMap { workout -> TodayDialTrainingBlock? in
            let end = workout.end ?? max(workout.start, min(now, clock.end))
            guard workout.start < clock.end, end > clock.start, let arc = clock.arc(from: workout.start, to: end) else { return nil }
            return TodayDialTrainingBlock(id: workout.id, title: workout.title, arc: arc, isPlanned: false,
                                          isOngoing: workout.end == nil, ruleState: nil, provenance: workout.provenance)
        }
        let done = blocks.map { ($0.arc.start, $0.arc.end) }
        func plannedBlock(id: String, title: String, minute: Int, duration: Double?, state: TodayDialRuleState?) -> TodayDialTrainingBlock? {
            guard let start = clock.date(minuteOfDay: minute) else { return nil }
            let end = start.addingTimeInterval(max(0, duration.flatMap { $0.isFinite ? $0 : nil } ?? 0) * 60)
            let matched = done.contains { $0.0 < end.addingTimeInterval(plannedMatchWindow) && $0.1 > start.addingTimeInterval(-plannedMatchWindow) }
            guard !matched, let arc = clock.arc(from: start, to: end) else { return nil }
            return TodayDialTrainingBlock(id: id, title: title, arc: arc, isPlanned: true, isOngoing: false, ruleState: state,
                                          provenance: .onThisPhone)
        }
        for rule in rules where rule.role == .training {
            guard let minute = rule.limitMinute else { continue }
            let duration = TodayDialRule.Metric.minuteTargets.contains(rule.metric ?? "") ? rule.input.targetValue : nil
            if let block = plannedBlock(id: "rule-\(rule.input.key)", title: rule.input.title, minute: minute, duration: duration,
                                        state: rule.input.state) { blocks.append(block) }
        }
        for session in planned {
            if let block = plannedBlock(id: "plan-\(session.id)", title: session.title, minute: session.startMinuteOfDay,
                                        duration: session.durationMinutes, state: nil) { blocks.append(block) }
        }
        guard !blocks.isEmpty else {
            return .absent(TodayDialAbsence(gap: .noData, message: "No training logged today."))
        }
        return .present(blocks.sorted { $0.arc.start < $1.arc.start })
    }

    // MARK: Daylight

    /// The daytime rim a daily total spreads over.
    static let daylightSpreadStartMinute = 6 * 60
    static let daylightSpreadEndMinute = 18 * 60

    static func daylight(_ input: TodayDialDaylightInput, now: Date, isToday: Bool, clock: TodayDialClock) -> TodayDialLayer<TodayDialDaylight> {
        switch input {
        case .missing(let gap):
            return .absent(TodayDialAbsence(gap: gap, message: daylightMessage(gap, isToday: isToday)))
        case .intervals(let intervals, let provenance):
            let limit = isToday ? min(now, clock.end) : clock.end
            var angles: [Double] = []
            var minutes = 0.0
            let step = TodayDialGeometry.daylightMinutesPerTimedDot * 60
            for interval in intervals.sorted(by: { $0.start < $1.start }) {
                let start = max(interval.start, clock.start), end = min(interval.end, limit)
                guard end >= start else { continue }
                minutes += end.timeIntervalSince(start) / 60
                var cursor = start
                while cursor <= end, angles.count < TodayDialGeometry.maximumDaylightDots {
                    angles.append(clock.angle(of: cursor))
                    cursor = cursor.addingTimeInterval(step)
                }
            }
            guard !angles.isEmpty else { return .absent(TodayDialAbsence(gap: .noData, message: daylightMessage(.noData, isToday: isToday))) }
            return .present(TodayDialDaylight(minutes: minutes, placement: .atTimes, dotAngles: angles, provenance: provenance))
        case .dailyTotal(let minutes, let provenance):
            guard minutes.isFinite, minutes >= 0 else {
                return .absent(TodayDialAbsence(gap: .noData, message: daylightMessage(.noData, isToday: isToday)))
            }
            let start = Double(daylightSpreadStartMinute)
            let nowMinute = isToday ? clock.dialMinutes(of: now) : Double(daylightSpreadEndMinute)
            let end = min(Double(daylightSpreadEndMinute), max(start + minutes, min(nowMinute, Double(daylightSpreadEndMinute))))
            let per = TodayDialGeometry.daylightMinutesPerSpreadDot
            let room = Int(((end - start) / per).rounded(.down))
            let count = min(Int((minutes / per).rounded(.up)), max(room, minutes > 0 ? 1 : 0), TodayDialGeometry.maximumDaylightDots)
            let spacing = count > 0 ? (end - start) / Double(count) : 0
            let angles = (0..<max(count, 0)).map { TodayDialGeometry.angle(minuteOfDay: start + (Double($0) + 0.5) * spacing) }
            return .present(TodayDialDaylight(minutes: minutes, placement: .spreadAcrossDay, dotAngles: angles, provenance: provenance))
        }
    }

    /// A past day's gap line says "on this day", not "today".
    static func onThisDay<Value: Equatable & Sendable>(_ layer: TodayDialLayer<Value>, isToday: Bool) -> TodayDialLayer<Value> {
        guard !isToday, case .absent(let absence) = layer else { return layer }
        let message: String
        switch absence.message {
        case "No meals logged today. Log one and it lands on the dial.": message = "No meals logged on this day."
        case "No training logged today.": message = "No training logged on this day."
        default: return layer
        }
        return .absent(TodayDialAbsence(gap: absence.gap, message: message))
    }

    /// The sleep layer's sentence on a past day the band has no night for.
    static let pastDayNoNightMessage = "The band has no night for this day. It fills in if the band syncs one later."

    static func daylightMessage(_ gap: TodayDialGap, isToday: Bool = true) -> String {
        switch gap {
        case .noData: isToday ? "No time in daylight from Apple Health today." : "No time in daylight from Apple Health on this day."
        case .switchedOff: "Time in daylight is switched off in Settings."
        case .notAllowed: "Allow time in daylight in Apple Health to see it here."
        case .unavailable: "Time in daylight comes from Apple Health, which this iPhone does not have."
        }
    }

    // MARK: Beads

    static func beads(_ rules: [TodayDialRule], clock: TodayDialClock) -> [TodayDialBead] {
        rules.compactMap { rule -> TodayDialBead? in
            guard let minute = rule.limitMinute else { return nil }
            let kind: TodayDialBeadKind
            switch rule.role {
            case .kitchenCloses: kind = .kitchenCloses
            case .routine: kind = .routine
            case .bedtime, .training: return nil
            }
            let wrapped = ((minute % 1_440) + 1_440) % 1_440
            return TodayDialBead(id: rule.input.key, title: rule.input.title, kind: kind, minuteOfDay: wrapped,
                                 angle: TodayDialGeometry.angle(minuteOfDay: Double(wrapped)),
                                 radius: kind == .kitchenCloses ? TodayDialGeometry.eatingRadius : TodayDialGeometry.rimRadius,
                                 size: kind == .kitchenCloses ? TodayDialGeometry.kitchenBeadRadius : TodayDialGeometry.ruleBeadRadius,
                                 state: rule.input.state, isEvening: rule.input.isEvening, source: rule.input.source)
        }.sorted { ($0.minuteOfDay, $0.id) < ($1.minuteOfDay, $1.id) }
    }

    // MARK: Alarm

    /// This morning's alarm until it rings, then tomorrow's.
    static func alarm(_ input: TodayDialAlarmInput?, mode: TodayDialMode, now: Date, clock: TodayDialClock) -> TodayDialAlarmBead? {
        guard let input else { return nil }
        var choice: (Date, Bool)?
        if mode == .morning, input.ringsToday, let today = clock.date(minuteOfDay: input.wakeMinuteOfDay), now < today {
            choice = (today, false)
        } else if input.ringsTomorrow, let tomorrow = clock.date(minuteOfDay: input.wakeMinuteOfDay, dayOffset: 1) {
            choice = (tomorrow, true)
        }
        guard let choice else { return nil }
        let (wake, isTomorrow) = choice
        let window = input.smartWindowMinutes > 0
            ? clock.arc(from: wake.addingTimeInterval(-Double(input.smartWindowMinutes) * 60), to: wake) : nil
        return TodayDialAlarmBead(wake: wake, angle: clock.angle(of: wake), radius: TodayDialGeometry.sleepRadius,
                                  smartWindow: window, isTomorrow: isTomorrow)
    }
}

/// A protocol rule and the part of the dial it belongs to.
struct TodayDialRule: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        /// In bed or asleep by: the bedtime gem.
        case bedtime
        /// Last meal by: the kitchen-closes bead on the eating ring.
        case kitchenCloses
        /// Zone 2, hard minutes, workout minutes, strength or mobility: a planned training block.
        case training
        /// Anything else with a time: a bead on the rim.
        case routine
    }

    /// RoutineKit's metric names (`RoutineMetric.rawValue`).
    enum Metric {
        static let inBed = "in_bed_time"
        static let sleepOnset = "sleep_onset_time"
        static let lastMeal = "last_meal_time"
        static let lastCaffeine = "last_caffeine_time"
        static let zone2 = "zone2_minutes"
        static let zone45 = "zone45_minutes"
        static let workoutMinutes = "workout_minutes"
        static let strength = "strength_sessions"
        static let mobility = "mobility_sessions"

        /// Metrics measured as a time of day, whose target is the limit.
        static let timesOfDay: Set<String> = [inBed, sleepOnset, lastMeal, lastCaffeine]
        static let training: Set<String> = [zone2, zone45, workoutMinutes, strength, mobility]
        /// Training metrics whose target is a number of minutes, which gives a planned block its length.
        static let minuteTargets: Set<String> = [zone2, zone45, workoutMinutes]
    }

    let input: TodayDialRuleInput

    init(_ input: TodayDialRuleInput) { self.input = input }

    var metric: String? { input.metric }

    var role: Role {
        guard let metric else { return .routine }
        if metric == Metric.inBed || metric == Metric.sleepOnset { return .bedtime }
        if metric == Metric.lastMeal { return .kitchenCloses }
        if Metric.training.contains(metric) { return .training }
        return .routine
    }

    /// Where the rule sits on the clock, in minutes after the day's midnight. A time-of-day metric sits at its limit
    /// ("last meal by 18:30" at 18:30), because that is what decides it (`RuleEvaluator`); any other rule sits at its
    /// reminder time. 1440 and above is after midnight.
    var limitMinute: Int? {
        if let metric, Metric.timesOfDay.contains(metric), let target = input.targetValue, target.isFinite, target >= 0,
           target < 2_880 {
            return Int(target.rounded(.down))
        }
        guard let time = input.timeOfDayMinutes, (0..<1_440).contains(time) else { return nil }
        return time
    }
}
