import AnalyticsKit
import DomainKit
import Foundation

// LV-06.2: what the Fitness tab's signature objects show, built from plain values. The app loads the
// band days, sessions, Apple Health readings, profile, protocol rules and capacity results; this file
// only arranges them and writes the words. Missing data stays missing: a week without band data says
// so and never draws zero dots.

/// Where the VO2 max readings came from, or why there are none.
public enum FitnessVO2MaxSource: Equatable, Sendable {
    /// Readings Loopr read, possibly none.
    case readings([VO2MaxReading])
    /// The person switched the Apple Health VO2 max read off in Loopr.
    case switchedOff
    /// This device has no Apple Health, or Loopr could not read it.
    case unavailable
}

/// Everything the Fitness signature objects read.
public struct FitnessOverviewInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// Band zone minutes for the days of the week, in any order.
    public var doseDays: [DoseDay]
    /// Completed sessions. Gym sessions and their workout records share an id and count once.
    public var sessions: [DoseSession]
    public var targets: DoseTargets
    public var vo2Max: FitnessVO2MaxSource
    public var birthYear: Int?
    /// The reference curve the person chose. Nil when they chose none.
    public var referenceGroup: FriendReferenceGroup?
    public var capacityResults: [CapacityResult]
    public var capacityGoals: [CapacityTestKind: CapacityGoal]
    public var capacityCadences: [CapacityTestKind: CapacityCadence]
    /// Today's heart rate zones, the ones the dose's minutes are worked out with. Nil without a maximum heart rate.
    public var heartRateZones: HeartRateZones?
    /// The week's sessions with their names and what their heart rate gave, for the day list (R2-VET-03).
    public var daySessions: [FitnessDaySession]

    public init(now: Date, calendar: Calendar, doseDays: [DoseDay] = [], sessions: [DoseSession] = [],
                targets: DoseTargets = .none, vo2Max: FitnessVO2MaxSource = .readings([]), birthYear: Int? = nil,
                referenceGroup: FriendReferenceGroup? = nil, capacityResults: [CapacityResult] = [],
                capacityGoals: [CapacityTestKind: CapacityGoal] = [:],
                capacityCadences: [CapacityTestKind: CapacityCadence] = [:],
                heartRateZones: HeartRateZones? = nil, daySessions: [FitnessDaySession] = []) {
        self.now = now; self.calendar = calendar; self.doseDays = doseDays; self.sessions = sessions
        self.targets = targets; self.vo2Max = vo2Max; self.birthYear = birthYear; self.referenceGroup = referenceGroup
        self.capacityResults = capacityResults; self.capacityGoals = capacityGoals; self.capacityCadences = capacityCadences
        self.heartRateZones = heartRateZones; self.daySessions = daySessions
    }

    /// Whole years since the birth year, as the Body tab counts them. Nil outside 1 to 120.
    public var age: Int? {
        guard let birthYear else { return nil }
        let age = calendar.component(.year, from: now) - birthYear
        return (1...120).contains(age) ? age : nil
    }

    /// The profile keeps a birth year only, so the 85th birthday is placed mid-year.
    public var approximateDateOfBirth: Date? {
        birthYear.flatMap { calendar.date(from: DateComponents(year: $0, month: 7, day: 1)) }
    }
}

// MARK: - Dose

/// One minutes row: zone 2 or the hard minutes.
public struct FitnessDoseMinutesRow: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The band has no zone data for any day of the week.
        case absent
        case dots(DoseDots)
    }

    public let title: String
    public let state: State
    /// Whole minutes measured. Nil when absent.
    public let minutes: Int?
    /// The words after the number, such as " of 180 min" or " min · no target". "Target 180 min" or
    /// "Not measured" when absent.
    public let suffix: String
    public let spokenLabel: String
    /// A few words beside the title, "easy cardio" (R1-VET-11, R1-NEW-04).
    public var caption: String?
    /// The one line under the row on what counts.
    public var counts: String = ""
    /// The weekly target in whole minutes. Nil without one.
    public var target: Int?
    /// Hollow dots to draw while absent: the target's dots, so the row keeps its shape. Nil without a target.
    public var targetDots: Int? { target.map { DoseDots(minutes: 0, target: Double($0)).total ?? 0 } }
}

/// One sessions row: strength or mobility and balance.
public struct FitnessDoseSessionsRow: Equatable, Sendable {
    public let title: String
    public let count: Int
    public let target: Int?
    /// " of 3", " · no target", "None yet · no target".
    public let suffix: String
    public let spokenLabel: String
    /// The one line under the row on what counts.
    public var counts: String = ""
    /// Targets still to go, drawn as empty outlines.
    public var remaining: Int { max((target ?? 0) - count, 0) }
    /// The number to draw. Nil for no sessions and no target, where the suffix says "None yet" instead of a bare 0.
    public var shownCount: Int? { count == 0 && target == nil ? nil : count }
}

public struct FitnessDose: Equatable, Sendable {
    public static let title = "This week's training"
    public static let scale = "1 dot is 5 minutes"
    public static let absentSentence = "Zone minutes come from a band. There are none this week yet."
    public static let absentCount = "Not measured"
    /// Under the field when any target is set. Every dose target is a Protocol rule (`DoseTargets(rules:)`).
    public static let targetsFromProtocol = "Targets from your protocol."
    public static let noTargets = "No weekly targets set. They come from rules in Protocol."
    /// The empty field's offer (R2-NEW-06, R2-DES-09): the starter week as hollow targets, labelled for what it is.
    public static let starterTitle = "A starter week"
    public static let starterNote = "150 Zone 2 minutes, 2 strength and 2 mobility sessions. A common starting point, not a prescription."
    public static let starterUse = "Use this week"
    public static let openProtocol = "Set your week in Protocol"

    /// The sentence naming where the zone minutes came from.
    public static func minutesSource(_ source: DoseZoneMinutesSource) -> String {
        switch source {
        case .band: "Minutes from the band."
        case .appleHealth: "Minutes from Apple Health workouts."
        case .bandAndAppleHealth: "Minutes from the band and Apple Health workouts."
        }
    }
    /// The verdict for a week with nothing logged, no band minutes and no targets (R1-DES-18).
    public static let blank = "Log a session and its minutes land here."

    public static let zone2Counts = "Minutes in zone 2 during any activity."
    public static let hardCounts = "Minutes in zones 4 and 5 during any activity."
    public static let strengthCounts = "Gym sessions and WODs count."
    public static let mobilityCounts = "Yoga, Pilates, stretching and mobility count."

    /// `2023-W46`, the key the shown counts are kept under.
    public let weekKey: String
    public let zone2: FitnessDoseMinutesRow
    public let hard: FitnessDoseMinutesRow
    public let strength: FitnessDoseSessionsRow
    public let mobility: FitnessDoseSessionsRow
    /// The absent sentence when the band has no data this week.
    public let bandAbsence: String?
    /// A sentence when the band missed past days this week, so the minutes could be higher.
    public let coverageNote: String?
    /// One line above the rows on how the week is going (R1-NEW-05): "Three of four on track. Mobility is still
    /// open." Nil when no row has both a target and a reading.
    public var verdict: String?
    /// Where the targets come from, or that there are none.
    public var targetSource: String = FitnessDose.noTargets
    /// Where the zone minutes came from (R1-VET-02): "Minutes from the band and Apple Health workouts." Nil when
    /// no day has zone minutes.
    public var minutesSource: String?
    /// What Zone 2 is and where the maximum heart rate came from (R2-VET-02), under the title.
    public var zoneLine: String = FitnessZoneLine.unset
    /// What "on pace" means and what each row counts, behind the info button (R2-DES-07).
    public var basis = FitnessDoseBasis(paceLine: nil, definitions: [])
    /// The week's days up to today, newest first, behind a tap on a minutes row (R2-VET-03).
    public var days: [FitnessDoseDayRow] = []
    /// True while the protocol sets no dose target: the field offers the starter week (R2-NEW-06).
    public var offersStarterWeek = false
    /// Hard minutes show once they have a target or a reading (R2-NEW-06).
    public var showsHardMinutes = true

    /// Today's row of the day list.
    public var today: FitnessDoseDayRow? { days.first { $0.title == "Today" } }

    /// No target, no minutes and no session: a new person. The tab leads with the start rail (R2-DES-09).
    public var isBlank: Bool {
        offersStarterWeek && zone2.minutes == nil && hard.minutes == nil && strength.count == 0 && mobility.count == 0
    }

    /// The dot counts on screen, for the flight bookkeeping. Nil when the band has no data.
    public var shown: FitnessDoseShown? {
        guard case .dots(let zone2) = zone2.state, case .dots(let hard) = hard.state else { return nil }
        return FitnessDoseShown(zone2: zone2.filled, hard: hard.filled)
    }

    /// What VoiceOver reads for the whole field.
    public var spokenSummary: String {
        var parts = [Self.title + "."] + [verdict].compactMap { $0 }
            + [zone2.spokenLabel + ".", hard.spokenLabel + ".", strength.spokenLabel + ".", mobility.spokenLabel + "."]
        if let bandAbsence { parts.append(bandAbsence) }
        if let coverageNote { parts.append(coverageNote) }
        if let minutesSource { parts.append(minutesSource) }
        return parts.joined(separator: " ")
    }
}

// MARK: - VO2 max

public struct FitnessAgeBar: Equatable, Sendable {
    public let realAge: Int
    /// The Cardio Age from `CardioAgeCalculator`. Nil when it is unavailable.
    public let cardioAge: Double?
    public let cardioLabel: String?
    public let axisLower: Int
    public let axisUpper: Int

    /// "Real age 38", on a ruler whose unit is years.
    public var realLabel: String { "Real age \(realAge)" }
    /// "Cardio age 32", or "Cardio age 25 or younger" at the ends of the reference curve. Nil when unavailable.
    public var cardioPinLabel: String? { cardioLabel.map { "Cardio age \($0)" } }
    /// What the ruler measures.
    public static let unitCaption = "Ages, in years"

    /// Where an age sits along the axis, 0 to 1.
    public func fraction(for age: Double) -> Double {
        min(max((age - Double(axisLower)) / Double(max(axisUpper - axisLower, 1)), 0), 1)
    }

    /// The labelled ages under the axis.
    public var axisLabels: [Int] { Array(stride(from: axisLower, through: axisUpper, by: 10)) }

    public var spokenLabel: String {
        if let cardioLabel { return "Your age \(realAge) years. Cardio Age \(cardioLabel) years." }
        return "Your age \(realAge). Cardio Age is not available."
    }

    /// The axis spans 40 years from the decade at least ten years below both pins.
    public static func make(realAge: Int, cardio: CardioAgeResult?) -> FitnessAgeBar {
        let cardioAge = cardio.flatMap { $0.status == .available ? $0.ageYears : nil }.flatMap { $0.isFinite ? $0 : nil }
        let label: String? = cardioAge.map { age in
            if let display = cardio?.displayLabel { return display }
            return String(Int(age.rounded()))
        }
        let low = min(Double(realAge), cardioAge ?? Double(realAge)) - 10
        let high = max(Double(realAge), cardioAge ?? Double(realAge)) + 5
        let lower = max(20, Int((low / 10).rounded(.down)) * 10)
        let upper = max(lower + 40, Int((high / 10).rounded(.up)) * 10)
        return FitnessAgeBar(realAge: realAge, cardioAge: cardioAge, cardioLabel: label, axisLower: lower, axisUpper: upper)
    }
}

public struct FitnessGaugeReading: Equatable, Sendable {
    public let gauge: VO2MaxGauge
    public let scale: VO2MaxGaugeScale
    public let boundaries: [VO2MaxGaugeBoundary]
    /// "44.1"
    public let valueText: String
    /// "ml/kg/min"
    public let unitLine: String
    /// "Top half for men aged 30 to 39": the band, and whose reference it is read against.
    public let bandLine: String
    /// The change over 12 months and what the faint needle is, then the caveat for watch estimates.
    public let note: String
    /// "Apple Watch"
    public let sourceLabel: String
    public let ageBar: FitnessAgeBar?

    public static let qualifier = "42-day median"
    public static let unit = "ml/kg/min"

    public var spokenLabel: String {
        "VO₂max \(valueText) \(Self.unit). \(bandLine). \(note)"
    }
}

public enum FitnessVO2Max: Equatable, Sendable {
    case gauge(FitnessGaugeReading)
    /// The gauge's shape with a sentence saying what is missing and how it fills in.
    case absent(String)

    public static let needsAge = "Add your birth year in your profile to see where your VO₂max sits for your age."
    public static let needsReferenceGroup = "Pick the female or male reference curve in your profile to see the bands for your age."
    public static let unsupportedAge = "The published bands cover ages 20 to 79, so the gauge has no bands for your age."
    public static let notEnoughSamples = "Loopr needs 3 VO₂max readings on different days, at least 2 weeks apart, within 6 weeks. Apple Watch records one on outdoor walks, runs and hikes."
    public static let switchedOff = "Reading VO₂max from Apple Health is off. Turn it on in Settings, Apple Health."
    public static let unavailable = "Apple Health is not available on this iPhone, so there is no VO₂max to show."

    public static func sentence(for absence: VO2MaxGaugeAbsence) -> String {
        switch absence {
        case .needsAge: needsAge
        case .needsReferenceGroup: needsReferenceGroup
        case .unsupportedAge: unsupportedAge
        case .notEnoughSamples: notEnoughSamples
        }
    }
}

// MARK: - Capacity

public struct FitnessCapacityHistoryRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// "24 Oct 2026"
    public let dateText: String
    /// "52 kg", "1:24", "9.5/10"
    public let valueText: String
    /// "Right hand", "Left leg"
    public let sideText: String?
    /// "Typed in", "Timed on this iPhone", "From a workout"
    public let sourceText: String
}

public struct FitnessCapacityTile: Equatable, Sendable, Identifiable {
    public let kind: CapacityTestKind
    public var id: String { kind.rawValue }
    public var title: String { kind.title }
    /// "52", "1:24", "10". Nil before the first test.
    public let valueText: String?
    /// "kg", "/10", "s". Nil for dead hang, which reads as minutes and seconds.
    public let unitText: String?
    /// "Retest 2 Nov", "Test due". Nil when the protocol has no rule for this test.
    public let retestLine: String?
    /// True only when today's best is under the person's own goal for 85. Never a clinical judgement.
    public let isBelowGoal: Bool
    /// The instrument's fill, 0 to 1. Nil before the first test.
    public let fraction: Double?
    /// The goal for 85 on the same scale, for a marker. Nil without a goal.
    public let goalFraction: Double?
    public let history: [FitnessCapacityHistoryRow]
    /// Today's best as a number, for the count-up when a new result lands. Nil before the first test.
    public let bestValue: Double?
    /// The person's goal for 85, in the test's unit. Nil without one.
    public let goalValue: Double?
    /// The straight line from today's best to the goal on the 85th birthday. Nil without a best, a goal
    /// or a birth year.
    public let trajectory: CapacityTrajectory?
    /// False when the profile has no birth year, so no line to 85 can be drawn.
    public let knowsBirthYear: Bool
    /// "From a workout on 13 Nov", for heart rate recovery. Nil for the other tests.
    public let sourceLine: String?
    /// Where the best sits among people of the same age and sex in a published study, with the study named
    /// (R2-VET-06). Nil for heart rate recovery.
    public var norm: CapacityNorm?

    public static let notTested = "Not tested"
    /// Said when today's best is under the goal the person set for when they are 85.
    public static let belowGoal = "Under the goal you set for age 85"

    /// The result before the newest, "Was 10/10", so a lower score is not a silent change (R2-OPT-19). Only for tests
    /// with one result a session; grip and balance keep a result for each side.
    public var previousLine: String? {
        guard valueText != nil, history.count >= 2, history[0].sideText == nil, history[1].sideText == nil,
              kind != .heartRateRecovery else { return nil }
        return "Was \(history[1].valueText)"
    }

    /// The tile's line under a best that is short of the goal: whose goal it is and the number, so "85" never reads as
    /// the person's age or a norm for 85-year-olds (R2-OPT-17). "Your goal at 85: 30 s".
    public var belowGoalLine: String? {
        guard isBelowGoal, let goalValue else { return nil }
        let unit = FitnessOverview.unitText(kind).map { $0 == "/10" ? $0 : " \($0)" } ?? ""
        return "Your goal at 85: \(FitnessOverview.valueText(kind, goalValue))\(unit)"
    }

    /// What a tile with no result says. A test the person can do reads as an invitation, one they cannot
    /// do (heart rate recovery) says where its number comes from.
    public var untestedLine: String {
        switch kind {
        case .sitToStand, .oneLegBalance: "Try it · about 2 min"
        case .grip: "Needs a dynamometer"
        case .deadHang: "Needs a bar"
        case .heartRateRecovery: "Not read yet"
        }
    }

    /// The second line under an untested tile.
    public var untestedDetail: String? {
        switch kind {
        case .sitToStand, .oneLegBalance: "No gear needed"
        case .heartRateRecovery: "Appears after a workout with heart rate."
        case .grip, .deadHang: nil
        }
    }

    /// True for a test anyone can start now: it needs no gear.
    public var isInvitation: Bool { valueText == nil && (kind == .sitToStand || kind == .oneLegBalance) }

    public var spokenLabel: String {
        var parts = [title]
        if let valueText { parts.append(unitText.map { "\(valueText) \(Self.spokenUnit($0))" } ?? Self.spokenClock(valueText)) }
        else { parts.append([untestedLine, untestedDetail].compactMap { $0 }.joined(separator: ". ")) }
        if isBelowGoal {
            let goal = goalValue.map { value in
                unitText.map { "\(FitnessOverview.valueText(kind, value)) \(Self.spokenUnit($0))" }
                    ?? Self.spokenClock(FitnessOverview.valueText(kind, value))
            }
            parts.append(goal.map { "\(Self.belowGoal), \($0)" } ?? Self.belowGoal)
        }
        if let retestLine { parts.append(retestLine) }
        if let sourceLine { parts.append(sourceLine) }
        return parts.joined(separator: ", ")
    }

    private static func spokenUnit(_ unit: String) -> String {
        switch unit {
        case "kg": "kilograms"
        case "s": "seconds"
        case "/10": "out of 10"
        case "bpm": "beats a minute"
        default: unit
        }
    }

    /// "1:24" read as "1 minute 24 seconds".
    private static func spokenClock(_ text: String) -> String {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return text }
        let minutes = parts[0] == 1 ? "1 minute" : "\(parts[0]) minutes"
        let seconds = parts[1] == 1 ? "1 second" : "\(parts[1]) seconds"
        return parts[0] == 0 ? seconds : parts[1] == 0 ? minutes : "\(minutes) \(seconds)"
    }
}

// MARK: - Overview

public struct FitnessOverview: Equatable, Sendable {
    public let week: ISOWeek
    /// "6 days left this week" (R1-NEW-13)
    public let meta: String
    public let dose: FitnessDose
    public let vo2Max: FitnessVO2Max
    /// Where the person stands on VO₂max readings while there are too few for the gauge. Nil once the rule is met, and
    /// while Apple Health is off or missing, since then no reading can arrive.
    public let vo2MaxProgress: VO2MaxReadingProgress?
    /// Grip, dead hang, sit to stand and one-leg balance, in that order.
    public let capacity: [FitnessCapacityTile]
    /// Heart rate recovery from the latest scored workout. Read only.
    public let heartRateRecovery: FitnessCapacityTile

    /// The tile for one test, heart rate recovery included.
    public func tile(_ kind: CapacityTestKind) -> FitnessCapacityTile? {
        kind == .heartRateRecovery ? heartRateRecovery : capacity.first { $0.kind == kind }
    }

    /// The line above the capacity tiles while none has a result.
    public static let capacityIntro = "Sit to stand and one-leg balance take about two minutes and need no gear. Grip needs a dynamometer, dead hang a bar."

    /// The four tests the tab draws as instruments. Heart rate recovery lives with workouts.
    public static let capacityKinds: [CapacityTestKind] = [.grip, .deadHang, .sitToStand, .oneLegBalance]

    /// Nil only when the calendar cannot place `now`.
    public static func make(_ input: FitnessOverviewInput) -> FitnessOverview? {
        guard let week = ISOWeek(containing: input.now, calendar: input.calendar) else { return nil }
        let dose = WeeklyDose.make(week: week, days: input.doseDays, sessions: input.sessions, targets: input.targets)
        return FitnessOverview(week: week, meta: meta(week: week, input: input),
                               dose: doseCard(dose, week: week, input: input),
                               vo2Max: vo2Max(input), vo2MaxProgress: vo2MaxProgress(input), capacity: capacity(input),
                               heartRateRecovery: capacityTile(.heartRateRecovery, input))
    }

    // MARK: Meta

    static func meta(week: ISOWeek, input: FitnessOverviewInput) -> String {
        let today = dayIdentity(input.now, calendar: input.calendar)
        let index = week.days.firstIndex(of: today) ?? 0
        let left = week.days.count - index
        // The calendar week number meant nothing to the reviewers (R1-NEW-13).
        return left <= 1 ? "Last day of the week" : "\(left) days left this week"
    }

    static func dayIdentity(_ date: Date, calendar: Calendar) -> DayIdentity {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return DayIdentity(era: parts.era ?? 1, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    // MARK: Dose

    static func doseCard(_ dose: WeeklyDose, week: ISOWeek, input: FitnessOverviewInput) -> FitnessDose {
        let absent = dose.zone2.minutes == nil
        var card = FitnessDose(
            weekKey: FitnessDoseShownStore.key(for: week),
            zone2: minutesRow("Zone 2", dose.zone2, caption: "easy cardio", counts: FitnessDose.zone2Counts),
            hard: minutesRow("Hard minutes", dose.hard, caption: "zones 4 and 5", counts: FitnessDose.hardCounts),
            strength: sessionsRow("Strength sessions", spoken: "Strength", dose.strength, counts: FitnessDose.strengthCounts),
            mobility: sessionsRow("Mobility sessions", spoken: "Mobility", dose.mobility, counts: FitnessDose.mobilityCounts),
            bandAbsence: absent ? FitnessDose.absentSentence : nil,
            coverageNote: absent ? nil : coverageNote(week: week, days: input.doseDays, now: input.now, calendar: input.calendar))
        let today = dayIdentity(input.now, calendar: input.calendar)
        // Today counts: on Tuesday the week is two days in (R2-DES-07).
        let daysIn = (week.days.firstIndex(of: today) ?? 0) + 1
        card.verdict = FitnessDoseVerdict.sentence(dose, daysIn: daysIn, daysInWeek: week.days.count)
        let anyTarget = dose.zone2.target != nil || dose.hard.target != nil || dose.strength.target != nil || dose.mobility.target != nil
        card.targetSource = anyTarget ? FitnessDose.targetsFromProtocol : FitnessDose.noTargets
        card.minutesSource = absent ? nil : dose.zoneMinutesSource.map(FitnessDose.minutesSource)
        card.zoneLine = FitnessZoneLine.text(input.heartRateZones)
        card.basis = FitnessDoseBasis.make(dose, daysIn: daysIn)
        card.days = FitnessDoseDays.rows(week: week, days: input.doseDays, sessions: input.daySessions, now: input.now,
                                         calendar: input.calendar)
        card.offersStarterWeek = !anyTarget
        card.showsHardMinutes = dose.hard.target != nil || dose.hard.minutes != nil
        return card
    }

    static func minutesRow(_ title: String, _ minutes: DoseMinutes, caption: String? = nil, counts: String = "") -> FitnessDoseMinutesRow {
        let target = minutes.target.map { Int($0.rounded()) }
        guard let measured = minutes.minutes, let dots = minutes.dots else {
            // No "Not measured" pill (R1-DES-18): the target's hollow dots keep the row's shape when there is one.
            var row = FitnessDoseMinutesRow(title: title, state: .absent, minutes: nil,
                                            suffix: target.map { "Target \($0) min" } ?? FitnessDose.absentCount,
                                            spokenLabel: target.map { "\(title), not measured, target \($0) minutes" }
                                                ?? "\(title), not measured")
            row.caption = caption; row.counts = counts; row.target = target
            return row
        }
        let whole = Int(measured.rounded(.down))
        let suffix = target.map { " of \($0) min" } ?? " min · no target"
        let spoken = target.map { "\(title), \(whole) of \($0) minutes" } ?? "\(title), \(whole) minutes, no weekly target"
        var row = FitnessDoseMinutesRow(title: title, state: .dots(dots), minutes: whole, suffix: suffix, spokenLabel: spoken)
        row.caption = caption; row.counts = counts; row.target = target
        return row
    }

    /// - Parameters:
    ///   - title: the row's name on screen, "Strength sessions".
    ///   - spoken: the shorter name VoiceOver reads before the count, "Strength, 1 of 3 sessions".
    static func sessionsRow(_ title: String, spoken name: String? = nil, _ sessions: DoseSessions,
                            counts: String = "") -> FitnessDoseSessionsRow {
        let name = name ?? title
        let count = sessions.count
        let suffix: String
        let spoken: String
        if let target = sessions.target {
            let noun = target == 1 ? "session" : "sessions"
            suffix = " of \(target)"
            spoken = "\(name), \(count) of \(target) \(noun)"
        } else if count == 0 {
            suffix = "None yet · no target"
            spoken = "\(name), none yet, no weekly target"
        } else {
            let noun = count == 1 ? "session" : "sessions"
            suffix = " · no target"
            spoken = "\(name), \(count) \(noun), no weekly target"
        }
        var row = FitnessDoseSessionsRow(title: title, count: count, target: sessions.target, suffix: suffix, spokenLabel: spoken)
        row.counts = counts
        return row
    }

    /// Past days of the week without band data. Today is still being measured, so it never counts.
    static func coverageNote(week: ISOWeek, days: [DoseDay], now: Date, calendar: Calendar) -> String? {
        let today = dayIdentity(now, calendar: calendar)
        guard let index = week.days.firstIndex(of: today), index > 0 else { return nil }
        var measured = Set<DayIdentity>()
        var latest: [DayIdentity: DoseDay] = [:]
        for day in days where week.days.contains(day.day) { latest[day.day] = day }
        for (day, entry) in latest where entry.zones != nil { measured.insert(day) }
        let missed = week.days.prefix(index).filter { !measured.contains($0) }.count
        guard missed > 0 else { return nil }
        let days = missed == 1 ? "1 day" : "\(missed) days"
        return "The band missed \(days) this week, so your minutes may be higher."
    }

    // MARK: VO2 max

    static func vo2MaxProgress(_ input: FitnessOverviewInput) -> VO2MaxReadingProgress? {
        guard case .readings(let readings) = input.vo2Max else { return nil }
        let progress = VO2MaxReadingProgress.make(readings: readings, asOf: input.now, calendar: input.calendar)
        return progress.isComplete ? nil : progress
    }

    static func vo2Max(_ input: FitnessOverviewInput) -> FitnessVO2Max {
        let readings: [VO2MaxReading]
        switch input.vo2Max {
        case .readings(let values): readings = values
        case .switchedOff: return .absent(FitnessVO2Max.switchedOff)
        case .unavailable: return .absent(FitnessVO2Max.unavailable)
        }
        let outcome = VO2MaxGauge.make(readings: readings, now: input.now, age: input.age, group: input.referenceGroup,
                                       calendar: input.calendar)
        switch outcome {
        case .absent(let absence):
            return .absent(FitnessVO2Max.sentence(for: absence))
        case .gauge(let gauge):
            let scale = VO2MaxGaugeScale(bands: gauge.bands, including: [gauge.value] + [gauge.lastYearValue].compactMap { $0 })
            let cardio = CardioAgeCalculator().calculate(vo2max: gauge.value, referenceGroup: input.referenceGroup,
                                                         curve: .version1, source: .healthKit, calculationAge: input.age)
            return .gauge(FitnessGaugeReading(
                gauge: gauge, scale: scale, boundaries: VO2MaxGaugeBoundary.boundaries(for: gauge.bands),
                valueText: oneDecimal(gauge.value), unitLine: FitnessGaugeReading.unit,
                bandLine: bandLine(gauge),
                note: gaugeNote(gauge), sourceLabel: gauge.sourceLabels.joined(separator: ", "),
                ageBar: input.age.map { FitnessAgeBar.make(realAge: $0, cardio: cardio) }))
        }
    }

    /// "Top half for men aged 30 to 39". The bands are the FRIEND percentiles of the person's age decade and curve.
    static func bandLine(_ gauge: VO2MaxGauge) -> String {
        let row = gauge.percentiles
        let who = row.group == .female ? "women" : "men"
        let band = gauge.band.label
        return "\(band.prefix(1).uppercased() + band.dropFirst()) for \(who) aged \(row.ageLower) to \(row.ageUpper)"
    }

    /// The app's number locale: numbers are pinned to en_US across the app (`LooprUnitFormatter`), so the gauge, its
    /// sentence and the test screens all show "44.1" (R2-OPT-18). Dates and times follow the device.
    static let numberLocale = Locale(identifier: "en_US_POSIX")

    /// One decimal in the app's number locale.
    static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return (rounded == 0 ? 0 : rounded).formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(numberLocale))
    }

    static func gaugeNote(_ gauge: VO2MaxGauge) -> String {
        var sentences: [String] = []
        if let change = gauge.changeOverTwelveMonths {
            let shown = oneDecimal(abs(change))
            if shown == "0.0" {
                sentences.append("The same as 12 months ago.")
            } else {
                sentences.append("\(change > 0 ? "Up" : "Down") \(shown) in 12 months.")
            }
            sentences.append("Last year's needle is the faint one.")
        } else {
            sentences.append("A year ago there were too few readings for last year's needle.")
        }
        if gauge.showsConsumerEstimateCaveat { sentences.append(VO2MaxGauge.consumerEstimateCaveat) }
        return sentences.joined(separator: " ")
    }

    // MARK: Capacity

    static func capacity(_ input: FitnessOverviewInput) -> [FitnessCapacityTile] {
        capacityKinds.map { capacityTile($0, input) }
    }

    static func capacityTile(_ kind: CapacityTestKind, _ input: FitnessOverviewInput) -> FitnessCapacityTile {
        let summary = CapacitySummary.make(kind: kind, results: input.capacityResults, cadences: input.capacityCadences,
                                           goal: input.capacityGoals[kind], dateOfBirth: input.approximateDateOfBirth,
                                           now: input.now, calendar: input.calendar)
        var result = tile(summary, now: input.now, calendar: input.calendar, knowsBirthYear: input.birthYear != nil)
        result.norm = CapacityNorm.make(kind: kind, best: summary.best, age: input.age, group: input.referenceGroup)
        return result
    }

    static func tile(_ summary: CapacitySummary, now: Date, calendar: Calendar, knowsBirthYear: Bool = false) -> FitnessCapacityTile {
        let kind = summary.kind
        let best = summary.best
        let sourceLine: String? = kind == .heartRateRecovery ? summary.latest.map { latest in
            var local = calendar
            local.timeZone = TimeZone(identifier: latest.timeZoneIdentifier) ?? calendar.timeZone
            return "From a workout on \(dayMonth(latest.recordedAt, calendar: local))"
        } : nil
        let scale = instrumentScale(kind, best: best, goal: summary.goal?.targetValue)
        return FitnessCapacityTile(
            kind: kind, valueText: best.map { valueText(kind, $0) }, unitText: best == nil ? nil : unitText(kind),
            retestLine: retestLine(summary.retest, now: now, calendar: calendar),
            isBelowGoal: summary.trajectory.map { !$0.goalAlreadyMet } ?? false,
            fraction: best.map { min(max($0 / scale, 0), 1) },
            goalFraction: summary.goal.map { min(max($0.targetValue / scale, 0), 1) },
            history: summary.history.results.map { historyRow($0, calendar: calendar) },
            bestValue: best, goalValue: summary.goal?.targetValue, trajectory: summary.trajectory,
            knowsBirthYear: knowsBirthYear, sourceLine: sourceLine)
    }

    /// The full scale of each instrument: grip in tens of kilograms from 80, dead hang from two
    /// minutes, sit to stand out of 10, balance from 30 seconds. A value or goal past it widens it.
    static func instrumentScale(_ kind: CapacityTestKind, best: Double?, goal: Double?) -> Double {
        let top = max(best ?? 0, goal ?? 0)
        switch kind {
        case .grip: return max(80, (top / 10).rounded(.up) * 10)
        case .deadHang: return max(120, (top / 60).rounded(.up) * 60)
        case .sitToStand: return 10
        case .oneLegBalance: return max(30, (top / 10).rounded(.up) * 10)
        case .heartRateRecovery: return max(60, (top / 10).rounded(.up) * 10)
        }
    }

    static func valueText(_ kind: CapacityTestKind, _ value: Double) -> String {
        switch kind {
        case .deadHang:
            let seconds = Int(value.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .sitToStand, .grip:
            // Whole numbers stay whole; a half point reads "9.5" in the app's number locale.
            return value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(numberLocale))
        case .oneLegBalance, .heartRateRecovery:
            return String(Int(value.rounded()))
        }
    }

    static func unitText(_ kind: CapacityTestKind) -> String? {
        switch kind {
        case .grip: "kg"
        case .deadHang: nil
        case .sitToStand: "/10"
        case .oneLegBalance: "s"
        case .heartRateRecovery: "bpm"
        }
    }

    static func retestLine(_ retest: CapacityRetest, now: Date, calendar: Calendar) -> String? {
        switch retest {
        case .noRule: return nil
        case .firstTest: return "Test due"
        case .due(let date, _):
            if calendar.startOfDay(for: date) <= calendar.startOfDay(for: now) { return "Test due" }
            return "Retest \(dayMonth(date, calendar: calendar))"
        }
    }

    static func dayMonth(_ date: Date, calendar: Calendar, withYear: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = withYear ? "d MMM yyyy" : "d MMM"
        return formatter.string(from: date)
    }

    static func historyRow(_ result: CapacityResult, calendar: Calendar) -> FitnessCapacityHistoryRow {
        var local = calendar
        local.timeZone = TimeZone(identifier: result.timeZoneIdentifier) ?? calendar.timeZone
        let value = valueText(result.kind, result.value) + (unitText(result.kind).map { $0 == "/10" ? $0 : " \($0)" } ?? "")
        let side: String? = result.side.map { side in
            let limb = result.kind == .grip ? "hand" : "leg"
            return "\(side == .left ? "Left" : "Right") \(limb)"
        }
        let source = switch result.source {
        case .typed: "Typed in"
        case .timed: "Timed on this iPhone"
        case .workout: "From a workout"
        }
        return FitnessCapacityHistoryRow(id: result.id, dateText: dayMonth(result.recordedAt, calendar: local, withYear: true),
                                         valueText: value, sideText: side, sourceText: source)
    }
}

/// The one line above the dose rows (R1-NEW-05, R2-DES-07): how far into the week it is, then how many targeted rows
/// are on pace. On pace means the target spread evenly over the week's seven days, today included, so on Tuesday a row
/// keeps pace at two sevenths of its target. A row is met once its target is reached, open while it has nothing yet.
/// Rows without a target, or without a reading, are left out. No score and no "optimal": the targets are the person's
/// own protocol rules.
public enum FitnessDoseVerdict {
    public enum Standing: Equatable, Sendable { case met, onPace, behind, open }

    public struct Row: Equatable, Sendable {
        public let name: String
        public let standing: Standing
    }

    /// The rows that have a target and a reading, in the field's order.
    public static func rows(_ dose: WeeklyDose, daysIn: Int, daysInWeek: Int) -> [Row] {
        let pace = Double(min(max(daysIn, 0), max(daysInWeek, 1))) / Double(max(daysInWeek, 1))
        func standing(_ value: Double, _ target: Double) -> Standing {
            if value >= target { return .met }
            if value <= 0 { return .open }
            return value / target >= pace - 1e-9 ? .onPace : .behind
        }
        var rows: [Row] = []
        if let minutes = dose.zone2.minutes, let target = dose.zone2.target {
            rows.append(Row(name: "Zone 2", standing: standing(minutes, target)))
        }
        if let minutes = dose.hard.minutes, let target = dose.hard.target {
            rows.append(Row(name: "Hard minutes", standing: standing(minutes, target)))
        }
        if let target = dose.strength.target {
            rows.append(Row(name: "Strength", standing: standing(Double(dose.strength.count), Double(target))))
        }
        if let target = dose.mobility.target {
            rows.append(Row(name: "Mobility", standing: standing(Double(dose.mobility.count), Double(target))))
        }
        return rows
    }

    /// "Two days in.", "Last day."
    static func daysInPhrase(_ daysIn: Int, daysInWeek: Int) -> String {
        if daysIn >= daysInWeek { return "Last day." }
        return daysIn == 1 ? "One day in." : "\(word(daysIn).capitalizedFirst) days in."
    }

    /// Nil when no row has a target and a reading, unless the week is blank, where it invites the first session.
    public static func sentence(_ dose: WeeklyDose, daysIn: Int, daysInWeek: Int) -> String? {
        let rows = rows(dose, daysIn: daysIn, daysInWeek: daysInWeek)
        guard !rows.isEmpty else {
            let blank = dose.zone2.minutes == nil && dose.strength.count == 0 && dose.mobility.count == 0
            return blank ? FitnessDose.blank : nil
        }
        var sentences = [daysInPhrase(daysIn, daysInWeek: daysInWeek)]
        let good = rows.filter { $0.standing == .met || $0.standing == .onPace }
        let open = rows.filter { $0.standing == .open }.map(\.name)
        let behind = rows.filter { $0.standing == .behind }.map(\.name)
        if rows.allSatisfy({ $0.standing == .met }) {
            switch rows.count {
            case 1: sentences.append("\(rows[0].name) target met.")
            case 2: sentences.append("Both targets met.")
            default: sentences.append("All \(word(rows.count)) targets met.")
            }
            return sentences.joined(separator: " ")
        }
        if good.isEmpty, behind.isEmpty {
            sentences.append("Nothing logged yet.")
            return sentences.joined(separator: " ")
        }
        if rows.count == 1 {
            sentences.append(good.isEmpty ? "\(rows[0].name) is behind." : "\(rows[0].name) is on pace.")
            return sentences.joined(separator: " ")
        }
        if good.count == rows.count {
            sentences.append(rows.count == 2 ? "Both on pace." : "All \(word(rows.count)) on pace.")
        } else {
            sentences.append("\(word(good.count).capitalizedFirst) of \(word(rows.count)) on pace.")
        }
        if !open.isEmpty { sentences.append("\(list(open)) \(open.count == 1 ? "has" : "have") none yet.") }
        if !behind.isEmpty { sentences.append("\(list(behind)) \(behind.count == 1 ? "is" : "are") behind.") }
        return sentences.joined(separator: " ")
    }

    static func word(_ number: Int) -> String {
        let words = ["none", "one", "two", "three", "four", "five", "six", "seven"]
        return words.indices.contains(number) ? words[number] : "\(number)"
    }

    /// "Mobility", "Strength and mobility": names after the first in lower case, except Zone 2.
    static func list(_ names: [String], lowercaseAfterFirst: Bool = true) -> String {
        let words = names.enumerated().map { index, name in
            !lowercaseAfterFirst || index == 0 || name == "Zone 2" ? name : name.lowercased()
        }
        guard let last = words.last else { return "" }
        return words.count == 1 ? last : words.dropLast().joined(separator: ", ") + " and " + last
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The one line under "Fitness checks" on the Fitness tab: the VO₂max reading when there is one, then how many
/// capacity tests have a result.
public enum FitnessChecksSummary {
    public static func text(_ fitness: FitnessOverview) -> String {
        var parts: [String] = []
        if case .gauge(let reading) = fitness.vo2Max {
            parts.append("VO₂max \(reading.valueText)")
        } else {
            parts.append("VO₂max not read yet")
        }
        let tested = fitness.capacity.filter { $0.valueText != nil }.count
        let total = fitness.capacity.count
        if total > 0 {
            parts.append(tested == 0 ? "no strength or balance tests yet" : "\(tested) of \(total) tests done")
        }
        return parts.joined(separator: ", ")
    }
}
