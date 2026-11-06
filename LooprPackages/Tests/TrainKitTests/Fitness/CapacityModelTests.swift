import Foundation
import RoutineKit
import Testing
import TrainKit

struct CapacityModelTests {
    typealias F = FitnessFixture
    let now = F.date(2026, 10, 24)
    let calendar = F.calendar()

    func result(_ kind: CapacityTestKind, _ value: Double, side: CapacitySide? = nil, at date: Date? = nil,
                zone: String = "UTC", createdAt: Date? = nil) throws -> CapacityResult {
        try CapacityResult(kind: kind, value: value, side: side ?? (kind.requiresSide ? .left : nil),
                           recordedAt: date ?? now, timeZoneIdentifier: zone, workoutID: nil, createdAt: createdAt)
    }

    // MARK: Validation, one block per kind

    @Test func gripIsTypedKilogramsPerHand() throws {
        let grip = try result(.grip, 52, side: .right)
        #expect(grip.unit == "kg" && grip.source == .typed && grip.side == .right)
        #expect(throws: CapacityError.valueOutOfRange(.grip)) { try result(.grip, 0) }
        #expect(throws: CapacityError.valueOutOfRange(.grip)) { try result(.grip, -5) }
        #expect(throws: CapacityError.valueOutOfRange(.grip)) { try result(.grip, 150.5) }
        #expect(throws: CapacityError.valueNotFinite) { try result(.grip, .nan) }
        #expect(throws: CapacityError.valueNotFinite) { try result(.grip, .infinity) }
        #expect(throws: CapacityError.sideRequired(.grip)) {
            try CapacityResult(kind: .grip, value: 40, recordedAt: now, timeZoneIdentifier: "UTC")
        }
        #expect(throws: CapacityError.wrongSource(.grip)) {
            try CapacityResult(kind: .grip, value: 40, side: .left, recordedAt: now, timeZoneIdentifier: "UTC", source: .timed)
        }
    }

    @Test func deadHangIsSecondsTimedByThePhoneWithNoSide() throws {
        let hang = try result(.deadHang, 84)
        #expect(hang.unit == "s" && hang.source == .timed && hang.side == nil)
        #expect(throws: CapacityError.valueOutOfRange(.deadHang)) { try result(.deadHang, 0) }
        #expect(throws: CapacityError.valueOutOfRange(.deadHang)) { try result(.deadHang, 3_601) }
        #expect(throws: CapacityError.sideNotAllowed(.deadHang)) { try result(.deadHang, 30, side: .left) }
        #expect(throws: CapacityError.wrongSource(.deadHang)) {
            try CapacityResult(kind: .deadHang, value: 30, recordedAt: now, timeZoneIdentifier: "UTC", source: .typed)
        }
    }

    @Test func sitToStandIsASelfScoreFromZeroToTenInHalfPoints() throws {
        for value in [0.0, 0.5, 7, 9.5, 10] {
            let score = try result(.sitToStand, value)
            #expect(score.unit == "points" && score.source == .typed && score.value == value)
        }
        #expect(throws: CapacityError.valueOutOfRange(.sitToStand)) { try result(.sitToStand, 10.5) }
        #expect(throws: CapacityError.valueOutOfRange(.sitToStand)) { try result(.sitToStand, -0.5) }
        #expect(throws: CapacityError.notInSteps(.sitToStand)) { try result(.sitToStand, 7.3) }
        #expect(throws: CapacityError.notInSteps(.sitToStand)) { try result(.sitToStand, 9.75) }
        #expect(throws: CapacityError.sideNotAllowed(.sitToStand)) { try result(.sitToStand, 8, side: .right) }
    }

    @Test func oneLegBalanceIsTimedSecondsWithTheSide() throws {
        let balance = try result(.oneLegBalance, 18, side: .left)
        #expect(balance.unit == "s" && balance.source == .timed && balance.side == .left)
        #expect(throws: CapacityError.sideRequired(.oneLegBalance)) {
            try CapacityResult(kind: .oneLegBalance, value: 18, recordedAt: now, timeZoneIdentifier: "UTC")
        }
        #expect(throws: CapacityError.valueOutOfRange(.oneLegBalance)) { try result(.oneLegBalance, 0) }
        #expect(throws: CapacityError.valueOutOfRange(.oneLegBalance)) { try result(.oneLegBalance, 601) }
    }

    @Test func heartRateRecoveryNeedsItsWorkoutAndCalculationVersion() throws {
        let id = UUID()
        let recovery = try CapacityResult(kind: .heartRateRecovery, value: 30, recordedAt: now, timeZoneIdentifier: "UTC",
                                          workoutID: id, algorithmVersion: "loopr.workout-hrr.1")
        #expect(recovery.unit == "bpm" && recovery.source == .workout && recovery.workoutID == id)
        #expect(throws: CapacityError.workoutRequired) {
            try CapacityResult(kind: .heartRateRecovery, value: 30, recordedAt: now, timeZoneIdentifier: "UTC")
        }
        #expect(throws: CapacityError.workoutRequired) {
            try CapacityResult(kind: .heartRateRecovery, value: 30, recordedAt: now, timeZoneIdentifier: "UTC", workoutID: id)
        }
        #expect(throws: CapacityError.valueOutOfRange(.heartRateRecovery)) {
            try CapacityResult(kind: .heartRateRecovery, value: -1, recordedAt: now, timeZoneIdentifier: "UTC",
                               workoutID: id, algorithmVersion: "v")
        }
        #expect(throws: CapacityError.wrongSource(.heartRateRecovery)) {
            try CapacityResult(kind: .heartRateRecovery, value: 30, recordedAt: now, timeZoneIdentifier: "UTC",
                               source: .typed, workoutID: id, algorithmVersion: "v")
        }
    }

    @Test func aTypedResultCannotCarryAWorkoutAndEveryResultNeedsAKnownZone() throws {
        #expect(throws: CapacityError.workoutNotAllowed) {
            try CapacityResult(kind: .grip, value: 40, side: .left, recordedAt: now, timeZoneIdentifier: "UTC", workoutID: UUID())
        }
        #expect(throws: CapacityError.unknownTimeZone) { try result(.deadHang, 30, zone: "Mars/Olympus") }
        #expect(throws: CapacityError.invalidDate) { try result(.deadHang, 30, at: Date(timeIntervalSince1970: .nan)) }
    }

    @Test func everyKindHasATitleUnitSourceAndRuleMetric() {
        #expect(CapacityTestKind.allCases.count == 5)
        #expect(Set(CapacityTestKind.allCases.map(\.rawValue)).count == 5)
        #expect(CapacityTestKind.grip.ruleMetric == "capacity_grip" && CapacityTestKind.oneLegBalance.ruleMetric == "capacity_one_leg_balance")
        #expect(CapacityTestKind.allCases.filter(\.requiresSide) == [.grip, .oneLegBalance])
        #expect(CapacityTestKind.allCases.filter(\.isRetestable) == [.grip, .deadHang, .sitToStand, .oneLegBalance])
        #expect(CapacityTestKind.deadHang.title == "Dead hang" && CapacityTestKind.oneLegBalance.title == "One-leg balance")
    }

    // MARK: History and the latest result

    @Test func historyIsNewestFirstWithTheLatestAndTheBestOfThatDay() throws {
        let old = try result(.grip, 55, side: .left, at: F.date(2026, 9, 1, 9))
        let leftToday = try result(.grip, 50, side: .left, at: F.date(2026, 10, 20, 9))
        let rightToday = try result(.grip, 52, side: .right, at: F.date(2026, 10, 20, 9, 5))
        let other = try result(.deadHang, 60, at: F.date(2026, 10, 21))
        let history = CapacityHistory(kind: .grip, results: [leftToday, old, other, rightToday])
        #expect(history.results == [rightToday, leftToday, old])
        #expect(history.latest == rightToday)
        #expect(history.headline == 52)
        #expect(CapacityHistory(kind: .grip, results: []).latest == nil && CapacityHistory(kind: .grip, results: []).headline == nil)
    }

    @Test func theHeadlineUsesTheDayInTheZoneTheResultWasRecordedIn() throws {
        // 23:00 UTC on 20 October and 01:00 UTC on 21 October fall on different UTC days but the same Perth day.
        let first = try result(.grip, 48, side: .left, at: F.date(2026, 10, 20, 23), zone: "Australia/Perth")
        let second = try result(.grip, 46, side: .right, at: F.date(2026, 10, 21, 1), zone: "Australia/Perth")
        #expect(CapacityHistory(kind: .grip, results: [first, second]).headline == 48)
    }

    @Test func resultsAtTheSameInstantListTheLaterCreatedFirst() throws {
        let a = try result(.deadHang, 50, createdAt: F.date(2026, 10, 24, 12, 1))
        let b = try result(.deadHang, 51, createdAt: F.date(2026, 10, 24, 12, 2))
        #expect(CapacityHistory(kind: .deadHang, results: [a, b]).latest == b)
    }

    // MARK: Retest dates

    func rule(_ kind: CapacityTestKind, value: Double? = nil, unit: String?, group: RuleGroup = .tests, key: String? = nil) -> ProtocolRule {
        ProtocolRule(key: RuleKey(rawValue: key ?? "t-\(kind.rawValue)-\(unit ?? "none")"), title: "Test \(kind.title)", group: group,
                     target: RuleTarget(kind: .done, metric: kind.ruleMetric, value: value, unit: unit))
    }

    @Test func aMonthlyRuleSetsTheRetestAMonthAfterTheLatestResult() throws {
        let cadences = CapacityCadence.cadences(from: [rule(.grip, unit: "month")])
        let latest = try result(.grip, 52, side: .left, at: F.date(2026, 10, 2, 8))
        #expect(CapacityRetest.make(kind: .grip, latest: latest, cadences: cadences, calendar: calendar).date == F.date(2026, 11, 2, 8))
        let thirtyFirst = try result(.grip, 52, side: .left, at: F.date(2026, 1, 31, 8))
        #expect(CapacityRetest.make(kind: .grip, latest: thirtyFirst, cadences: cadences, calendar: calendar).date == F.date(2026, 2, 28, 8))
    }

    @Test func theCadenceReadsCommonSpellings() {
        func cadence(_ value: Double?, _ unit: String?) -> CapacityCadence? { CapacityCadence(count: value, unitText: unit) }
        #expect(cadence(nil, "month") == CapacityCadence(count: 1, unit: .month))
        #expect(cadence(nil, "Monthly") == CapacityCadence(count: 1, unit: .month))
        #expect(cadence(3, "months") == CapacityCadence(count: 3, unit: .month))
        #expect(cadence(nil, "quarterly") == CapacityCadence(count: 3, unit: .month))
        #expect(cadence(2, "per week") == CapacityCadence(count: 2, unit: .week))
        #expect(cadence(nil, "every year") == CapacityCadence(count: 1, unit: .year))
        #expect(cadence(14, "days") == CapacityCadence(count: 14, unit: .day))
        #expect(cadence(nil, "daily") == CapacityCadence(count: 1, unit: .day))
        #expect(cadence(nil, nil) == nil && cadence(nil, "fortnight") == nil)
        #expect(cadence(0, "month") == nil && cadence(-1, "month") == nil && cadence(1.5, "month") == nil && cadence(.nan, "month") == nil)
    }

    @Test func cadenceAdvancesByTheCalendarUnit() throws {
        let start = F.date(2026, 10, 24, 9)
        #expect(CapacityCadence(count: 1, unit: .week)?.date(after: start, calendar: calendar) == F.date(2026, 10, 31, 9))
        #expect(CapacityCadence(count: 10, unit: .day)?.date(after: start, calendar: calendar) == F.date(2026, 11, 3, 9))
        #expect(CapacityCadence(count: 1, unit: .year)?.date(after: start, calendar: calendar) == F.date(2027, 10, 24, 9))
        #expect(CapacityCadence(count: 0, unit: .day) == nil)
    }

    @Test func aTestWithNoRuleHasNoRetestDate() throws {
        let latest = try result(.deadHang, 80)
        #expect(CapacityRetest.make(kind: .deadHang, latest: latest, cadences: [:], calendar: calendar) == .noRule)
        let cadences = CapacityCadence.cadences(from: [rule(.grip, unit: "month")])
        #expect(CapacityRetest.make(kind: .deadHang, latest: latest, cadences: cadences, calendar: calendar).date == nil)
    }

    @Test func aRuleWithNoResultYetIsAFirstTestNotADate() throws {
        let cadences = CapacityCadence.cadences(from: [rule(.sitToStand, unit: "month")])
        let retest = CapacityRetest.make(kind: .sitToStand, latest: nil, cadences: cadences, calendar: calendar)
        #expect(retest == .firstTest(CapacityCadence(count: 1, unit: .month)!) && retest.date == nil)
    }

    @Test func onlyTestsGroupRulesNamedForATestSetACadence() {
        let rules = [
            rule(.grip, unit: "month", group: .fitness, key: "wrong-group"),
            rule(.deadHang, unit: "fortnight", key: "unreadable"),
            rule(.sitToStand, value: 3, unit: "months", key: "sit"),
            rule(.oneLegBalance, unit: "week", key: "balance-first"),
            rule(.oneLegBalance, unit: "year", key: "balance-second"),
            rule(.heartRateRecovery, unit: "month", key: "hrr"),
            ProtocolRule(key: "other", title: "Other", group: .tests, target: RuleTarget(kind: .done, metric: "apob", unit: "month"))
        ]
        let cadences = CapacityCadence.cadences(from: rules)
        #expect(cadences == [.sitToStand: CapacityCadence(count: 3, unit: .month)!, .oneLegBalance: CapacityCadence(count: 1, unit: .week)!])
    }

    @Test func heartRateRecoveryHasNoRetestEvenWithARule() throws {
        let id = UUID()
        let recovery = try CapacityResult(id: id, kind: .heartRateRecovery, value: 30, recordedAt: now, timeZoneIdentifier: "UTC",
                                          workoutID: id, algorithmVersion: "loopr.workout-hrr.1")
        let cadence = CapacityCadence(count: 1, unit: .month)!
        #expect(CapacityRetest.make(kind: .heartRateRecovery, latest: recovery, cadences: [.heartRateRecovery: cadence], calendar: calendar) == .noRule)
    }

    // MARK: Goals at 85

    @Test func aGoalIsValidatedLikeAResultAndNeedsToBePositive() throws {
        #expect(try CapacityGoal(kind: .grip, targetValue: 40, setAt: now).unit == "kg")
        #expect(CapacityGoal.targetAge == 85)
        #expect(throws: CapacityError.valueOutOfRange(.grip)) { try CapacityGoal(kind: .grip, targetValue: 0, setAt: now) }
        #expect(throws: CapacityError.valueOutOfRange(.sitToStand)) { try CapacityGoal(kind: .sitToStand, targetValue: 11, setAt: now) }
        #expect(throws: CapacityError.notInSteps(.sitToStand)) { try CapacityGoal(kind: .sitToStand, targetValue: 8.2, setAt: now) }
        #expect(throws: CapacityError.valueNotFinite) { try CapacityGoal(kind: .deadHang, targetValue: .nan, setAt: now) }
        #expect(throws: CapacityError.invalidDate) { try CapacityGoal(kind: .deadHang, targetValue: 30, setAt: Date(timeIntervalSince1970: .infinity)) }
    }

    @Test func theTrajectoryIsAStraightLineFromTodaysBestToTheGoalOnThe85thBirthday() throws {
        let goal = try CapacityGoal(kind: .grip, targetValue: 30, setAt: now)
        let birth = F.date(1980, 3, 1)
        let line = try #require(CapacityTrajectory.make(kind: .grip, best: 52, goal: goal, dateOfBirth: birth, now: now, calendar: calendar))
        #expect(line.start == CapacityTrajectory.Point(date: now, value: 52))
        #expect(line.end == CapacityTrajectory.Point(date: F.date(2065, 3, 1), value: 30))
        #expect(line.value(at: now) == 52 && line.value(at: line.end.date) == 30)
        let middle = now.addingTimeInterval(line.end.date.timeIntervalSince(now) / 2)
        #expect(abs(line.value(at: middle) - 41) < 1e-9)
        let years = line.end.date.timeIntervalSince(now) / CapacityTrajectory.secondsPerYear
        #expect(abs(line.changePerYear - (-22 / years)) < 1e-12 && line.changePerYear < 0)
        // Today's best of 52 is already above the goal of 30, so the line falls and the goal counts as met.
        #expect(line.goalAlreadyMet)
        // Outside the line the value holds at the nearest end.
        #expect(line.value(at: now.addingTimeInterval(-86_400)) == 52 && line.value(at: F.date(2070, 1, 1)) == 30)
    }

    @Test func theTrajectoryPointsRunFromStartToEndEvenly() throws {
        let goal = try CapacityGoal(kind: .deadHang, targetValue: 60, setAt: now)
        let line = try #require(CapacityTrajectory.make(kind: .deadHang, best: 40, goal: goal, dateOfBirth: F.date(1990, 10, 24), now: now, calendar: calendar))
        let points = line.points(count: 5)
        #expect(points.count == 5 && points.first == line.start && points.last?.value == 60)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.date < $1.date && $0.value < $1.value })
        #expect(line.points(count: 0).count == 2 && line.points(count: 1).count == 2)
        #expect(line.changePerYear > 0 && !line.goalAlreadyMet)
    }

    @Test func aGoalAlreadyMetStillDrawsTheLineAndSaysSo() throws {
        let goal = try CapacityGoal(kind: .grip, targetValue: 30, setAt: now)
        let line = try #require(CapacityTrajectory.make(kind: .grip, best: 52, goal: goal, dateOfBirth: F.date(1980, 3, 1), now: now, calendar: calendar))
        #expect(line.goalAlreadyMet)
        let low = try CapacityGoal(kind: .grip, targetValue: 52, setAt: now)
        #expect(try #require(CapacityTrajectory.make(kind: .grip, best: 52, goal: low, dateOfBirth: F.date(1980, 3, 1), now: now, calendar: calendar)).goalAlreadyMet)
    }

    @Test func theTrajectoryIsAbsentWithoutABestAGoalABirthDateOrTimeLeft() throws {
        let goal = try CapacityGoal(kind: .grip, targetValue: 30, setAt: now)
        let birth = F.date(1980, 3, 1)
        func make(best: Double? = 52, goal: CapacityGoal? = goal, birth: Date? = birth, kind: CapacityTestKind = .grip) -> CapacityTrajectory? {
            CapacityTrajectory.make(kind: kind, best: best, goal: goal, dateOfBirth: birth, now: now, calendar: calendar)
        }
        #expect(make() != nil)
        #expect(make(best: nil) == nil && make(best: .nan) == nil)
        #expect(make(goal: nil) == nil)
        #expect(make(birth: nil) == nil)
        #expect(make(kind: .deadHang) == nil)
        #expect(make(birth: F.date(1941, 10, 24, 12)) == nil)
        #expect(make(birth: F.date(1930, 1, 1)) == nil)
    }

    @Test func theSummaryBringsTheHistoryRetestAndTrajectoryTogether() throws {
        let latest = try result(.grip, 52, side: .right, at: F.date(2026, 10, 2, 8))
        let goal = try CapacityGoal(kind: .grip, targetValue: 45, setAt: now)
        let cadences = CapacityCadence.cadences(from: [rule(.grip, unit: "month")])
        let summary = CapacitySummary.make(kind: .grip, results: [latest], cadences: cadences, goal: goal,
                                           dateOfBirth: F.date(1980, 3, 1), now: now, calendar: calendar)
        #expect(summary.latest == latest && summary.best == 52)
        #expect(summary.retest.date == F.date(2026, 11, 2, 8))
        #expect(summary.goal == goal && summary.trajectory?.end.value == 45)
        let other = CapacitySummary.make(kind: .deadHang, results: [latest], cadences: cadences, goal: goal,
                                         dateOfBirth: F.date(1980, 3, 1), now: now, calendar: calendar)
        #expect(other.latest == nil && other.best == nil && other.goal == nil && other.trajectory == nil && other.retest == .noRule)
    }
}
