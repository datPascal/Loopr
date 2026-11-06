import AnalyticsKit
import DomainKit
import Foundation
import Testing
@testable import TrainKit

/// What the Fitness tab's signature objects say, built from plain inputs. The person is 38 on the male
/// reference curve; the day is Tuesday 2023-11-14 in Perth, ISO week 46.
struct FitnessOverviewTests {
    typealias F = FitnessFixture
    static let zone = "Australia/Perth"
    let calendar = F.calendar("Australia/Perth")
    /// Tuesday 2023-11-14, 10:00 in Perth.
    let now = F.date(2023, 11, 14, 10, zone: "Australia/Perth")

    func input(days: [DoseDay] = [], sessions: [DoseSession] = [], targets: DoseTargets = .none,
               vo2Max: FitnessVO2MaxSource = .readings([]), birthYear: Int? = 1985, group: FriendReferenceGroup? = .male,
               results: [CapacityResult] = [], goals: [CapacityTestKind: CapacityGoal] = [:],
               cadences: [CapacityTestKind: CapacityCadence] = [:], now: Date? = nil) -> FitnessOverviewInput {
        FitnessOverviewInput(now: now ?? self.now, calendar: calendar, doseDays: days, sessions: sessions, targets: targets,
                             vo2Max: vo2Max, birthYear: birthYear, referenceGroup: group, capacityResults: results,
                             capacityGoals: goals, capacityCadences: cadences)
    }

    func overview(_ input: FitnessOverviewInput) throws -> FitnessOverview { try #require(FitnessOverview.make(input)) }

    static let contractTargets = DoseTargets(zone2Minutes: 180, hardMinutes: 20, strengthSessions: 3, mobilitySessions: 3)

    /// Monday and Tuesday: 112 zone 2 minutes and 16 hard ones, as the contract phone.
    var bandDays: [DoseDay] {
        [DoseDay(day: F.day(2023, 11, 13), zones: F.zones(30, 64, 20, 6, 3)),
         DoseDay(day: F.day(2023, 11, 14), zones: F.zones(30, 48, 20, 5, 2))]
    }

    // MARK: Header

    /// R1-NEW-13: no calendar week number, only the days left counting today.
    @Test func theMetaSaysTheDaysLeftThisWeekCountingToday() throws {
        #expect(try overview(input()).meta == "6 days left this week")
        #expect(try overview(input(now: F.date(2023, 11, 16, 17, zone: Self.zone))).meta == "4 days left this week")
        #expect(try overview(input(now: F.date(2023, 11, 19, 20, zone: Self.zone))).meta == "Last day of the week")
    }

    // MARK: Dose

    @Test func theDoseCountsDotsOfFiveMinutesAgainstTheTargets() throws {
        let dose = try overview(input(days: bandDays, targets: Self.contractTargets)).dose
        #expect(dose.zone2.state == .dots(DoseDots(minutes: 112, target: 180)))
        #expect(dose.zone2.minutes == 112 && dose.zone2.suffix == " of 180 min")
        guard case .dots(let zone2) = dose.zone2.state, case .dots(let hard) = dose.hard.state else {
            Issue.record("Expected dots")
            return
        }
        #expect(zone2.filled == 22 && zone2.total == 36)
        #expect(hard.filled == 3 && hard.total == 4)
        #expect(dose.hard.suffix == " of 20 min")
        #expect(dose.bandAbsence == nil && dose.coverageNote == nil)
        #expect(dose.shown == FitnessDoseShown(zone2: 22, hard: 3))
        #expect(dose.weekKey == "2023-W46")
        #expect(dose.zone2.spokenLabel == "Zone 2, 112 of 180 minutes")
    }

    @Test func aWeekWithoutBandDataIsAbsentNeverZeroDots() throws {
        let days = [DoseDay(day: F.day(2023, 11, 13), zones: nil)]
        let dose = try overview(input(days: days, targets: Self.contractTargets)).dose
        #expect(dose.zone2.state == .absent && dose.hard.state == .absent)
        // No "Not measured" pill when there is a target: the row names the target and draws it hollow (R1-DES-18).
        #expect(dose.zone2.minutes == nil && dose.zone2.suffix == "Target 180 min")
        #expect(dose.zone2.targetDots == 36 && dose.hard.targetDots == 4)
        #expect(dose.bandAbsence == "Zone minutes come from a band. There are none this week yet.")
        #expect(dose.shown == nil)
        #expect(dose.spokenSummary.contains("Zone 2, not measured, target 180 minutes."))
        // Sessions are logged in Loopr, so zero of them is a real zero.
        #expect(dose.strength.count == 0 && dose.strength.suffix == " of 3")
        // Without a target an absent row says so plainly and draws nothing.
        let bare = try overview(input(days: days)).dose
        #expect(bare.zone2.suffix == "Not measured" && bare.zone2.targetDots == nil)
    }

    @Test func withoutATargetTheCountStandsAlone() throws {
        let dose = try overview(input(days: bandDays)).dose
        guard case .dots(let dots) = dose.zone2.state else {
            Issue.record("Expected dots")
            return
        }
        #expect(dots.total == nil)
        #expect(FitnessDotFill(dots).count == 22)
        #expect(dose.zone2.suffix == " min · no target")
        #expect(dose.zone2.spokenLabel == "Zone 2, 112 minutes, no weekly target")
        // Nothing logged and no target reads "None yet", not a bare 0 beside "no target".
        #expect(dose.strength.suffix == "None yet · no target" && dose.strength.remaining == 0 && dose.strength.shownCount == nil)
        #expect(dose.strength.spokenLabel == "Strength, none yet, no weekly target")
        #expect(dose.targetSource == FitnessDose.noTargets && dose.verdict == nil)
    }

    @Test func sessionsCountAgainstTheirTargetsAndLeaveOutlinesForTheRest() throws {
        let gym = UUID()
        let sessions = [
            DoseSession(id: gym, activity: "strength", date: F.date(2023, 11, 13, 17, zone: Self.zone)),
            DoseSession(id: gym, activity: .strength, date: F.date(2023, 11, 13, 17, zone: Self.zone)),
            DoseSession(activity: .strength, date: F.date(2023, 11, 14, 7, zone: Self.zone)),
            DoseSession(activity: .yoga, date: F.date(2023, 11, 14, 8, zone: Self.zone)),
            // Last week.
            DoseSession(activity: .strength, date: F.date(2023, 11, 10, 8, zone: Self.zone))
        ]
        let dose = try overview(input(days: bandDays, sessions: sessions, targets: Self.contractTargets)).dose
        #expect(dose.strength.count == 2 && dose.strength.remaining == 1)
        #expect(dose.strength.suffix == " of 3")
        #expect(dose.mobility.count == 1 && dose.mobility.remaining == 2)
        #expect(dose.mobility.spokenLabel == "Mobility, 1 of 3 sessions")
        let one = try overview(input(sessions: [sessions[3]])).dose
        #expect(one.mobility.suffix == " · no target" && one.mobility.shownCount == 1)
        #expect(one.mobility.spokenLabel == "Mobility, 1 session, no weekly target")
    }

    /// R1-NEW-04, R1-VET-11, R1-WOD-15: plain row names, and one line on what counts under each.
    @Test func theRowsHavePlainNamesAndSayWhatCounts() throws {
        let dose = try overview(input(days: bandDays, targets: Self.contractTargets)).dose
        #expect(dose.zone2.title == "Zone 2" && dose.zone2.caption == "easy cardio")
        #expect(dose.hard.title == "Hard minutes" && dose.hard.caption == "zones 4 and 5")
        #expect(dose.strength.title == "Strength sessions" && dose.mobility.title == "Mobility sessions")
        #expect(dose.strength.counts == "Gym sessions and WODs count.")
        #expect(dose.mobility.counts == "Yoga, Pilates, stretching and mobility count.")
        #expect(dose.zone2.counts == "Minutes in zone 2 during any activity.")
        #expect(dose.hard.counts == "Minutes in zones 4 and 5 during any activity.")
        #expect(dose.hard.spokenLabel == "Hard minutes, 16 of 20 minutes")
        #expect(dose.targetSource == "Targets from your protocol.")
        // Every line passes the copy rules: no em dash, no "optimal".
        for line in [dose.zone2.counts, dose.hard.counts, dose.strength.counts, dose.mobility.counts, dose.targetSource] {
            #expect(!line.contains("—") && !line.lowercased().contains("optimal"))
        }
    }

    /// R1-NEW-05: one line from the targets. Tuesday, one day gone: Zone 2 112 of 180, hard 16 of 20 and strength 1
    /// of 3 keep pace; mobility has nothing yet.
    @Test func theVerdictCountsTheRowsOnTrackAndNamesTheOpenOnes() throws {
        let gym = DoseSession(activity: .strength, date: F.date(2023, 11, 13, 17, zone: Self.zone))
        let dose = try overview(input(days: bandDays, sessions: [gym], targets: Self.contractTargets)).dose
        // The verdict says how far into the week it is, so "on pace" has a basis (R2-DES-07).
        #expect(dose.verdict == "Two days in. Three of four on pace. Mobility has none yet.")
        #expect(dose.spokenSummary.contains("Three of four on pace."))
    }

    @Test func theVerdictNamesRowsThatFallBehindThePace() throws {
        let sunday = F.date(2023, 11, 19, 20, zone: Self.zone)
        let yoga = DoseSession(activity: .yoga, date: F.date(2023, 11, 14, 8, zone: Self.zone))
        let dose = try overview(input(days: bandDays, sessions: [yoga], targets: Self.contractTargets, now: sunday)).dose
        // Six days gone: 112 of 180 and 16 of 20 are behind, 1 of 3 mobility too, strength has none.
        #expect(dose.verdict == "Last day. None of four on pace. Strength has none yet. Zone 2, hard minutes and mobility are behind.")
    }

    @Test func theVerdictSaysWhenEveryTargetIsMetOrNothingIsLogged() throws {
        let targets = DoseTargets(zone2Minutes: 100, strengthSessions: 1)
        let gym = DoseSession(activity: .strength, date: F.date(2023, 11, 13, 17, zone: Self.zone))
        #expect(try overview(input(days: bandDays, sessions: [gym], targets: targets)).dose.verdict?.hasSuffix(" Both targets met.") == true)
        let monday = F.date(2023, 11, 13, 7, zone: Self.zone)
        let empty = [DoseDay(day: F.day(2023, 11, 13), zones: F.zones(0, 0, 0, 0, 0))]
        #expect(try overview(input(days: empty, targets: targets, now: monday)).dose.verdict == "One day in. Nothing logged yet.")
        // No band, no sessions and no targets: the field invites the first session (R1-DES-18).
        #expect(try overview(input()).dose.verdict == FitnessDose.blank)
    }

    @Test func aPastDayTheBandMissedSaysTheMinutesMayBeHigher() throws {
        let thursday = F.date(2023, 11, 16, 9, zone: Self.zone)
        let dose = try overview(input(days: bandDays, now: thursday)).dose
        // Wednesday is missing; Thursday is still being measured.
        #expect(dose.coverageNote == "The band missed 1 day this week, so your minutes may be higher.")
        #expect(try overview(input(days: bandDays)).dose.coverageNote == nil)
    }

    @Test func theDoseNamesWhereItsMinutesCameFrom() throws {
        #expect(try overview(input(days: bandDays)).dose.minutesSource == "Minutes from the band.")
        let mixed = [bandDays[0], DoseDay(day: F.day(2023, 11, 14), zones: F.zones(0, 48, 0, 0, 0), source: .appleHealth)]
        #expect(try overview(input(days: mixed)).dose.minutesSource == "Minutes from the band and Apple Health workouts.")
        #expect(try overview(input()).dose.minutesSource == nil)
    }

    // MARK: VO2 max

    func reading(_ value: Double, daysAgo: Double, yearsAgo: Int = 0, estimate: Bool = true) -> VO2MaxReading {
        let base = calendar.date(byAdding: .year, value: -yearsAgo, to: now)!
        return VO2MaxReading(value: value, date: base.addingTimeInterval(-daysAgo * 86_400), sourceLabel: "Apple Watch",
                             isConsumerEstimate: estimate)
    }

    var contractReadings: [VO2MaxReading] {
        [reading(41.3, daysAgo: 30, yearsAgo: 1), reading(41.5, daysAgo: 15, yearsAgo: 1), reading(41.7, daysAgo: 1, yearsAgo: 1),
         reading(43.8, daysAgo: 35), reading(44.1, daysAgo: 20), reading(44.4, daysAgo: 3)]
    }

    @Test func theGaugeReadsTheValueTheBandTheChangeAndTheCaveat() throws {
        guard case .gauge(let gauge) = try overview(input(vo2Max: .readings(contractReadings))).vo2Max else {
            Issue.record("Expected a gauge")
            return
        }
        #expect(gauge.valueText == "44.1")
        #expect(gauge.unitLine == "ml/kg/min")
        #expect(gauge.bandLine == "Top half for men aged 30 to 39")
        #expect(gauge.spokenLabel.hasPrefix("VO₂max 44.1 ml/kg/min. Top half for men aged 30 to 39."))
        #expect(gauge.sourceLabel == "Apple Watch")
        #expect(gauge.note == "Up 2.6 in 12 months. Last year's needle is the faint one. Watch estimates can be about 13 to 15% off, so Loopr reads the trend.")
        #expect(gauge.gauge.lastYearValue == 41.5)
        #expect(gauge.boundaries.map(\.percentile) == [10, 25, 50, 75])
        #expect(gauge.scale.lower == 20 && gauge.scale.upper == 60)
    }

    @Test func theAgeBarPinsTheRealAgeAndTheCardioAgeFromTheCalculator() throws {
        guard case .gauge(let gauge) = try overview(input(vo2Max: .readings(contractReadings))).vo2Max,
              let bar = gauge.ageBar else {
            Issue.record("Expected a gauge with an age bar")
            return
        }
        let expected = CardioAgeCalculator().calculate(vo2max: 44.1, referenceGroup: .male, curve: .version1, source: .healthKit,
                                                       calculationAge: 38)
        #expect(bar.realAge == 38 && bar.realLabel == "Real age 38" && bar.cardioPinLabel == "Cardio age 32")
        #expect(FitnessAgeBar.unitCaption == "Ages, in years")
        #expect(bar.cardioAge == expected.ageYears)
        #expect(bar.cardioLabel == "32")
        #expect(bar.axisLower == 20 && bar.axisUpper == 60 && bar.axisLabels == [20, 30, 40, 50, 60])
        #expect(abs(bar.fraction(for: 38) - 0.45) < 0.0001)
    }

    @Test func cardioAgeIsAbsentWhenTheCalculatorHasNone() {
        let unavailable = CardioAgeCalculator().calculate(vo2max: 44, referenceGroup: nil, curve: .version1)
        let bar = FitnessAgeBar.make(realAge: 38, cardio: unavailable)
        #expect(bar.cardioAge == nil && bar.cardioLabel == nil)
        #expect(bar.spokenLabel == "Your age 38. Cardio Age is not available.")
        let boundary = CardioAgeCalculator().calculate(vo2max: 60, referenceGroup: .male, curve: .version1, calculationAge: 38)
        #expect(FitnessAgeBar.make(realAge: 38, cardio: boundary).cardioLabel == "25 or younger")
    }

    @Test func theGaugeSaysWhatIsMissingForEachAbsence() throws {
        func sentence(_ input: FitnessOverviewInput) throws -> String? {
            if case .absent(let text) = try overview(input).vo2Max { return text }
            return nil
        }
        #expect(try sentence(input(vo2Max: .readings(contractReadings), birthYear: nil)) == FitnessVO2Max.needsAge)
        #expect(try sentence(input(vo2Max: .readings(contractReadings), group: nil)) == FitnessVO2Max.needsReferenceGroup)
        #expect(try sentence(input(vo2Max: .readings(contractReadings), birthYear: 1930)) == FitnessVO2Max.unsupportedAge)
        #expect(try sentence(input(vo2Max: .readings(Array(contractReadings.suffix(2))))) == FitnessVO2Max.notEnoughSamples)
        #expect(try sentence(input(vo2Max: .switchedOff)) == FitnessVO2Max.switchedOff)
        #expect(try sentence(input(vo2Max: .unavailable)) == FitnessVO2Max.unavailable)
    }

    @Test func withoutLastYearTheNoteSaysSoAndALabValueHasNoCaveat() throws {
        let lab = [reading(43.8, daysAgo: 35, estimate: false), reading(44.1, daysAgo: 20, estimate: false),
                   reading(44.4, daysAgo: 3, estimate: false)]
        guard case .gauge(let gauge) = try overview(input(vo2Max: .readings(lab))).vo2Max else {
            Issue.record("Expected a gauge")
            return
        }
        #expect(gauge.note == "A year ago there were too few readings for last year's needle.")
    }

    // MARK: Capacity

    /// 16 October 2023, 08:00 in Perth.
    let tested = F.date(2023, 10, 16, 8, zone: "Australia/Perth")

    func result(_ kind: CapacityTestKind, _ value: Double, side: CapacitySide? = nil) throws -> CapacityResult {
        try CapacityResult(kind: kind, value: value, side: side, recordedAt: tested, timeZoneIdentifier: Self.zone)
    }

    /// R2-OPT-19: a new sit to stand score under the last one says what the last one was.
    @Test func aNewerResultShowsThePreviousOne() throws {
        let earlier = try CapacityResult(kind: .sitToStand, value: 10, recordedAt: tested, timeZoneIdentifier: Self.zone)
        let later = try CapacityResult(kind: .sitToStand, value: 9.5, recordedAt: now.addingTimeInterval(-3_600),
                                       timeZoneIdentifier: Self.zone)
        let sit = try #require(try overview(input(results: [earlier, later])).capacity.first { $0.kind == .sitToStand })
        #expect(sit.valueText == "9.5")
        #expect(sit.previousLine == "Was 10/10")
        let single = try #require(try overview(input(results: [earlier])).capacity.first { $0.kind == .sitToStand })
        #expect(single.previousLine == nil)
    }

    @Test func theFourInstrumentsShowTodaysBestTheirRetestAndAWarningOnlyUnderTheGoal() throws {
        let results = [try result(.grip, 52, side: .right), try result(.grip, 49, side: .left), try result(.deadHang, 84),
                       try result(.sitToStand, 10), try result(.oneLegBalance, 18, side: .left)]
        let goals = [CapacityTestKind.grip: try CapacityGoal(kind: .grip, targetValue: 30, setAt: tested),
                     .oneLegBalance: try CapacityGoal(kind: .oneLegBalance, targetValue: 30, setAt: tested)]
        let monthly = try #require(CapacityCadence(count: 1, unit: .month))
        let cadences = Dictionary(uniqueKeysWithValues: CapacityTestKind.allCases.filter(\.isRetestable).map { ($0, monthly) })
        let tiles = try overview(input(results: results, goals: goals, cadences: cadences)).capacity
        #expect(tiles.map(\.kind) == [.grip, .deadHang, .sitToStand, .oneLegBalance])

        let grip = tiles[0], hang = tiles[1], sit = tiles[2], balance = tiles[3]
        #expect(grip.valueText == "52" && grip.unitText == "kg" && !grip.isBelowGoal)
        #expect(grip.retestLine == "Retest 16 Nov")
        #expect(grip.history.count == 2)
        #expect(grip.history.first?.dateText == "16 Oct 2023")
        #expect(Set(grip.history.compactMap(\.sideText)) == ["Right hand", "Left hand"])
        #expect(abs((grip.fraction ?? 0) - 52.0 / 80) < 0.0001)

        #expect(hang.valueText == "1:24" && hang.unitText == nil)
        #expect(hang.spokenLabel == "Dead hang, 1 minute 24 seconds, Retest 16 Nov")
        #expect(abs((hang.fraction ?? 0) - 0.7) < 0.0001)

        #expect(sit.valueText == "10" && sit.unitText == "/10" && sit.fraction == 1)

        #expect(balance.valueText == "18" && balance.unitText == "s")
        #expect(balance.isBelowGoal)
        #expect(abs((balance.fraction ?? 0) - 0.6) < 0.0001 && balance.goalFraction == 1)
        // R2-OPT-17: the line says whose goal it is and the number.
        #expect(balance.spokenLabel.contains("Under the goal you set for age 85, 30 seconds"))
        #expect(balance.belowGoalLine == "Your goal at 85: 30 s")
        #expect(hang.belowGoalLine == nil)
        #expect(balance.history.first?.sourceText == "Timed on this iPhone")
    }

    @Test func anUntestedInstrumentIsAbsentAndARuleWithoutAResultIsDue() throws {
        let monthly = try #require(CapacityCadence(count: 1, unit: .month))
        let tiles = try overview(input(cadences: [.grip: monthly])).capacity
        #expect(tiles[0].valueText == nil && tiles[0].fraction == nil)
        #expect(tiles[0].retestLine == "Test due")
        #expect(tiles[1].retestLine == nil)
        #expect(tiles[1].spokenLabel == "Dead hang, Needs a bar")
        // The two tests that need no gear read as invitations. Heart rate recovery says where its number comes from.
        #expect(tiles[2].untestedLine == "Try it · about 2 min" && tiles[2].isInvitation && !tiles[1].isInvitation)
        #expect(tiles[2].spokenLabel == "Sit to stand, Try it · about 2 min. No gear needed")
        #expect(!tiles.contains { $0.isBelowGoal })
        let recovery = try overview(input()).heartRateRecovery
        #expect(recovery.untestedLine == "Not read yet" && recovery.untestedDetail == "Appears after a workout with heart rate.")
        #expect(recovery.spokenLabel == "Heart rate recovery, Not read yet. Appears after a workout with heart rate.")
    }

    @Test func aRetestDatePassedReadsDue() throws {
        let monthly = try #require(CapacityCadence(count: 1, unit: .month))
        let december = F.date(2023, 12, 1, 9, zone: Self.zone)
        let tiles = try overview(input(results: [try result(.deadHang, 84)], cadences: [.deadHang: monthly], now: december)).capacity
        #expect(tiles[1].retestLine == "Test due")
    }

    @Test func halfPointsAndMinutesFormatAsTheyRead() {
        #expect(FitnessOverview.valueText(.sitToStand, 9.5) == "9.5")
        #expect(FitnessOverview.valueText(.deadHang, 125) == "2:05")
        #expect(FitnessOverview.valueText(.deadHang, 9) == "0:09")
        #expect(FitnessOverview.instrumentScale(.deadHang, best: 150, goal: nil) == 180)
        #expect(FitnessOverview.instrumentScale(.grip, best: 92, goal: nil) == 100)
    }
}
