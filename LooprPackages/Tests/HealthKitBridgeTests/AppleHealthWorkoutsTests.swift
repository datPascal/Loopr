import Foundation
@testable import HealthKitBridge
import XCTest
#if canImport(HealthKit)
import HealthKit
#endif

// R1-VET-01: workouts other apps saved to Apple Health, read with their source. Every test runs against a fake
// store. No test calls HealthKit.

private actor FakeAppleHealthWorkoutStore: AppleHealthWorkoutStore {
    var accessValue: AppleHealthStoreAccess = .requested
    /// Nil is "no other app saved a workout", which is also what a declined read looks like.
    var workoutsValue: [AppleHealthRawWorkout]? = []
    var heartRateValue: [AppleHealthRawHeartRate] = []
    var failure: AppleHealthStoreError?
    private(set) var heartRateQueries = 0
    private(set) var excludedSeen: [[String]] = []

    func set(access: AppleHealthStoreAccess) { accessValue = access }
    func set(workouts: [AppleHealthRawWorkout]?) { workoutsValue = workouts }
    func set(heartRate: [AppleHealthRawHeartRate]) { heartRateValue = heartRate }
    func set(failure: AppleHealthStoreError?) { self.failure = failure }

    func access() async -> AppleHealthStoreAccess { accessValue }

    func workouts(from start: Date, to end: Date, limit: Int,
                  excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawWorkout]? {
        excludedSeen.append(excludingBundlePrefixes)
        if let failure { throw failure }
        return workoutsValue
    }

    func heartRate(from start: Date, to end: Date, limit: Int,
                   excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawHeartRate] {
        heartRateQueries += 1
        if let failure { throw failure }
        return heartRateValue
    }
}

private let base = Date(timeIntervalSince1970: 1_699_920_000)
private let garmin = AppleHealthProvenance(sourceName: "Garmin Connect", sourceBundleIdentifier: "com.garmin.connect.mobile")
private let watch = AppleHealthProvenance(sourceName: "Dev's Apple Watch", sourceBundleIdentifier: "com.apple.health.1234",
                                          deviceName: "Apple Watch")

private func raw(_ id: Int, activity: AppleHealthWorkoutActivity = .cycle, start: TimeInterval = 0, minutes: Double = 52,
                 provenance: AppleHealthProvenance = garmin, distance: Double? = 24_000, energy: Double? = 500,
                 average: Double? = nil, maximum: Double? = nil, sync: String? = nil,
                 keys: Set<String> = []) -> AppleHealthRawWorkout {
    AppleHealthRawWorkout(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!,
                          activity: activity, activityName: "Cycling", start: base.addingTimeInterval(start),
                          end: base.addingTimeInterval(start + minutes * 60), distanceMeters: distance, energyKcal: energy,
                          averageHeartRate: average, maximumHeartRate: maximum, provenance: provenance,
                          syncIdentifier: sync, metadataKeys: keys)
}

final class AppleHealthWorkoutsTests: XCTestCase {
    private let window = (from: base.addingTimeInterval(-86_400), to: base.addingTimeInterval(86_400))

    func testWorkoutsFromOtherAppsKeepTheirSourceAndValues() async {
        let store = FakeAppleHealthWorkoutStore()
        await store.set(workouts: [raw(1, average: 121, maximum: 131), raw(2, activity: .run, start: 3_600, provenance: watch)])
        let reader = AppleHealthWorkoutReader(store: store, excludingBundlePrefixes: ["com.loopr.ios"])
        guard case .workouts(let workouts) = await reader.read(from: window.from, to: window.to) else {
            return XCTFail("Expected workouts")
        }
        XCTAssertEqual(workouts.map(\.activity), [.run, .cycle], "newest first")
        XCTAssertEqual(workouts.map(\.sourceLabel), ["Apple Watch", "Garmin Connect"])
        XCTAssertEqual(workouts.last?.distanceMeters, 24_000)
        XCTAssertEqual(workouts.last?.energyKcal, 500)
        XCTAssertEqual(workouts.last?.averageHeartRate, 121)
        XCTAssertEqual(workouts.last?.maximumHeartRate, 131)
        let excluded = await store.excludedSeen
        XCTAssertEqual(excluded, [["com.loopr.ios"]])
    }

    func testLooprsOwnWorkoutsAreNeverReadBack() async {
        let store = FakeAppleHealthWorkoutStore()
        let own = AppleHealthProvenance(sourceName: "Loopr", sourceBundleIdentifier: "com.loopr.ios")
        let watchApp = AppleHealthProvenance(sourceName: "Loopr", sourceBundleIdentifier: "com.loopr.ios.watchkitapp")
        await store.set(workouts: [
            raw(1, provenance: own),
            raw(2, provenance: watchApp),
            // A copy that kept Loopr's export metadata, whatever app holds it now.
            raw(3, sync: "com.loopr.workout.ABC"),
            raw(4, keys: ["com.loopr.provenance", "HKTimeZone"]),
            raw(5)
        ])
        let reader = AppleHealthWorkoutReader(store: store, excludingBundlePrefixes: ["com.loopr.ios"])
        guard case .workouts(let workouts) = await reader.read(from: window.from, to: window.to) else {
            return XCTFail("Expected workouts")
        }
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.sourceLabel, "Garmin Connect")
    }

    func testImpossibleValuesBecomeNilAndBrokenWorkoutsAreDropped() async {
        let store = FakeAppleHealthWorkoutStore()
        await store.set(workouts: [
            raw(1, distance: 0, energy: -.infinity, average: 400, maximum: 12),
            raw(2, minutes: 0),
            raw(3, start: -3 * 86_400),
            raw(1)
        ])
        let reader = AppleHealthWorkoutReader(store: store)
        guard case .workouts(let workouts) = await reader.read(from: window.from, to: window.to) else {
            return XCTFail("Expected workouts")
        }
        XCTAssertEqual(workouts.count, 1, "a zero-length workout, one outside the window and a duplicate id are dropped")
        XCTAssertNil(workouts.first?.distanceMeters)
        XCTAssertNil(workouts.first?.energyKcal)
        XCTAssertNil(workouts.first?.averageHeartRate)
        XCTAssertNil(workouts.first?.maximumHeartRate)
    }

    func testADeclinedOrUnaskedReadFailsClosed() async {
        let store = FakeAppleHealthWorkoutStore()
        let reader = AppleHealthWorkoutReader(store: store)
        await store.set(workouts: nil)
        var result = await reader.read(from: window.from, to: window.to)
        XCTAssertEqual(result, .absent(.noSamples))
        await store.set(access: .notRequested)
        result = await reader.read(from: window.from, to: window.to)
        XCTAssertEqual(result, .absent(.notAuthorized))
        await store.set(access: .unavailable)
        result = await reader.read(from: window.from, to: window.to)
        XCTAssertEqual(result, .absent(.unavailable))
        await store.set(access: .requested)
        await store.set(failure: .authorizationDenied)
        result = await reader.read(from: window.from, to: window.to)
        XCTAssertEqual(result, .absent(.notAuthorized))
        await store.set(failure: .failed("Protected data unavailable"))
        result = await reader.read(from: window.from, to: window.to)
        XCTAssertEqual(result, .absent(.queryFailed("Protected data unavailable")))
        let unavailable = await AppleHealthWorkoutReader(store: UnavailableAppleHealthWorkoutStore()).read(from: window.from, to: window.to)
        XCTAssertEqual(unavailable, .absent(.unavailable))
    }

    func testAppsWithWorkoutsButNoneInTheWindowGiveAnEmptyList() async {
        let store = FakeAppleHealthWorkoutStore()
        await store.set(workouts: [])
        let result = await AppleHealthWorkoutReader(store: store).read(from: window.from, to: window.to)
        XCTAssertEqual(result, .workouts([]))
    }

    func testHeartRatePrefersTheWorkoutsOwnSourceAndFillsTheAverage() async throws {
        let store = FakeAppleHealthWorkoutStore()
        await store.set(workouts: [raw(1)])
        let reader = AppleHealthWorkoutReader(store: store)
        guard case .workouts(let workouts) = await reader.read(from: window.from, to: window.to),
              let ride = workouts.first else { return XCTFail("Expected a ride") }
        await store.set(heartRate: [
            AppleHealthRawHeartRate(time: base.addingTimeInterval(60), bpm: 120, sourceBundleIdentifier: "com.garmin.connect.mobile"),
            AppleHealthRawHeartRate(time: base.addingTimeInterval(120), bpm: 130, sourceBundleIdentifier: "com.garmin.connect.mobile"),
            // The same minute from the watch on the other wrist: ignored, the Garmin recorded the ride.
            AppleHealthRawHeartRate(time: base.addingTimeInterval(90), bpm: 150, sourceBundleIdentifier: "com.apple.health.1234"),
            // Before the ride, and a reading no heart can give.
            AppleHealthRawHeartRate(time: base.addingTimeInterval(-60), bpm: 70, sourceBundleIdentifier: "com.garmin.connect.mobile"),
            AppleHealthRawHeartRate(time: base.addingTimeInterval(180), bpm: 400, sourceBundleIdentifier: "com.garmin.connect.mobile")
        ])
        let filled = await reader.withHeartRate(ride)
        XCTAssertEqual(filled.heartRate.map(\.bpm), [120, 130])
        XCTAssertEqual(filled.averageHeartRate, 125)
        XCTAssertEqual(filled.maximumHeartRate, 130)
    }

    func testHeartRateFromAnotherSourceCountsWhenTheWorkoutsSourceHasNone() async {
        let strava = AppleHealthProvenance(sourceName: "Strava", sourceBundleIdentifier: "com.strava.stravaride")
        let workout = AppleHealthWorkout(id: UUID(), activity: .run, activityName: "Running", start: base,
                                         end: base.addingTimeInterval(600), averageHeartRate: 150, provenance: strava)
        let filled = AppleHealthWorkoutReader.filling(workout, with: [
            AppleHealthRawHeartRate(time: base.addingTimeInterval(60), bpm: 148, sourceBundleIdentifier: "com.apple.health.1234")
        ])
        XCTAssertEqual(filled.heartRate.count, 1)
        XCTAssertEqual(filled.averageHeartRate, 150, "Apple Health's own average stays")
    }

    func testHeartRateSwitchedOffReadsNoHeartRate() async {
        let store = FakeAppleHealthWorkoutStore()
        await store.set(heartRate: [AppleHealthRawHeartRate(time: base.addingTimeInterval(60), bpm: 120, sourceBundleIdentifier: nil)])
        let workout = AppleHealthWorkout(id: UUID(), activity: .cycle, activityName: "Cycling", start: base,
                                         end: base.addingTimeInterval(600), provenance: garmin)
        let filled = await AppleHealthWorkoutReader(store: store, readsHeartRate: false).withHeartRate(workout)
        XCTAssertTrue(filled.heartRate.isEmpty)
        XCTAssertNil(filled.averageHeartRate)
        let queries = await store.heartRateQueries
        XCTAssertEqual(queries, 0)
    }

    func testAFailedHeartRateReadLeavesTheWorkoutAsItWas() async {
        let store = FakeAppleHealthWorkoutStore()
        await store.set(failure: .failed("locked"))
        let workout = AppleHealthWorkout(id: UUID(), activity: .cycle, activityName: "Cycling", start: base,
                                         end: base.addingTimeInterval(600), provenance: garmin)
        let filled = await AppleHealthWorkoutReader(store: store).withHeartRate(workout)
        XCTAssertEqual(filled, workout)
    }

    func testActivityNamesMatchWorkoutKitsCatalogue() {
        // WorkoutKit's ActivityType raw values. HealthKitBridge cannot import WorkoutKit, so the names are pinned here.
        XCTAssertEqual(AppleHealthWorkoutActivity.allCases.map(\.rawValue),
                       ["run", "cycle", "walk", "hike", "strength", "swim", "cardio", "yoga", "hiit", "pilates", "mobility",
                        "crossfit", "rowing", "climbing", "sport", "dance", "other"])
    }

    #if canImport(HealthKit)
    func testHealthKitActivitiesMapOntoLooprsActivities() {
        let cases: [(HKWorkoutActivityType, AppleHealthWorkoutActivity)] = [
            (.running, .run), (.cycling, .cycle), (.walking, .walk), (.hiking, .hike),
            (.traditionalStrengthTraining, .strength), (.functionalStrengthTraining, .strength),
            (.crossTraining, .crossfit), (.pilates, .pilates), (.barre, .pilates),
            (.flexibility, .mobility), (.cooldown, .mobility), (.yoga, .yoga), (.taiChi, .yoga),
            (.rowing, .rowing), (.climbing, .climbing), (.cardioDance, .dance), (.socialDance, .dance),
            (.soccer, .sport), (.tennis, .sport), (.basketball, .sport), (.highIntensityIntervalTraining, .hiit),
            (.swimming, .swim), (.elliptical, .cardio), (.archery, .other), (.other, .other)
        ]
        for (type, expected) in cases {
            XCTAssertEqual(LiveAppleHealthWorkoutStore.activity(for: type), expected, "\(type.rawValue)")
        }
        XCTAssertEqual(LiveAppleHealthWorkoutStore.name(for: .functionalStrengthTraining), "Functional strength training")
        XCTAssertEqual(LiveAppleHealthWorkoutStore.name(for: .archery), "Other")
    }

    func testTheHeartRateReadBringsWorkoutsAndTheirValues() {
        let types = LiveHealthHistoryClient.readTypes(for: [.heartRate], readSleep: false).map(\.identifier)
        XCTAssertTrue(types.contains(HKObjectType.workoutType().identifier))
        XCTAssertTrue(types.contains(HKQuantityTypeIdentifier.heartRate.rawValue))
        XCTAssertTrue(types.contains(HKQuantityTypeIdentifier.distanceCycling.rawValue))
        XCTAssertTrue(types.contains(HKQuantityTypeIdentifier.activeEnergyBurned.rawValue))
        // Switching heart rate off leaves workouts out of the request.
        let withoutHeartRate = LiveHealthHistoryClient.readTypes(for: [.steps], readSleep: false).map(\.identifier)
        XCTAssertFalse(withoutHeartRate.contains(HKObjectType.workoutType().identifier))
    }
    #endif
}
