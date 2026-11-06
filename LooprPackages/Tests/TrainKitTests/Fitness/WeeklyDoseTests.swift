import DomainKit
import Foundation
import RoutineKit
import Testing
import TrainKit
import WorkoutKit

struct WeeklyDoseTests {
    typealias F = FitnessFixture

    // MARK: ISO weeks

    @Test func theContractWeekIsWeek43AndStartsOnMonday() throws {
        let week = try #require(ISOWeek(containing: F.date(2026, 10, 24), calendar: F.calendar()))
        #expect(week.weekOfYear == 43 && week.yearForWeekOfYear == 2026)
        #expect(week.start == F.date(2026, 10, 19, 0))
        #expect(week.end == F.date(2026, 10, 26, 0))
        #expect(week.days.first == F.day(2026, 10, 19) && week.days.last == F.day(2026, 10, 25))
        #expect(week.days.count == 7)
    }

    @Test func aSundayStillBelongsToTheWeekThatStartedOnMonday() throws {
        let sunday = try #require(ISOWeek(containing: F.date(2026, 10, 25, 23, 59), calendar: F.calendar()))
        let monday = try #require(ISOWeek(containing: F.date(2026, 10, 26, 0, 0), calendar: F.calendar()))
        #expect(sunday.weekOfYear == 43 && monday.weekOfYear == 44)
        #expect(sunday.contains(F.date(2026, 10, 25, 23, 59)) && !sunday.contains(F.date(2026, 10, 26, 0, 0)))
    }

    @Test func yearEdgesFollowIsoNumbering() throws {
        let calendar = F.calendar()
        // 2026 has 53 ISO weeks: the Thursday 31 December is in week 53, and so is Sunday 3 January 2027.
        let late = try #require(ISOWeek(containing: F.date(2026, 12, 31), calendar: calendar))
        let early = try #require(ISOWeek(containing: F.date(2027, 1, 3), calendar: calendar))
        #expect(late == early && late.weekOfYear == 53 && late.yearForWeekOfYear == 2026)
        #expect(late.start == F.date(2026, 12, 28, 0))
        #expect(try #require(ISOWeek(containing: F.date(2027, 1, 4), calendar: calendar)).weekOfYear == 1)
        // Monday 30 December 2024 is already week 1 of 2025.
        let next = try #require(ISOWeek(containing: F.date(2024, 12, 30), calendar: calendar))
        #expect(next.weekOfYear == 1 && next.yearForWeekOfYear == 2025)
        // Friday 1 January 2021 is still week 53 of 2020.
        let old = try #require(ISOWeek(containing: F.date(2021, 1, 1), calendar: calendar))
        #expect(old.weekOfYear == 53 && old.yearForWeekOfYear == 2020)
    }

    @Test func aSundayFirstCalendarStillGivesAMondayWeek() throws {
        var calendar = F.calendar()
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        let week = try #require(ISOWeek(containing: F.date(2026, 10, 25), calendar: calendar))
        #expect(week.start == F.date(2026, 10, 19, 0) && week.weekOfYear == 43)
    }

    @Test func theCalendarsTimeZoneDecidesWhichWeekAMomentIsIn() throws {
        // Sunday 25 October 17:00 UTC is Monday 26 October 01:00 in Perth.
        let moment = F.date(2026, 10, 25, 17)
        #expect(try #require(ISOWeek(containing: moment, calendar: F.calendar("UTC"))).weekOfYear == 43)
        #expect(try #require(ISOWeek(containing: moment, calendar: F.calendar("Australia/Perth"))).weekOfYear == 44)
    }

    // MARK: Counting

    @Test func theDoseCountsZone2HardMinutesAndBothSessionKinds() throws {
        let days = [
            DoseDay(day: F.day(2026, 10, 19), zones: F.zones(30, 60, 10, 5, 0)),
            DoseDay(day: F.day(2026, 10, 21), zones: F.zones(20, 52, 8, 6, 5)),
            DoseDay(day: F.day(2026, 10, 24), zones: F.zones(0, 0, 0, 0, 0))
        ]
        let sessions = [
            DoseSession(activity: "strength", date: F.date(2026, 10, 20)),
            DoseSession(activity: "Traditional Strength Training", date: F.date(2026, 10, 22)),
            DoseSession(activity: "yoga", date: F.date(2026, 10, 23)),
            DoseSession(activity: "run", date: F.date(2026, 10, 24))
        ]
        let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 24), days: days, sessions: sessions, calendar: F.calendar()))
        #expect(dose.zone2.minutes == 112)
        #expect(dose.hard.minutes == 16)
        #expect(dose.strength.count == 2 && dose.mobility.count == 1)
        #expect(dose.bandDaysWithData == 3 && dose.bandCoverageIsPartial)
    }

    @Test func daysAndSessionsOutsideTheWeekAreIgnored() throws {
        let days = [
            DoseDay(day: F.day(2026, 10, 18), zones: F.zones(0, 99, 0, 99, 0)),
            DoseDay(day: F.day(2026, 10, 26), zones: F.zones(0, 99, 0, 99, 0)),
            DoseDay(day: F.day(2026, 10, 25), zones: F.zones(0, 10, 0, 4, 1))
        ]
        let sessions = [
            DoseSession(activity: "strength", date: F.date(2026, 10, 18, 23, 59)),
            DoseSession(activity: "strength", date: F.date(2026, 10, 19, 0, 0)),
            DoseSession(activity: "strength", date: F.date(2026, 10, 25, 23, 59)),
            DoseSession(activity: "strength", date: F.date(2026, 10, 26, 0, 0))
        ]
        let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 21), days: days, sessions: sessions, calendar: F.calendar()))
        #expect(dose.zone2.minutes == 10 && dose.hard.minutes == 5)
        #expect(dose.strength.count == 2)
    }

    @Test func aWeekWithoutBandDataIsAbsentNotZero() throws {
        let sessions = [DoseSession(activity: "strength", date: F.date(2026, 10, 20))]
        for days in [[], [DoseDay(day: F.day(2026, 10, 20), zones: nil), DoseDay(day: F.day(2026, 10, 21), zones: nil)]] {
            let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 24), days: days, sessions: sessions,
                targets: DoseTargets(zone2Minutes: 180, hardMinutes: 20), calendar: F.calendar()))
            #expect(dose.zone2.minutes == nil && dose.hard.minutes == nil)
            #expect(dose.zone2.dots == nil && dose.hard.dots == nil)
            #expect(dose.zone2.progress == nil)
            #expect(dose.bandDaysWithData == 0 && !dose.bandCoverageIsPartial)
            #expect(dose.strength.count == 1)
        }
    }

    @Test func aMeasuredDayWithNoZoneTimeIsAMeasuredZero() throws {
        let days = [DoseDay(day: F.day(2026, 10, 20), zones: F.zones())]
        let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 24), days: days, sessions: [],
            targets: DoseTargets(zone2Minutes: 180), calendar: F.calendar()))
        #expect(dose.zone2.minutes == 0 && dose.zone2.dots == DoseDots(minutes: 0, target: 180))
        #expect(dose.zone2.dots?.filled == 0 && dose.zone2.dots?.total == 36)
    }

    @Test func aFullWeekHasNoPartialCoverageFlag() throws {
        let week = try #require(ISOWeek(containing: F.date(2026, 10, 24), calendar: F.calendar()))
        let days = week.days.map { DoseDay(day: $0, zones: F.zones(0, 10)) }
        let dose = WeeklyDose.make(week: week, days: days, sessions: [])
        #expect(dose.zone2.minutes == 70 && dose.bandDaysWithData == 7 && !dose.bandCoverageIsPartial)
    }

    @Test func aRepeatedDayCountsOnceAndTheLaterEntryWins() throws {
        let days = [DoseDay(day: F.day(2026, 10, 20), zones: F.zones(0, 10)), DoseDay(day: F.day(2026, 10, 20), zones: F.zones(0, 25))]
        let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 24), days: days, sessions: [], calendar: F.calendar()))
        #expect(dose.zone2.minutes == 25 && dose.bandDaysWithData == 1)
    }

    @Test func zoneMinutesNeedFiveFiniteNonNegativeValues() {
        #expect(BandZoneMinutes(zones: [1, 2, 3, 4]) == nil)
        #expect(BandZoneMinutes(zones: [1, 2, 3, 4, 5, 6]) == nil)
        #expect(BandZoneMinutes(zones: [1, -2, 3, 4, 5]) == nil)
        #expect(BandZoneMinutes(zones: [1, .nan, 3, 4, 5]) == nil)
        #expect(BandZoneMinutes(zones: [1, .infinity, 3, 4, 5]) == nil)
        #expect(BandZoneMinutes(zones: [1, 2, 3, 4, 5])?.hard == 9)
    }

    // MARK: Dots and targets

    @Test func oneDotIsFiveMinutesAndTheContractNumbersFill() throws {
        let days = [DoseDay(day: F.day(2026, 10, 20), zones: F.zones(0, 112, 0, 11, 5))]
        let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 24), days: days, sessions: [],
            targets: DoseTargets(zone2Minutes: 180, hardMinutes: 20, strengthSessions: 3, mobilitySessions: 3), calendar: F.calendar()))
        #expect(dose.zone2.dots == DoseDots(minutes: 112, target: 180))
        #expect(dose.zone2.dots?.filled == 22 && dose.zone2.dots?.total == 36)
        #expect(dose.hard.minutes == 16 && dose.hard.dots?.filled == 3 && dose.hard.dots?.total == 4)
        #expect(dose.strength.target == 3 && dose.mobility.target == 3)
        #expect(abs((dose.zone2.progress ?? 0) - 112.0 / 180.0) < 1e-12)
    }

    @Test func aTargetThatIsNotAWholeNumberOfDotsRoundsUpAndOverflowIsNotCapped() throws {
        #expect(DoseDots(minutes: 4.9, target: 22).filled == 0)
        #expect(DoseDots(minutes: 5, target: 22).filled == 1)
        #expect(DoseDots(minutes: 5, target: 22).total == 5)
        #expect(DoseDots(minutes: 200, target: 20).filled == 40)
    }

    @Test func withoutATargetTheDoseShowsTheCountWithoutAGoal() throws {
        let days = [DoseDay(day: F.day(2026, 10, 20), zones: F.zones(0, 40, 0, 10, 0))]
        let sessions = [DoseSession(activity: "yoga", date: F.date(2026, 10, 20))]
        let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 24), days: days, sessions: sessions, calendar: F.calendar()))
        #expect(dose.zone2.minutes == 40 && dose.zone2.target == nil && dose.zone2.dots?.total == nil && dose.zone2.dots?.filled == 8)
        #expect(dose.zone2.progress == nil)
        #expect(dose.strength.target == nil && dose.mobility.target == nil && dose.mobility.count == 1)
    }

    @Test func aTargetThatIsNotPositiveBecomesNoTarget() {
        let targets = DoseTargets(zone2Minutes: 0, hardMinutes: .nan, strengthSessions: 0, mobilitySessions: -1)
        #expect(targets == .none)
    }

    @Test func targetsComeFromTheProtocolsRulesByMetricName() throws {
        let week = RuleCadence(unit: .week)
        let rules = [
            ProtocolRule(key: "z2", title: "Zone 2", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 180, unit: "min"), cadence: week),
            ProtocolRule(key: "hard", title: "Hard", group: .fitness, target: RuleTarget(kind: .exactly, metric: "zone45_minutes", value: 20, unit: "min"), cadence: week),
            ProtocolRule(key: "lift", title: "Lift", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "strength_sessions", value: 2.5, unit: "sessions"), cadence: week),
            ProtocolRule(key: "move", title: "Mobility", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "mobility_sessions", value: 3, unit: "per week")),
            ProtocolRule(key: "sleep", title: "Bed by 22:30", group: .sleep, target: RuleTarget(kind: .atMost, metric: "bedtime", value: 1_350))
        ]
        let targets = DoseTargets(rules: rules)
        #expect(targets == DoseTargets(zone2Minutes: 180, hardMinutes: 20, strengthSessions: 3, mobilitySessions: 3))
        #expect(DoseTargets(rules: []) == .none)
    }

    @Test func aRuleThatIsNotAWeeklyAtLeastTargetSetsNoTarget() {
        let rules = [
            ProtocolRule(key: "a", title: "A", group: .fitness, target: RuleTarget(kind: .atMost, metric: "zone2_minutes", value: 180)),
            ProtocolRule(key: "b", title: "B", group: .fitness, target: RuleTarget(kind: .done, metric: "zone45_minutes")),
            ProtocolRule(key: "c", title: "C", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "strength_sessions", value: 1, unit: "per day"), cadence: RuleCadence(unit: .month)),
            ProtocolRule(key: "d", title: "D", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "mobility_sessions", value: 0))
        ]
        #expect(DoseTargets(rules: rules) == .none)
    }

    /// R2-UPG-1, R2-OPT-16: "Zone 2, 45 min" every day is scored per day on Today, so the week asks for seven times
    /// it, 315 minutes, never 45. A rule every two weeks or every month sets no weekly target.
    @Test func anEveryDayRuleCountsSevenTimesAndALongerOneNone() {
        let daily = [
            ProtocolRule(key: "daily", title: "Zone 2, 45 min", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 45, unit: "min")),
            ProtocolRule(key: "day", title: "Hard", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "zone45_minutes", value: 5, unit: "min"), cadence: RuleCadence(unit: .day)),
            ProtocolRule(key: "lift", title: "Lift", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "strength_sessions", value: 1, unit: "per day"))
        ]
        #expect(DoseTargets(rules: daily) == DoseTargets(zone2Minutes: 315, hardMinutes: 35, strengthSessions: 7))
        let longer = [
            ProtocolRule(key: "fortnight", title: "Hard", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "zone45_minutes", value: 40, unit: "min"), cadence: RuleCadence(unit: .week, every: 2)),
            ProtocolRule(key: "month", title: "Lift", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "strength_sessions", value: 8), cadence: RuleCadence(unit: .month))
        ]
        #expect(DoseTargets(rules: longer) == .none)
        let labelled = [ProtocolRule(key: "z2", title: "Zone 2", group: .fitness,
                                     target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 150, unit: "min/week"))]
        #expect(DoseTargets(rules: labelled).zone2Minutes == 150)
    }

    @Test func theFirstMatchingRuleWinsAndALaterReadableRuleStillCountsWhenAnEarlierOneDoesNot() {
        let rules = [
            ProtocolRule(key: "a", title: "A", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 30, unit: "min"), cadence: RuleCadence(unit: .week, every: 2)),
            ProtocolRule(key: "b", title: "B", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 150), cadence: RuleCadence(unit: .week)),
            ProtocolRule(key: "c", title: "C", group: .fitness, target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 200), cadence: RuleCadence(unit: .week))
        ]
        #expect(DoseTargets(rules: rules).zone2Minutes == 150)
    }

    // MARK: Session kinds

    @Test func strengthAndMobilityActivitiesAreClassified() {
        for name in ["strength", "Strength", "traditionalStrengthTraining", "functional_strength_training", "HKWorkoutActivityTypeTraditionalStrengthTraining"] {
            #expect(DoseSessionKind.classify(activity: name) == .strength, "\(name)")
        }
        for name in ["yoga", "Mobility", "stretching", "flexibility", "balance", "pilates", "Tai Chi", "tai_chi", "mindAndBody",
                     "cooldown", "preparationAndRecovery", "HKWorkoutActivityTypeYoga"] {
            #expect(DoseSessionKind.classify(activity: name) == .mobility, "\(name)")
        }
        for name in ["run", "cycle", "walk", "hiit", "swim", "other", "coreTraining", "", "strengthless"] {
            #expect(DoseSessionKind.classify(activity: name) == nil, "\(name)")
        }
    }

    @Test func loopsOwnCatalogueMapsToTheRightKind() {
        let strength: Set<ActivityType> = [.strength, .crossfit]
        let mobility: Set<ActivityType> = [.yoga, .pilates, .mobility]
        for type in strength { #expect(DoseSessionKind.classify(activity: type.rawValue) == .strength, "\(type.rawValue)") }
        for type in mobility { #expect(DoseSessionKind.classify(activity: type.rawValue) == .mobility, "\(type.rawValue)") }
        for type in ActivityType.allCases where !strength.contains(type) && !mobility.contains(type) {
            #expect(DoseSessionKind.classify(activity: type.rawValue) == nil, "\(type.rawValue)")
        }
        #expect(DoseSession(activity: ActivityType.yoga, date: F.date(2026, 10, 20)).activity == "yoga")
    }

    @Test func aSessionSeenTwiceCountsOnce() throws {
        let id = UUID()
        let sessions = [
            DoseSession(id: id, activity: "strength", date: F.date(2026, 10, 20)),
            DoseSession(id: id, activity: "traditionalStrengthTraining", date: F.date(2026, 10, 20)),
            DoseSession(activity: "strength", date: F.date(2026, 10, 21)),
            DoseSession(activity: "strength", date: F.date(2026, 10, 21))
        ]
        let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 24), days: [], sessions: sessions, calendar: F.calendar()))
        #expect(dose.strength.count == 3)
    }

    @Test func aCompletedGymSessionCountsAsStrengthAndAnActiveOneDoesNot() throws {
        let workoutID = UUID()
        let started = F.date(2026, 10, 20, 9)
        let gym = try #require(DoseSession(trainSession: TrainFixture.session(startedAt: started, status: .completed, workoutID: workoutID)))
        let record = DoseSession(id: workoutID, activity: ActivityType.strength, date: started)
        #expect(gym.id == workoutID && gym.activity == "strength" && gym.date == started)
        #expect(DoseSession(trainSession: try TrainFixture.session(startedAt: started, status: .active)) == nil)
        #expect(DoseSession(trainSession: try TrainFixture.session(startedAt: started, status: .abandoned)) == nil)
        let dose = try #require(WeeklyDose.make(weekContaining: started, days: [], sessions: [gym, record], calendar: F.calendar()))
        #expect(dose.strength.count == 1)
    }

    @Test func aSessionNearMidnightFollowsTheCalendarsZone() throws {
        let session = DoseSession(activity: "strength", date: F.date(2026, 10, 25, 17))
        let utc = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 21), days: [], sessions: [session], calendar: F.calendar("UTC")))
        let perth = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 21), days: [], sessions: [session], calendar: F.calendar("Australia/Perth")))
        #expect(utc.strength.count == 1 && perth.strength.count == 0)
    }

    // MARK: Logged sessions (Fitness round 1)

    @Test func loggedPilatesMobilityAndYogaCountAsMobilityAndAWodAsStrength() async throws {
        let controller = WorkoutSessionController(store: InMemoryWorkoutStore(), now: { F.date(2026, 10, 23, 20) })
        var records: [WorkoutRecord] = []
        for (activity, day) in [(ActivityType.pilates, 20), (.mobility, 21), (.yoga, 22), (.crossfit, 22), (.sport, 23)] {
            let start = F.date(2026, 10, day, 7)
            let entry = WorkoutLogEntry(activity: activity, startedAt: start, endedAt: start.addingTimeInterval(20 * 60),
                                        title: activity == .sport ? "Five-a-side football" : nil)
            records.append(try await controller.logManual(entry))
        }
        let sessions = records.compactMap { record -> DoseSession? in
            guard record.state == .completed, let start = record.startedAt else { return nil }
            return DoseSession(id: record.id, activity: record.activity, date: start)
        }
        let dose = try #require(WeeklyDose.make(weekContaining: F.date(2026, 10, 21), days: [], sessions: sessions,
                                                calendar: F.calendar()))
        #expect(dose.mobility.count == 3)
        #expect(dose.strength.count == 1)
    }

    @Test func everyNewCatalogueTypeHasAnAnswer() {
        #expect(DoseSessionKind.classify(activity: ActivityType.pilates.rawValue) == .mobility)
        #expect(DoseSessionKind.classify(activity: ActivityType.mobility.rawValue) == .mobility)
        #expect(DoseSessionKind.classify(activity: ActivityType.crossfit.rawValue) == .strength)
        for activity in [ActivityType.rowing, .climbing, .sport, .dance, .other] {
            #expect(DoseSessionKind.classify(activity: activity.rawValue) == nil, "\(activity)")
        }
    }
}
