import AnalyticsKit
import DomainKit
import Foundation
import Testing
@testable import WorkoutKit

@Suite("Workout page")
struct WorkoutPageTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let zones = ActivityAnalytics.zones(maxHR: 190, source: .agePredicted).value

    private func record(_ activity: ActivityType, minutes: Double, samples: [WorkoutSample] = [], source: WorkoutSource = .live,
                        lengths: Int? = nil, title: String? = nil, windows: [WorkoutEffortWindow]? = nil, pauses: [WorkoutPause]? = nil) -> WorkoutRecord {
        WorkoutRecord(id: UUID(), identity: .init(canonicalKey: UUID().uuidString), activity: activity, source: source, state: .completed,
                      createdAt: Self.start, startedAt: Self.start, endedAt: Self.start.addingTimeInterval(minutes * 60), samples: samples,
                      finalizationStage: .activeStateCleared, pauses: pauses, title: title, lengths: lengths, poolLengthMeters: lengths == nil ? nil : 25, effortWindows: windows)
    }

    private func series(minutes: Double, every seconds: Double = 5, bpm: (Double) -> Int) -> [WorkoutSample] {
        stride(from: 0.0, to: minutes * 60, by: seconds).map {
            WorkoutSample(timestamp: Self.start.addingTimeInterval($0), heartRate: bpm($0))
        }
    }

    // MARK: Heart rate

    @Test func averagePeakAndZonesComeFromTheSamples() throws {
        let zones = try #require(Self.zones)
        let zoneTwoBPM = Int(zones.zones[1].lowerBPM) + 2
        let workout = record(.run, minutes: 10, samples: series(minutes: 10) { $0 < 300 ? zoneTwoBPM : zoneTwoBPM + 4 })
        let analysis = WorkoutSessionAnalysis(workout: workout, zones: zones)
        #expect(analysis.averageBPM == zoneTwoBPM + 2)
        #expect(analysis.peakBPM == zoneTwoBPM + 4)
        #expect(analysis.source == .live)
        #expect(abs(analysis.coveredSeconds - 600) <= 5)
        #expect(abs((analysis.secondsInZones[2] ?? 0) - 600) <= 5)
        #expect(!analysis.coverageIsPartial)
    }

    @Test func aGapIsNotTimeAtTheLastReadingAndTheCoverageSaysSo() {
        let samples = series(minutes: 10) { _ in 130 } + series(minutes: 10) { _ in 130 }.map {
            WorkoutSample(timestamp: $0.timestamp.addingTimeInterval(1_800), heartRate: $0.heartRate)
        }
        let analysis = WorkoutSessionAnalysis(workout: record(.run, minutes: 40, samples: samples))
        #expect(analysis.coveredSeconds < 1_250)
        #expect(analysis.coverageIsPartial)
    }

    @Test func aPausedStretchIsLeftOut() {
        let pause = WorkoutPause(start: Self.start.addingTimeInterval(300), end: Self.start.addingTimeInterval(600))
        let workout = record(.run, minutes: 10, samples: series(minutes: 10) { $0 >= 300 && $0 < 600 ? 90 : 150 }, pauses: [pause])
        let analysis = WorkoutSessionAnalysis(workout: workout)
        #expect(analysis.averageBPM == 150)
    }

    @Test func aSessionWithNoSamplesReadsBandHistoryAndSaysWhereItCameFrom() {
        let history = WorkoutHeartSeries(samples: (0..<120).map {
            WorkoutHeartSample(date: Self.start.addingTimeInterval(Double($0) * 5), bpm: 120)
        }, source: .bandHistory)
        let analysis = WorkoutSessionAnalysis(workout: record(.swim, minutes: 10, source: .manual), history: history)
        #expect(analysis.source == .bandHistory)
        #expect(analysis.averageBPM == 120)
    }

    @Test func noHeartRateAtAllLeavesEveryNumberAbsentNotZero() {
        let analysis = WorkoutSessionAnalysis(workout: record(.yoga, minutes: 30, source: .manual))
        #expect(!analysis.hasHeartRate)
        #expect(analysis.averageBPM == nil)
        #expect(analysis.peakBPM == nil)
        #expect(analysis.strain == nil)
        let page = WorkoutPagePresentation(workout: record(.yoga, minutes: 30, source: .manual), analysis: analysis, route: nil)
        #expect(page.sentence == "No heart rate for this session. The band had no reading.")
    }

    @Test func impossibleReadingsAreDropped() {
        let series = WorkoutHeartSeries(samples: [.init(date: Self.start, bpm: 0), .init(date: Self.start, bpm: 900), .init(date: Self.start, bpm: .nan),
                                                  .init(date: Self.start, bpm: 88)], source: .live)
        #expect(series.samples.map(\.bpm) == [88])
    }

    // MARK: Drift

    @Test func driftComparesTheHalvesAfterTenMinutes() throws {
        // 40 settled minutes after the warm-up: 130 then 136.
        let workout = record(.cycle, minutes: 50, samples: series(minutes: 50) { $0 < 600 ? 100 : $0 < 1_800 ? 130 : 136 })
        let drift = try #require(WorkoutSessionAnalysis(workout: workout).drift)
        #expect(abs(drift.firstHalfBPM - 130) < 0.5)
        #expect(abs(drift.secondHalfBPM - 136) < 0.5)
        #expect(abs(drift.percent - 4.6) < 0.2)
    }

    @Test func driftNeedsThirtySettledMinutesAndASteadySession() {
        #expect(WorkoutSessionAnalysis(workout: record(.cycle, minutes: 35, samples: series(minutes: 35) { _ in 130 })).drift == nil)
        #expect(WorkoutSessionAnalysis(workout: record(.strength, minutes: 60, samples: series(minutes: 60) { _ in 130 })).drift == nil)
        #expect(WorkoutSessionAnalysis(workout: record(.yoga, minutes: 60, samples: series(minutes: 60) { _ in 90 })).drift == nil)
    }

    // MARK: Efforts

    @Test func hiitEffortsAreFoundByThePrintedRule() {
        // Four-minute waves between 120 and 170.
        let samples = series(minutes: 16) { second in
            let phase = second.truncatingRemainder(dividingBy: 240) / 240
            return 120 + Int(sin(phase * .pi) * 50)
        }
        let analysis = WorkoutSessionAnalysis(workout: record(.hiit, minutes: 16, samples: samples))
        #expect(analysis.effortsAreFound)
        #expect(analysis.efforts.count == 4)
        #expect(analysis.efforts.allSatisfy { $0.peakBPM >= 165 })
        #expect(analysis.efforts.first?.dropBPM != nil)
    }

    @Test func aFlatSessionHasNoEffortsAndARunNeverLooksForThem() {
        #expect(WorkoutSessionAnalysis(workout: record(.hiit, minutes: 16, samples: series(minutes: 16) { _ in 120 })).efforts.isEmpty)
        let waves = series(minutes: 16) { 120 + Int(sin($0 / 240 * .pi) * 50) }
        #expect(WorkoutSessionAnalysis(workout: record(.run, minutes: 16, samples: waves)).efforts.isEmpty)
    }

    @Test func timerPhasesBecomeEffortsWithPeakAndDrop() throws {
        let window = WorkoutEffortWindow(round: 1, start: Self.start.addingTimeInterval(60), end: Self.start.addingTimeInterval(300))
        let samples = series(minutes: 10) { second in second < 60 ? 110 : second < 300 ? 170 : 130 }
        let analysis = WorkoutSessionAnalysis(workout: record(.hiit, minutes: 10, samples: samples, windows: [window]))
        let effort = try #require(analysis.efforts.first)
        #expect(!analysis.effortsAreFound)
        #expect(effort.peakBPM == 170)
        #expect(effort.seconds == 240)
        #expect(effort.dropBPM != nil)
    }

    // MARK: The page per type

    @Test func onlyRouteActivitiesHaveAMap() {
        for activity in ActivityType.allCases {
            let hasMap = WorkoutPagePresentation.modules(activity: activity, hasTarget: false).contains(.map)
            #expect(hasMap == activity.recordsRoute, "\(activity)")
        }
    }

    @Test func aRouteTooThinToDrawIsTreatedAsNoRoute() {
        let thin = WorkoutPageRoute(segments: [], distanceMeters: 800, movingSeconds: 60, elapsedSeconds: 60, ascentMeters: nil, descentMeters: nil,
                                    highestMeters: nil, gapSeconds: 0, splits: [], elevation: [], pointCount: 2)
        #expect(!thin.canBeDrawn)
        let workout = record(.run, minutes: 30, samples: series(minutes: 30) { _ in 140 })
        let page = WorkoutPagePresentation(workout: workout, analysis: WorkoutSessionAnalysis(workout: workout), route: thin)
        #expect(page.companions.first?.label != "Moving")
        #expect(page.headlineValue != "800")
    }

    @Test func aRunLeadsWithDistanceThenTimeAndPace() {
        let route = WorkoutPageRoute(segments: [], distanceMeters: 5_000, movingSeconds: 1_500, elapsedSeconds: 1_600, ascentMeters: 10, descentMeters: 10,
                                     highestMeters: 50, gapSeconds: 0, splits: [], elevation: [], pointCount: 300)
        let workout = record(.run, minutes: 27, samples: series(minutes: 27) { _ in 140 })
        let page = WorkoutPagePresentation(workout: workout, analysis: WorkoutSessionAnalysis(workout: workout), route: route)
        #expect(page.headlineValue == "5.0")
        #expect(page.headlineUnit == "km")
        #expect(page.companions.map(\.label) == ["Moving", "Pace", "Average"])
        #expect(page.companions[1].value == "5:00")
    }

    @Test func aRideShowsSpeedNotPace() {
        let companion = WorkoutPagePresentation.speedCompanion(activity: .cycle, meters: 30_000, seconds: 3_600, system: .metric)
        #expect(companion?.label == "Speed")
        #expect(companion?.value == "30.0")
    }

    @Test func aSwimUsesTypedLengths() {
        let swim = record(.swim, minutes: 36, source: .manual, lengths: 48)
        let page = WorkoutPagePresentation(workout: swim, analysis: WorkoutSessionAnalysis(workout: swim), route: nil)
        #expect(page.headlineValue == "1.2")
        #expect(page.companions.contains { $0.label == "Pace" && $0.unit == "/100 m" })
    }

    @Test func theSentenceNamesTheZoneWithoutPraise() throws {
        let zones = try #require(Self.zones)
        let bpm = Int(zones.zones[1].lowerBPM) + 2
        let workout = record(.walk, minutes: 30, samples: series(minutes: 30) { _ in bpm })
        let page = WorkoutPagePresentation(workout: workout, analysis: WorkoutSessionAnalysis(workout: workout, zones: zones), route: nil)
        #expect(page.sentence == "All 30 min in Zone 2, easy.")
    }

    @Test func theRowAddsPaceOrLengthsAndNeverAZero() {
        let line = { (workout: WorkoutRecord) in WorkoutSessionPresentation.detailLine(for: workout)?.lowercased() ?? "" }
        let run = record(.run, minutes: 30, samples: [.init(timestamp: Self.start.addingTimeInterval(1_800), distanceMeters: 6_000)])
        #expect(line(run).contains("6.0 km") && line(run).contains("5:00 /km"), "\(line(run))")
        #expect(line(record(.swim, minutes: 36, source: .manual, lengths: 48)).contains("1.2 km"))
        #expect(!line(record(.yoga, minutes: 30)).contains("0 km"))
    }

    // MARK: Chart

    @Test func theChartScaleIsAlwaysARealRange() {
        #expect(WorkoutEffortChart.domain(for: [120, 165]) == 110...180)
        #expect(WorkoutEffortChart.domain(for: []) == 50...190)
        // A calm session draws calm, and readings at the very bottom and top of what is kept still make a range.
        #expect(WorkoutEffortChart.domain(for: [100, 106]) == 90...130)
        #expect(WorkoutEffortChart.domain(for: [25]) == 30...70)
        #expect(WorkoutEffortChart.domain(for: [250]) == 240...280)
    }

    // MARK: Comparison

    @Test func theComparisonUsesMovingTimeWhenItHasItAndSaysWhenItDoesNot() {
        let start = Self.start
        let run = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "r"), activity: .run, source: .live, state: .completed, createdAt: start,
                                startedAt: start, endedAt: start.addingTimeInterval(1_800),
                                samples: [.init(timestamp: start.addingTimeInterval(1_800), distanceMeters: 5_000)], finalizationStage: .activeStateCleared)
        #expect(WorkoutComparison.line(previous: run, averageBPM: nil, movingSeconds: 1_500)?.contains("5:00 /km") == true)
        #expect(WorkoutComparison.line(previous: run, averageBPM: nil)?.contains("6:00 /km elapsed") == true)
    }

    @Test func aRowerGetsASplitPer500Metres() {
        let split = WorkoutPagePresentation.speedCompanion(activity: .rowing, meters: 6_000, seconds: 1_500, system: .metric)
        #expect(split?.value == "2:05" && split?.unit == "/500 m")
    }

    @Test func aTargetSessionDoesNotSayItsMinutesAThirdTime() throws {
        let zones = try #require(Self.zones)
        let target = try #require(WorkoutZoneTarget(preference: WorkoutZoneAlertPreference(target: .zoneTwo), zones: zones,
                                                    zoneTwo: ZoneTwoRange(lower: 110, upper: 130, source: .maximumHeartRate)))
        var workout = record(.cycle, minutes: 30, samples: series(minutes: 30) { _ in 120 })
        workout.zoneTargetChanges = [.init(at: Self.start, target: target)]
        let page = WorkoutPagePresentation(workout: workout, analysis: WorkoutSessionAnalysis(workout: workout, zones: zones), route: nil)
        #expect(page.headlineUnit == "min in Zone 2")
        #expect(page.sentence == nil)
    }

    @Test func theComparisonFindsTheLastSessionOfASimilarSize() {
        func run(_ daysAgo: Double, meters: Double) -> WorkoutRecord {
            let start = Self.start.addingTimeInterval(-daysAgo * 86_400)
            return WorkoutRecord(id: UUID(), identity: .init(canonicalKey: UUID().uuidString), activity: .run, source: .live, state: .completed,
                                 createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(1_800),
                                 samples: [.init(timestamp: start.addingTimeInterval(1_800), distanceMeters: meters)], finalizationStage: .activeStateCleared)
        }
        let current = run(0, meters: 5_000)
        let near = run(4, meters: 5_200), far = run(2, meters: 10_000), older = run(9, meters: 5_000)
        let found = WorkoutComparison.similar(to: current, in: [far, older, near, current])
        #expect(found?.id == near.id)
        let line = WorkoutComparison.line(previous: near, averageBPM: 148) ?? ""
        #expect(line.hasPrefix("Last similar run"))
        #expect(line.contains("5.2 km") && line.contains("148 bpm"))
        #expect(!line.lowercased().contains("better") && !line.lowercased().contains("worse"))
    }

    // MARK: Records

    @Test func factsAndPhasesSurviveTheListRow() throws {
        let window = WorkoutEffortWindow(round: 1, start: Self.start, end: Self.start.addingTimeInterval(60))
        let workout = record(.hiit, minutes: 10, samples: series(minutes: 10) { _ in 130 }, title: "Friday", windows: [window])
        let data = try JSONEncoder().encode(workout)
        let row = try JSONDecoder().decode(WorkoutListingRowDocument.self, from: data).row
        #expect(row.title == "Friday")
        #expect(row.effortWindows == [window])
        #expect(row == workout.listingRow)
    }

    @Test func anOldRecordWithoutTheNewFieldsStillDecodes() throws {
        let workout = record(.run, minutes: 5)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workout)) as? [String: Any])
        object["lengths"] = nil
        object["effortWindows"] = nil
        let decoded = try JSONDecoder().decode(WorkoutRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.lengths == nil && decoded.effortWindows == nil)
    }

    @Test func effortSavesOnlyTheEffort() async throws {
        let workout = record(.swim, minutes: 30, source: .manual)
        let controller = WorkoutSessionController(store: InMemoryWorkoutStore(workouts: [workout]))
        let saved = try await controller.setEffort(id: workout.id, effort: 7)
        #expect(saved.effort == 7)
        #expect(saved.endedAt == workout.endedAt && saved.activity == workout.activity)
        await #expect(throws: (any Error).self) { try await controller.setEffort(id: workout.id, effort: 11) }
    }

    @Test func lengthsAndCaloriesAreTypedForTheTypesThatTakeThem() throws {
        let end = Self.start.addingTimeInterval(1_800)
        let swim = try WorkoutLogEntry(activity: .swim, startedAt: Self.start, endedAt: end, lengths: 40, poolLengthMeters: 50).validated(allowingFuture: true)
        #expect(swim.lengths == 40 && swim.poolLengthMeters == 50)
        let run = try WorkoutLogEntry(activity: .run, startedAt: Self.start, endedAt: end, lengths: 40, calories: 300).validated(allowingFuture: true)
        #expect(run.lengths == nil && run.calories == nil)
        let row = try WorkoutLogEntry(activity: .rowing, startedAt: Self.start, endedAt: end, calories: 0).validated(allowingFuture: true)
        #expect(row.calories == nil)
    }

    @Test func aFinishedIntervalSessionBecomesARecordWithItsPhases() throws {
        let schedule = IntervalSchedule(configuration: .init(workSeconds: 240, restSeconds: 180, rounds: 4), startedAt: Self.start)
        let result = IntervalSessionResult(schedule: schedule, endedAt: schedule.endsAt, samples: series(minutes: 28) { _ in 150 })
        let workout = try #require(result.record(title: "Norwegian 4x4"))
        #expect(workout.activity == .hiit)
        #expect(workout.effortWindows?.count == 4)
        #expect(workout.title == "Norwegian 4x4")
        #expect(workout.samples.count == 336)
        let early = IntervalSessionResult(schedule: schedule, endedAt: Self.start.addingTimeInterval(30), samples: [])
        #expect(early.record(title: "x") == nil)
    }

    @Test func theHeartRateCSVHasOneRowPerReading() {
        let file = WorkoutCSVFile.heartRate(samples: [.init(date: Self.start, bpm: 120), .init(date: Self.start.addingTimeInterval(5), bpm: 121.4)], startedAt: Self.start)
        let lines = file.text.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == "time_utc,seconds_from_start,bpm")
        #expect(lines[2].hasSuffix(",5,121"))
        #expect(file.filename == "heart-rate-2023-11-14.csv")
    }
}
