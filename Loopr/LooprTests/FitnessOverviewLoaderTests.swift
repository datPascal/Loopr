import AnalyticsKit
import BodyKit
import DomainKit
import Foundation
import HealthKitBridge
import ProfileKit
import RoutineKit
import Testing
import TrainKit
import WorkoutKit
@testable import Loopr

private let perth = "Australia/Perth"
private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: perth)!
    return calendar
}
/// Tuesday 2023-11-14, 10:00 in Perth.
private let now = Date(timeIntervalSince1970: 1_699_927_200)

private func perthDate(_ day: Int, hour: Int = 17) -> Date {
    calendar.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour))!
}

private func zones(_ minutes: [Double], ids: [Int] = [1, 2, 3, 4, 5]) -> [BodyZoneMinutes] {
    zip(ids, minutes).map { BodyZoneMinutes(id: $0.0, name: "Zone \($0.0)", minutes: $0.1) }
}

private func workout(_ activity: ActivityType, start: Date, state: WorkoutLifecycleState = .completed, id: UUID = UUID(),
                     importedName: String? = nil) -> WorkoutRecord {
    var record = WorkoutRecord(id: id, identity: WorkoutIdentity(canonicalKey: "w-\(id)"), activity: activity, source: .manual,
                               state: state, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(3_600))
    if let importedName { record.importedSummary = WorkoutImportedSummary(source: "whoop", activityName: importedName) }
    return record
}

private func vo2Sample(_ value: Double, at date: Date, typedIn: Bool = false) -> AppleHealthSample {
    AppleHealthSample(kind: .vo2Max, value: value, original: AppleHealthOriginalReading(value: value, unit: .mlPerKgPerMin),
                      start: date, end: date,
                      provenance: AppleHealthProvenance(sourceName: "Alex's Apple Watch", sourceBundleIdentifier: "com.apple.health.X",
                                                        deviceName: "Apple Watch", wasUserEntered: typedIn))
}

/// The Fitness loader's mapping from the app's stored data onto TrainKit's inputs, with fake sources.
struct FitnessOverviewLoaderTests {
    // MARK: Band days

    @Test func fiveZonesByIDBecomeBandMinutes() {
        let mapped = FitnessInputMapping.zones(zones([30, 64, 20, 6, 3]))
        #expect(mapped?.zone2 == 64 && mapped?.hard == 9)
        // Out of order ids still map by id.
        let shuffled = FitnessInputMapping.zones(zones([3, 6, 20, 64, 30], ids: [5, 4, 3, 2, 1]))
        #expect(shuffled?.zone2 == 64)
    }

    @Test func noZonesOrMissingZonesAreNoDataNotZero() {
        #expect(FitnessInputMapping.zones(nil) == nil)
        #expect(FitnessInputMapping.zones([]) == nil)
        #expect(FitnessInputMapping.zones(zones([30, 64, 20, 6], ids: [1, 2, 3, 4])) == nil)
        #expect(FitnessInputMapping.zones(zones([30, 64, 20, 6, .nan])) == nil)
    }

    @Test func onlyDaysUpToTodayAreRead() throws {
        let week = try #require(ISOWeek(containing: now, calendar: calendar))
        #expect(FitnessInputMapping.daysToRead(week: week, now: now, calendar: calendar)
                == [DayIdentity(year: 2023, month: 11, day: 13), DayIdentity(year: 2023, month: 11, day: 14)])
    }

    // MARK: Sessions

    @Test func aGymSessionAndItsWorkoutCountOnce() throws {
        let workoutID = UUID()
        let gym = try TrainSession(workoutID: workoutID, name: "Lower A", startedAt: perthDate(13), timeZoneIdentifier: perth,
                                   endedAt: perthDate(13, hour: 18), status: .completed)
        let sessions = FitnessInputMapping.sessions(train: [gym], workouts: [workout(.strength, start: perthDate(13), id: workoutID)])
        let week = try #require(ISOWeek(containing: now, calendar: calendar))
        let dose = WeeklyDose.make(week: week, days: [], sessions: sessions)
        #expect(sessions.count == 2)
        #expect(dose.strength.count == 1)
    }

    @Test func yogaAndImportedMobilityCountAndUnfinishedWorkoutsDoNot() throws {
        let workouts = [
            workout(.yoga, start: perthDate(13)),
            workout(.other, start: perthDate(14, hour: 7), importedName: "Pilates"),
            workout(.run, start: perthDate(14, hour: 8), importedName: "Running"),
            workout(.strength, start: perthDate(14, hour: 9), state: .active)
        ]
        let sessions = FitnessInputMapping.sessions(train: [], workouts: workouts)
        let week = try #require(ISOWeek(containing: now, calendar: calendar))
        let dose = WeeklyDose.make(week: week, days: [], sessions: sessions)
        #expect(dose.mobility.count == 2)
        #expect(dose.strength.count == 0)
        #expect(sessions.count == 3)
    }

    // MARK: Apple Health and profile

    @Test func vo2MaxReadsKeepTheirSourceAndTheirAbsence() {
        let sample = vo2Sample(44.1, at: now)
        guard case .readings(let readings) = FitnessInputMapping.vo2Max(.values([sample])) else {
            Issue.record("Expected readings")
            return
        }
        #expect(readings.first?.sourceLabel == "Apple Watch")
        #expect(readings.first?.isConsumerEstimate == true)
        #expect(FitnessInputMapping.vo2Max(.absent(.switchedOff)) == .switchedOff)
        #expect(FitnessInputMapping.vo2Max(.absent(.unavailable)) == .unavailable)
        #expect(FitnessInputMapping.vo2Max(.absent(.noSamples)) == .readings([]))
        #expect(FitnessInputMapping.vo2Max(.absent(.notAuthorized)) == .readings([]))
        #expect(FitnessInputMapping.vo2Max(nil) == .readings([]))
    }

    @Test func aValueTypedIntoAppleHealthIsNotAWatchEstimate() {
        let typed = FitnessInputMapping.reading(vo2Sample(47, at: now, typedIn: true))
        #expect(typed?.isConsumerEstimate == false)
        #expect(typed?.sourceLabel == "Typed into Apple Health")
        #expect(FitnessInputMapping.reading(vo2Sample(0, at: now)) == nil)
    }

    @Test func theWindowHoldsLastYearsFortyTwoDays() {
        let window = FitnessInputMapping.vo2MaxWindow(now: now, calendar: calendar)
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: now)!
        #expect(window.to == now)
        #expect(window.from <= yearAgo.addingTimeInterval(-42 * 86_400))
    }

    @Test func onlyTheFemaleAndMaleCurvesExist() {
        #expect(FitnessInputMapping.referenceGroup(.female) == .female)
        #expect(FitnessInputMapping.referenceGroup(.male) == .male)
        #expect(FitnessInputMapping.referenceGroup(.intersex) == nil)
        #expect(FitnessInputMapping.referenceGroup(.undisclosed) == nil)
        #expect(FitnessInputMapping.referenceGroup(nil) == nil)
    }

    // MARK: Whole input

    @Test func fakeSourcesBuildTheWholeOverview() async throws {
        let rule = ProtocolRule(key: "zone2", title: "Zone 2", group: .fitness,
                                target: RuleTarget(kind: .atLeast, metric: DoseTargets.zone2MinutesMetric, value: 180, unit: "min"),
                                source: .band, cadence: RuleCadence(unit: .week))
        let grip = try CapacityResult(kind: .grip, value: 52, side: .right, recordedAt: perthDate(1), timeZoneIdentifier: perth)
        let sources = FitnessSources(
            bandDay: { day in day.day == 13 ? zones([30, 64, 20, 6, 3]) : day.day == 14 ? zones([30, 48, 20, 5, 2]) : nil },
            vo2Max: { _, _ in .values([vo2Sample(43.8, at: now.addingTimeInterval(-35 * 86_400)),
                                       vo2Sample(44.1, at: now.addingTimeInterval(-20 * 86_400)),
                                       vo2Sample(44.4, at: now.addingTimeInterval(-3 * 86_400))]) },
            profile: { FitnessProfile(birthYear: 1985, biologicalSex: .male) },
            rules: { [rule] },
            capacity: { FitnessCapacityRecords(results: [grip]) })
        let input = await FitnessInputMapping.input(sources: sources, now: now, calendar: calendar, train: [], workouts: [])
        #expect(input.age == 38 && input.referenceGroup == .male)
        #expect(input.targets.zone2Minutes == 180 && input.targets.hardMinutes == nil)
        let overview = try #require(FitnessOverview.make(input))
        #expect(overview.dose.zone2.minutes == 112 && overview.dose.zone2.suffix == " of 180 min")
        #expect(overview.dose.hard.minutes == 16 && overview.dose.hard.suffix == " min · no target")
        guard case .gauge(let gauge) = overview.vo2Max else {
            Issue.record("Expected a gauge")
            return
        }
        #expect(gauge.valueText == "44.1")
        #expect(overview.capacity.first?.valueText == "52")
    }

    @Test func missingSourcesGiveAbsentStatesNotZeros() async throws {
        let input = await FitnessInputMapping.input(sources: FitnessSources(), now: now, calendar: calendar, train: [], workouts: [])
        let overview = try #require(FitnessOverview.make(input))
        #expect(overview.dose.bandAbsence == FitnessDose.absentSentence)
        #expect(overview.dose.zone2.minutes == nil)
        #expect(overview.vo2Max == .absent(FitnessVO2Max.needsAge))
        #expect(overview.capacity.allSatisfy { $0.valueText == nil && $0.retestLine == nil })
    }

    @Test func theFixtureMatchesTheContractPhone() async throws {
        let input = await FitnessInputMapping.input(sources: FitnessFixtures.sources, now: AppTrainFixtures.now,
                                                    calendar: AppTrainFixtures.calendar, train: [], workouts: [])
        let overview = try #require(FitnessOverview.make(input))
        #expect(overview.meta == "6 days left this week")
        #expect(overview.dose.zone2.minutes == 112 && overview.dose.zone2.suffix == " of 180 min")
        #expect(overview.dose.hard.minutes == 16 && overview.dose.hard.suffix == " of 20 min")
        guard case .gauge(let gauge) = overview.vo2Max else {
            Issue.record("Expected a gauge")
            return
        }
        #expect(gauge.valueText == "44.1" && gauge.unitLine == "ml/kg/min" && gauge.bandLine == "Top half for men aged 30 to 39")
        #expect(gauge.note.hasPrefix("Up 2.6 in 12 months."))
        #expect(gauge.sourceLabel == "Apple Watch")
        #expect(overview.capacity.map(\.valueText) == ["52", "1:24", "10", "18"])
        #expect(overview.capacity.last?.isBelowGoal == true)
        #expect(overview.capacity.first?.retestLine == "Retest 16 Nov")
    }

    @MainActor
    @Test func theLoaderPublishesTheOverview() async {
        let loader = FitnessOverviewLoader()
        #expect(loader.overview == nil)
        await loader.load(sources: FitnessFixtures.sources, now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar,
                          train: [], workouts: [])
        #expect(loader.overview?.dose.weekKey == "2023-W46")
    }
}
