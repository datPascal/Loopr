import DomainKit
import Foundation
import RoutineKit
import SettingsKit
import Testing

@testable import Loopr

// MARK: - Doubles

private actor FakeBedtimeStarter: BedtimeActivityStarting {
    nonisolated let canSchedule: Bool
    private(set) var events: [String] = []
    private(set) var handles: [BedtimeActivityHandle] = []
    private(set) var requests: [BedtimeActivityRequest] = []
    var authorized = true
    private var counter = 0

    init(canSchedule: Bool = true) { self.canSchedule = canSchedule }

    func setAuthorized(_ value: Bool) { authorized = value }
    func isAuthorized() async -> Bool { authorized }
    func current() async -> [BedtimeActivityHandle] { handles }

    func start(_ request: BedtimeActivityRequest) async throws -> String {
        counter += 1
        let id = "activity-\(counter)"
        events.append(request.scheduledStart == nil ? "start" : "schedule")
        requests.append(request)
        handles.append(BedtimeActivityHandle(
            id: id, windowStart: request.attributes.windowStart, bedtime: request.attributes.bedtime,
            isScheduled: request.scheduledStart != nil, state: request.state))
        return id
    }

    func update(id: String, state: LooprBedtimeActivityAttributes.ContentState, staleDate _: Date) async {
        events.append("update")
        handles = handles.map {
            $0.id == id ? BedtimeActivityHandle(id: id, windowStart: $0.windowStart, bedtime: $0.bedtime,
                                                isScheduled: $0.isScheduled, state: state) : $0
        }
    }

    func end(id: String) async {
        events.append("end")
        handles.removeAll { $0.id == id }
    }
}

private actor FakeBedtimeInputs: BedtimeActivityInputProviding {
    var rules: [ProtocolRule]
    var plannedMinute: Int?
    var kept: Set<RuleKey> = []
    var asleep: Date?

    init(rules: [ProtocolRule], plannedMinute: Int? = nil) {
        self.rules = rules
        self.plannedMinute = plannedMinute
    }

    func keep(_ key: RuleKey) { kept.insert(key) }
    func fallAsleep(at date: Date) { asleep = date }

    func tonight(now _: Date, timeZone _: TimeZone) -> BedtimeTonight {
        BedtimeTonight(rules: rules, plannedBedtimeMinute: plannedMinute)
    }

    func checks(day: DayIdentity, now: Date, timeZone _: TimeZone) -> [RuleCheck] {
        rules.filter(\.isEvening).compactMap { rule in
            try? RuleCheck(ruleKey: rule.key, day: day, version: 1, state: kept.contains(rule.key) ? .kept : .pending,
                           source: .manual, recordedAt: now)
        }
    }

    func sleepStart(since _: Date, now _: Date) -> Date? { asleep }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

private struct FakeSurfacePrivacy: LooprSurfacePrivacyReading, BedtimePreferenceStoring {
    let box: Box
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SurfacePrivacySettings
        init(_ value: SurfacePrivacySettings) { self.value = value }
        var settings: SurfacePrivacySettings { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    func currentSurfacePrivacy() async -> SurfacePrivacySettings { box.settings }
    func setBedtimeActivityEnabled(_ enabled: Bool) async throws { box.settings.bedtimeLiveActivity = enabled }
}

// MARK: - Fixtures

private let calendar = BedtimeActivityWindowTests.calendar()

private func at(_ hour: Int, _ minute: Int = 0, day: Int = 24) -> Date {
    BedtimeActivityWindowTests.date(2026, 10, day, hour, minute, in: calendar)
}

private let eveningRules: [ProtocolRule] = [
    ProtocolRule(key: "in-bed", title: "In bed by 22:30", group: .sleep,
                 target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350), source: .band),
    ProtocolRule(key: "kitchen", title: "Kitchen closed", group: .food, timeOfDayMinutes: 1_100, isEvening: true),
    ProtocolRule(key: "wind", title: "Wind-down", group: .sleep, timeOfDayMinutes: 1_305, isEvening: true),
    ProtocolRule(key: "screens", title: "Screens off", group: .sleep, isEvening: true)
]

private func makeRuntime(
    starter: FakeBedtimeStarter, clock: MutableClock
) -> BedtimeActivityRuntime {
    BedtimeActivityRuntime(starter: starter, now: { clock.now }, calendar: { calendar },
                           scheduleWakeups: false, observeSystemEvents: false)
}

// MARK: - The decision

struct BedtimeActivityDecisionTests {
    private let evening = BedtimeActivityWindow.evening(startingOn: at(9), bedtimeMinute: 1_350, calendar: calendar)!

    private func existing(_ id: String, start: Date? = nil, bedtime: Date? = nil, scheduled: Bool = false) -> BedtimeActivityDecision.Existing {
        .init(id: id, windowStart: start ?? evening.start, bedtime: bedtime ?? evening.bedtime, isScheduled: scheduled)
    }

    private func decide(
        enabled: Bool = true, authorized: Bool = true, asleep: Bool = false,
        phase: BedtimeActivityWindow.Phase, existing: [BedtimeActivityDecision.Existing] = [], canSchedule: Bool = true
    ) -> BedtimeActivityDecision.Plan {
        BedtimeActivityDecision.decide(enabled: enabled, authorized: authorized, asleep: asleep, phase: phase,
                                       existing: existing, canSchedule: canSchedule)
    }

    @Test
    func startsOnlyInsideTheWindow() {
        #expect(decide(phase: .running(evening)).start == .now)
        #expect(decide(phase: .grace(evening)).start == nil)
        #expect(decide(phase: .over).start == nil)
        #expect(decide(phase: .noBedtime).start == nil)
    }

    @Test
    func beforeEighteenSchedulesTheStartWhenTheSystemCan() {
        #expect(decide(phase: .before(evening)).start == .scheduled(evening.start))
        #expect(decide(phase: .before(evening), canSchedule: false).start == nil)
    }

    @Test
    func offOrUnauthorizedNeverStartsAndOffEndsEverything() {
        #expect(decide(enabled: false, phase: .running(evening), existing: [existing("a")]) ==
                .init(ends: ["a"], updateID: nil, start: nil))
        #expect(decide(authorized: false, phase: .running(evening)).start == nil)
    }

    @Test
    func keepsOneMatchingActivityAndEndsTheRest() {
        let plan = decide(phase: .running(evening), existing: [
            existing("b"), existing("a"),
            existing("old", start: evening.start.addingTimeInterval(-86_400), bedtime: evening.bedtime.addingTimeInterval(-86_400))
        ])
        #expect(plan.updateID == "a")
        #expect(plan.ends == ["b", "old"])
        #expect(plan.start == nil)
    }

    @Test
    func aChangedBedtimeEndsTheOldActivityAndStartsAgain() {
        let plan = decide(phase: .running(evening), existing: [existing("a", bedtime: evening.bedtime.addingTimeInterval(1_800))])
        #expect(plan.ends == ["a"])
        #expect(plan.start == .now)
    }

    @Test
    func theGraceKeepsARunningActivityButStartsNothing() {
        let plan = decide(phase: .grace(evening), existing: [existing("a")])
        #expect(plan == .init(ends: [], updateID: "a", start: nil))
    }

    @Test
    func overEndsEverythingAndAsleepEndsEverything() {
        #expect(decide(phase: .over, existing: [existing("a")]).ends == ["a"])
        let asleep = decide(asleep: true, phase: .running(evening), existing: [existing("a")])
        #expect(asleep == .init(ends: ["a"], updateID: nil, start: nil))
    }

    @Test
    func aScheduledActivityIsKeptAndNotUpdated() {
        let plan = decide(phase: .before(evening), existing: [existing("a", scheduled: true)])
        #expect(plan == .init(ends: [], updateID: nil, start: nil))
    }
}

// MARK: - The runtime

struct BedtimeActivityRuntimeTests {
    @Test
    func theSwitchIsOffByDefaultSoNothingStartsInsideTheWindow() async {
        let starter = FakeBedtimeStarter()
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(19, 49)))
        await runtime.setProvider(FakeBedtimeInputs(rules: eveningRules))
        #expect(await runtime.isEnabled() == false)
        #expect(await starter.events.isEmpty)
    }

    @Test
    func turningItOnStartsTheActivityWithTheStepsAndTheBedtime() async throws {
        let starter = FakeBedtimeStarter()
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(19, 49)))
        let inputs = FakeBedtimeInputs(rules: eveningRules)
        await inputs.keep("kitchen")
        await runtime.setProvider(inputs)
        await runtime.setPreference(true)

        #expect(await starter.events == ["start"])
        let request = try #require(await starter.requests.first)
        #expect(request.attributes.bedtime == at(22, 30))
        #expect(request.attributes.windowStart == at(18))
        #expect(request.attributes.bedtimeMinuteOfDay == 1_350)
        #expect(request.scheduledStart == nil)
        #expect(request.staleDate == at(22, 45))
        #expect(request.state.steps.map(\.title) == ["Kitchen closed", "Wind-down", "Screens off"])
        #expect(request.state.steps.map(\.isDone) == [true, false, false])
        #expect(request.state.nextStep?.title == "Wind-down")
        #expect(abs(request.state.progress - (109.0 / 270.0)) < 1e-9)
    }

    @Test
    func startsNothingBeforeEighteenButSchedulesTheStartWhenTheSystemCan() async throws {
        let schedulingStarter = FakeBedtimeStarter(canSchedule: true)
        let early = makeRuntime(starter: schedulingStarter, clock: MutableClock(at(14)))
        await early.setProvider(FakeBedtimeInputs(rules: eveningRules))
        await early.setPreference(true)
        #expect(await schedulingStarter.events == ["schedule"])
        #expect(try #require(await schedulingStarter.requests.first).scheduledStart == at(18))
        // A second pass finds the scheduled activity and adds no other.
        await early.reconcile()
        #expect(await schedulingStarter.events == ["schedule"])

        let plainStarter = FakeBedtimeStarter(canSchedule: false)
        let plain = makeRuntime(starter: plainStarter, clock: MutableClock(at(14)))
        await plain.setProvider(FakeBedtimeInputs(rules: eveningRules))
        await plain.setPreference(true)
        #expect(await plainStarter.events.isEmpty)
    }

    @Test
    func startsOnTheFirstPassAfterEighteenWhenNothingStartedEarlier() async {
        let starter = FakeBedtimeStarter(canSchedule: false)
        let clock = MutableClock(at(14))
        let runtime = makeRuntime(starter: starter, clock: clock)
        await runtime.setProvider(FakeBedtimeInputs(rules: eveningRules))
        await runtime.setPreference(true)
        #expect(await starter.events.isEmpty)
        clock.set(at(18, 5))
        await runtime.reconcile()
        #expect(await starter.events == ["start"])
    }

    @Test
    func startsNothingAfterBedtimeAndNeverForAPastDay() async {
        let starter = FakeBedtimeStarter()
        let clock = MutableClock(at(22, 50))
        let runtime = makeRuntime(starter: starter, clock: clock)
        await runtime.setProvider(FakeBedtimeInputs(rules: eveningRules))
        await runtime.setPreference(true)
        #expect(await starter.events.isEmpty)
        clock.set(at(0, 30, day: 25))
        await runtime.reconcile()
        #expect(await starter.events == ["schedule"], "00:30 is the next day, so only tonight's evening is scheduled")
    }

    @Test
    func aBedtimeAfterMidnightStartsAtTwentyThreeAndCountsPastTwelve() async throws {
        let starter = FakeBedtimeStarter()
        let clock = MutableClock(at(23, 10))
        let runtime = makeRuntime(starter: starter, clock: clock)
        await runtime.setProvider(FakeBedtimeInputs(rules: rules(inBedMinute: 90)))
        await runtime.setPreference(true)
        #expect(await starter.events == ["start"])
        #expect(try #require(await starter.requests.first).attributes.bedtime == at(1, 30, day: 25))
        clock.set(at(0, 20, day: 25))
        await runtime.reconcile()
        #expect(await starter.requests.count == 1, "still the same evening, so no second activity")
        #expect(await starter.handles.count == 1)
    }

    @Test
    func tickingARuleUpdatesTheStepsOnceAndAnIdlePassUpdatesNothing() async throws {
        let starter = FakeBedtimeStarter()
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(20)))
        let inputs = FakeBedtimeInputs(rules: eveningRules)
        await runtime.setProvider(inputs)
        await runtime.setPreference(true)
        await runtime.reconcile()
        #expect(await starter.events == ["start"], "nothing changed, so no update")

        await inputs.keep("wind")
        await runtime.reconcile()
        #expect(await starter.events == ["start", "update"])
        let state = try #require(await starter.handles.first).state
        #expect(state.steps.map(\.isDone) == [false, true, false])
        #expect(state.nextStep?.title == "Kitchen closed")
    }

    @Test
    func turningTheSwitchOffEndsARunningActivity() async {
        let starter = FakeBedtimeStarter()
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(20)))
        await runtime.setProvider(FakeBedtimeInputs(rules: eveningRules))
        await runtime.setPreference(true)
        #expect(await starter.handles.count == 1)
        await runtime.setPreference(false)
        #expect(await starter.handles.isEmpty)
        #expect(await starter.events == ["start", "end"])
        await runtime.reconcile()
        #expect(await starter.events == ["start", "end"], "off stays off")
    }

    @Test
    func endsAtBedtimePlusTheGraceAndDoesNotComeBack() async {
        let starter = FakeBedtimeStarter()
        let clock = MutableClock(at(20))
        let runtime = makeRuntime(starter: starter, clock: clock)
        await runtime.setProvider(FakeBedtimeInputs(rules: eveningRules))
        await runtime.setPreference(true)
        clock.set(at(22, 40))
        await runtime.reconcile()
        #expect(await starter.handles.count == 1, "the grace keeps it up")
        clock.set(at(22, 46))
        await runtime.reconcile()
        #expect(await starter.handles.isEmpty)
        clock.set(at(23))
        await runtime.reconcile()
        #expect(await starter.events == ["start", "end"], "ended once and never restarted")
    }

    @Test
    func endsWhenThePersonGoesToBedAndStaysEnded() async {
        let starter = FakeBedtimeStarter()
        let clock = MutableClock(at(21))
        let runtime = makeRuntime(starter: starter, clock: clock)
        let inputs = FakeBedtimeInputs(rules: eveningRules)
        await runtime.setProvider(inputs)
        await runtime.setPreference(true)
        #expect(await starter.handles.count == 1)
        await inputs.fallAsleep(at: at(21, 20))
        clock.set(at(21, 25))
        await runtime.reconcile()
        #expect(await starter.handles.isEmpty)
        await runtime.reconcile()
        #expect(await starter.events == ["start", "end"])
    }

    @Test
    func respectsTheSystemSwitchForLiveActivities() async {
        let starter = FakeBedtimeStarter()
        await starter.setAuthorized(false)
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(20)))
        await runtime.setProvider(FakeBedtimeInputs(rules: eveningRules))
        await runtime.setPreference(true)
        #expect(await starter.events.isEmpty)
    }

    @Test
    func theInBedRuleWinsOverTheSleepPlanInTheRunningActivity() async throws {
        let starter = FakeBedtimeStarter()
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(20)))
        await runtime.setProvider(FakeBedtimeInputs(rules: eveningRules, plannedMinute: 23 * 60 + 10))
        await runtime.setPreference(true)
        #expect(try #require(await starter.requests.first).attributes.bedtime == at(22, 30))
    }

    @Test
    func withNoInBedRuleTheSleepPlanSetsTheBedtime() async throws {
        let starter = FakeBedtimeStarter()
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(20)))
        await runtime.setProvider(FakeBedtimeInputs(rules: Array(eveningRules.dropFirst()), plannedMinute: 23 * 60 + 10))
        await runtime.setPreference(true)
        #expect(try #require(await starter.requests.first).attributes.bedtime == at(23, 10))
    }

    @Test
    func withNeitherABedtimeThereIsNoActivity() async {
        let starter = FakeBedtimeStarter()
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(20)))
        await runtime.setProvider(FakeBedtimeInputs(rules: Array(eveningRules.dropFirst())))
        await runtime.setPreference(true)
        #expect(await starter.events.isEmpty)
    }

    @Test
    func settingsStoreTheSwitchAndTheGeneralLiveActivityOffWins() async {
        let box = FakeSurfacePrivacy.Box(SurfacePrivacySettings())
        let reader = FakeSurfacePrivacy(box: box)
        let starter = FakeBedtimeStarter()
        let runtime = makeRuntime(starter: starter, clock: MutableClock(at(20)))
        await runtime.setProvider(FakeBedtimeInputs(rules: eveningRules))
        await runtime.attachSettings(reader)
        #expect(await runtime.isEnabled() == false)
        #expect(await starter.events.isEmpty)

        await runtime.setPreference(true)
        #expect(box.settings.bedtimeLiveActivity)
        #expect(await starter.events == ["start"])

        // The workout switch also gates this activity. Off there ends it here.
        box.settings.liveActivity = false
        await runtime.reconcile()
        #expect(await starter.handles.isEmpty)
    }
}

// MARK: - Settings storage

struct BedtimeActivitySettingsTests {
    @Test
    func theSwitchIsOffByDefault() {
        #expect(SurfacePrivacySettings().bedtimeLiveActivity == false)
        #expect(SettingsSnapshot().surfacePrivacy.bedtimeLiveActivity == false)
    }

    @Test
    func settingsSavedBeforeTheSwitchExistedKeepTheirValuesAndDecodeOff() throws {
        let old = Data(#"{"todayWidget":false,"batteryWidget":true,"watchSnapshot":false,"liveActivity":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SurfacePrivacySettings.self, from: old)
        #expect(decoded == SurfacePrivacySettings(todayWidget: false, batteryWidget: true, watchSnapshot: false,
                                                  liveActivity: true, bedtimeLiveActivity: false))
    }

    @Test
    func theSwitchSurvivesAnEncodeAndDecode() throws {
        let on = SurfacePrivacySettings(bedtimeLiveActivity: true)
        let decoded = try JSONDecoder().decode(SurfacePrivacySettings.self, from: JSONEncoder().encode(on))
        #expect(decoded.bedtimeLiveActivity)
    }

    @Test
    func aSavedSnapshotWithTheOldShapeStillDecodesWholeSoNoOtherSettingResets() throws {
        var snapshot = SettingsSnapshot()
        snapshot.units = .imperial
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var privacy = try #require(json["surfacePrivacy"] as? [String: Any])
        privacy.removeValue(forKey: "bedtimeLiveActivity")
        json["surfacePrivacy"] = privacy
        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.units == .imperial)
        #expect(decoded.surfacePrivacy.bedtimeLiveActivity == false)
    }
}

// MARK: - Helpers

/// The fixture rules with the in-bed rule moved to `minute`, for bedtimes the fixture does not carry.
private func rules(inBedMinute minute: Int) -> [ProtocolRule] {
    eveningRules.map { rule in
        guard rule.key == "in-bed" else { return rule }
        return ProtocolRule(key: rule.key, title: rule.title, group: rule.group,
                            target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: Double(minute)),
                            source: .band)
    }
}
