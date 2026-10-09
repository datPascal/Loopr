import Foundation
import Testing
import AnalyticsKit
import NotificationKit
import StorageKit
import SettingsKit
@testable import Loopr

/// Stands in for UNUserNotificationCenter behind the real policy.
private actor FakeNotificationCenter: NotificationSchedulingClient {
    var requests: [NotificationRequest] = []
    func schedule(_ request: NotificationRequest) async throws { requests.append(request) }
    func remove(identities: Set<NotificationIdentity>) async { requests.removeAll { identities.contains($0.identity) } }
    func all() -> [NotificationRequest] { requests }
}

/// The production publisher's mapping, over a policy the test owns.
nonisolated private struct PolicyPublisher: HeartAlertsPublishing {
    let policy: NotificationPolicy

    func publish(_ request: NotificationRequest) async -> HeartAlertDelivery {
        switch try? await policy.schedule(request) {
        case .scheduled?, .duplicate?: .sent
        case .deferred?: .heldForQuietHours
        case .queued?: .waitingForPermission
        case .disabled?, .denied?: .notificationsOff
        default: .notSent
        }
    }

    func setFamilies(_ families: [NotificationFamily: Bool]) async throws {
        for (family, enabled) in families { try await policy.setEnabled(enabled, for: family) }
    }

    func deliverySettings() async -> NotificationDeliverySettings { await policy.deliverySettings() }
}

nonisolated private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private func utc8() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    return calendar
}

/// Writes band seconds into a fresh history database, the way a committed
/// batch leaves them.
private func insert(_ database: StorageDatabase, from start: Int64, minutes: Int, bpm: Int, walking: Bool = false) throws {
    try database.write { db in
        var beatClock = 0.0
        for offset in 0..<Int64(minutes * 60) {
            let t = start + offset
            let swing = walking ? (t % 2 == 0 ? 0.15 : -0.15) : Double(t % 5) * 0.0002
            try db.execute(sql: """
                INSERT INTO decoded_second (physiological_timestamp, band_counter, absolute_timestamp, local_day,
                    heart_rate, gravity_x, gravity_y, gravity_z)
                VALUES (?, ?, ?, '2026-09-23', ?, ?, 0.2, -0.98)
                """, arguments: [t, t, t, bpm, 0.002 + swing])
            let id = db.lastInsertedRowID
            let interval = 60_000.0 / Double(bpm)
            beatClock += 1000
            var index = 0
            while beatClock >= interval {
                beatClock -= interval
                let jitter = [0, 3, -2, 5, -4, 1, -3][(index + Int(t % 7)) % 7]
                try db.execute(sql: "INSERT INTO rr_beat (decoded_second_id, beat_index, rr_milliseconds) VALUES (?, ?, ?)",
                               arguments: [id, index, Int(interval.rounded()) + jitter])
                index += 1
            }
        }
    }
}

nonisolated private struct Harness {
    let root: URL
    let history: StorageDatabase
    let center = FakeNotificationCenter()
    let policy: NotificationPolicy
    let clock: MutableClock
    let runtime: LooprHeartAlertsRuntime

    init(now: Date, quietHours: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("heart-alerts-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let clock = MutableClock(now)
        self.clock = clock
        policy = NotificationPolicy(client: center, claims: NotificationClaimLedger(), calendar: utc8(),
                                    now: { clock.now })
        let calendar = utc8()
        runtime = LooprHeartAlertsRuntime(
            store: HeartAlertsStore(root: root.appendingPathComponent("HeartAlerts")),
            calendar: { calendar },
            clock: { clock.now },
            publisher: PolicyPublisher(policy: policy)
        )
        _ = quietHours
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// 2026-09-24 14:00 at UTC+8.
private let afternoon: Int64 = 1_790_229_600
/// 2026-09-24 02:00 at UTC+8.
private let night: Int64 = 1_790_186_400

@Suite(.serialized)
struct HeartAlertsRuntimeTests {
    @Test func headlessSourceNeverOpensProductionStoresForATestDatabase() throws {
        let harness = try Harness(now: Date(timeIntervalSince1970: TimeInterval(afternoon)))
        defer { harness.cleanUp() }
        #expect(ProjectionOvernightSource.production(history: harness.history) == nil)
    }

    @Test func everyAlertStartsOffAndOnlyMovesTheWatermark() async throws {
        let harness = try Harness(now: Date(timeIntervalSince1970: TimeInterval(afternoon + 15 * 60)))
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        try insert(harness.history, from: afternoon, minutes: 15, bpm: 135)
        await harness.runtime.attach(history: harness.history)

        let preferences = await harness.runtime.preferences()
        #expect(preferences == .off)
        await harness.runtime.evaluateNow()

        #expect(await harness.center.all().isEmpty)
        #expect(await harness.runtime.history().isEmpty)
        let state = await harness.runtime.store.state()
        #expect(state.rates.watermark == afternoon + 15 * 60 - 1)
    }

    @Test func stillHighHeartRateSchedulesOneAlertThroughThePolicy() async throws {
        let harness = try Harness(now: Date(timeIntervalSince1970: TimeInterval(afternoon)))
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        await harness.runtime.attach(history: harness.history)
        try await harness.runtime.update(HeartAlertsPreferences(rates: HeartRateAlertSettings(highEnabled: true)))
        #expect(await harness.policy.isEnabled(.highHeartRate))

        // The band offloads fifteen minutes of sitting at 135 bpm.
        try insert(harness.history, from: afternoon, minutes: 15, bpm: 135)
        harness.clock.now = Date(timeIntervalSince1970: TimeInterval(afternoon + 16 * 60))
        await harness.runtime.evaluateNow()

        let scheduled = await harness.center.all()
        #expect(scheduled.count == 1)
        let request = try #require(scheduled.first)
        #expect(request.identity.family == .highHeartRate)
        #expect(request.title == "High heart rate")
        #expect(request.detail.hasPrefix("Your heart rate stayed above 120 bpm for 10 minutes while you seemed to be at rest."))
        #expect(request.lockScreenBody == request.detail)
        #expect(request.categoryIdentifier == NotificationCategoryCatalog.heartAlert)
        if case .heartAlert(let id) = request.deepLink { #expect(id == request.identity.objectID) } else {
            Issue.record("heart alerts must deep link to their episode")
        }

        let records = await harness.runtime.history()
        #expect(records.count == 1)
        #expect(records.first?.delivery == .sent)
        #expect((records.first?.episode?.minutes.count ?? 0) >= 10)

        // The next offload continues the same stretch: no second alert.
        try insert(harness.history, from: afternoon + 15 * 60, minutes: 10, bpm: 134)
        harness.clock.now = Date(timeIntervalSince1970: TimeInterval(afternoon + 26 * 60))
        await harness.runtime.evaluateNow()
        #expect(await harness.center.all().count == 1)
        let extended = try #require(await harness.runtime.history().first?.episode)
        #expect(extended.end == afternoon + 25 * 60)
    }

    @Test func alertsInQuietHoursWaitForMorningUnlessAllowed() async throws {
        let harness = try Harness(now: Date(timeIntervalSince1970: TimeInterval(night)))
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        try await harness.policy.setDeliverySettings(.standard)
        await harness.policy.setQuietHours(.standard)
        await harness.runtime.attach(history: harness.history)
        try await harness.runtime.update(HeartAlertsPreferences(rates: HeartRateAlertSettings(highEnabled: true)))

        try insert(harness.history, from: night, minutes: 12, bpm: 128)
        harness.clock.now = Date(timeIntervalSince1970: TimeInterval(night + 13 * 60))
        await harness.runtime.evaluateNow()

        let held = try #require(await harness.center.all().first)
        // 07:00 at UTC+8 the same morning.
        #expect(held.fireDate == Date(timeIntervalSince1970: TimeInterval(night + 5 * 3600)))
        #expect(await harness.runtime.history().first?.delivery == .heldForQuietHours)
    }

    @Test func walkingNeverAlertsAndPausedKindsAreRecordedButSilent() async throws {
        let harness = try Harness(now: Date(timeIntervalSince1970: TimeInterval(afternoon)))
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        await harness.runtime.attach(history: harness.history)
        try await harness.runtime.update(HeartAlertsPreferences(rates: HeartRateAlertSettings(highEnabled: true)))

        try insert(harness.history, from: afternoon, minutes: 20, bpm: 130, walking: true)
        harness.clock.now = Date(timeIntervalSince1970: TimeInterval(afternoon + 21 * 60))
        await harness.runtime.evaluateNow()
        #expect(await harness.center.all().isEmpty)

        await harness.runtime.pauseForToday(.highHeartRate)
        // Sitting down, forty minutes later, still at 128.
        try insert(harness.history, from: afternoon + 40 * 60, minutes: 12, bpm: 128)
        harness.clock.now = Date(timeIntervalSince1970: TimeInterval(afternoon + 53 * 60))
        await harness.runtime.evaluateNow()
        #expect(await harness.center.all().isEmpty)
        #expect(await harness.runtime.history().first?.delivery == .paused)
    }

    @Test func aRecordedWorkoutSuppressesAlertsDuringAndJustAfterIt() async throws {
        let harness = try Harness(now: Date(timeIntervalSince1970: TimeInterval(afternoon)))
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        await harness.runtime.attach(history: harness.history)
        try await harness.runtime.update(HeartAlertsPreferences(rates: HeartRateAlertSettings(highEnabled: true)))
        // A stationary bike: high heart rate, still wrist.
        await harness.runtime.noteWorkout(id: "ride", start: Date(timeIntervalSince1970: TimeInterval(afternoon)),
                                          end: Date(timeIntervalSince1970: TimeInterval(afternoon + 20 * 60)))
        try insert(harness.history, from: afternoon, minutes: 25, bpm: 150)
        harness.clock.now = Date(timeIntervalSince1970: TimeInterval(afternoon + 26 * 60))
        await harness.runtime.evaluateNow()
        #expect(await harness.center.all().isEmpty)
    }

    @Test func staleBacklogIsSkippedWithoutAlerting() async throws {
        let harness = try Harness(now: Date(timeIntervalSince1970: TimeInterval(afternoon)))
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        await harness.runtime.attach(history: harness.history)
        try await harness.runtime.update(HeartAlertsPreferences(rates: HeartRateAlertSettings(highEnabled: true)))
        try insert(harness.history, from: afternoon, minutes: 15, bpm: 135)
        // The phone was away: the offload lands five hours later.
        harness.clock.now = Date(timeIntervalSince1970: TimeInterval(afternoon + 5 * 3600))
        await harness.runtime.evaluateNow()
        #expect(await harness.center.all().isEmpty)
    }

    @Test func overnightCheckNotifiesOnceWithNamedMetrics() async throws {
        let morning = Date(timeIntervalSince1970: TimeInterval(night + 6 * 3600)) // 08:00 local
        let harness = try Harness(now: morning)
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        try await harness.runtime.update(HeartAlertsPreferences(overnightCheckEnabled: true))
        await harness.runtime.attach(overnightSource: FixedNights(today: morning))
        await harness.runtime.appBecameActive()
        await harness.runtime.appBecameActive()

        let scheduled = await harness.center.all()
        #expect(scheduled.count == 1)
        let request = try #require(scheduled.first)
        #expect(request.title == "Overnight check")
        #expect(request.detail.contains("resting heart rate was higher"))
        #expect(request.detail.contains("heart rate variability was lower"))
        #expect(request.detail.contains("Alcohol, late meals, a hot room, hard training or travel"))
        #expect(await harness.runtime.history().first?.overnightMetrics.count == 3)
    }

    @Test func firstFlaggedNightIsQuietThenUpdatedSecondNightNotifiesOnce() async throws {
        let morning = Date(timeIntervalSince1970: TimeInterval(night + 6 * 3600))
        let harness = try Harness(now: morning)
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        try await harness.runtime.update(HeartAlertsPreferences(overnightCheckEnabled: true))
        await harness.runtime.attach(overnightSource: FixedNights(today: morning, flaggedNights: 1))
        await harness.runtime.appBecameActive()
        #expect(await harness.center.all().isEmpty)
        // Sync finishes and the preceding night's assessment becomes available.
        await harness.runtime.attach(overnightSource: FixedNights(today: morning, flaggedNights: 2))
        await harness.runtime.appBecameActive()
        await harness.runtime.appBecameActive()
        #expect(await harness.center.all().count == 1)
        #expect(await harness.runtime.history().first?.overnightMetrics.map(\.metric) == [.restingHeartRate, .heartRateVariability, .skinTemperatureDeviation])
        let saved = await harness.runtime.store.state()
        #expect(saved.overnight.episodeNotified == true)
    }

    @Test func cardioFitnessNoticeIsOptInAndRateLimited() async throws {
        let harness = try Harness(now: Date(timeIntervalSince1970: TimeInterval(afternoon)))
        defer { harness.cleanUp() }
        await harness.policy.setAuthorization(.authorized)
        #expect(await harness.runtime.cardioFitnessLowRange(estimateID: "a", measuredAt: harness.clock.now) == false)
        try await harness.runtime.update(HeartAlertsPreferences(cardioFitnessEnabled: true))
        #expect(await harness.runtime.cardioFitnessLowRange(estimateID: "a", measuredAt: harness.clock.now))
        harness.clock.now = harness.clock.now.addingTimeInterval(60 * 86_400)
        #expect(await harness.runtime.cardioFitnessLowRange(estimateID: "b", measuredAt: harness.clock.now) == false)
        #expect(await harness.center.all().count == 1)
    }

    @Test func copyStaysNeutral() {
        let episode = HeartRateAlertEpisode(id: "high-1", kind: .high, thresholdBPM: 120, start: afternoon,
                                            detectedAt: afternoon + 600, end: afternoon + 600, medianBPM: 131,
                                            extremeBPM: 135, confirmationBPM: 130, duringSleep: false, minutes: [])
        let low = HeartRateAlertEpisode(id: "low-1", kind: .low, thresholdBPM: 40, start: night,
                                        detectedAt: night + 600, end: night + 600, medianBPM: 38,
                                        extremeBPM: 37, confirmationBPM: 38, duringSleep: true, minutes: [])
        let texts = [
            HeartAlertsCopy.request(for: episode, family: .highHeartRate, now: .now, calendar: utc8(), allowDuringQuietHours: false).detail,
            HeartAlertsCopy.request(for: low, family: .lowHeartRate, now: .now, calendar: utc8(), allowDuringQuietHours: true).detail,
            HeartAlertsCopy.overnightSentence([(.restingHeartRate, .higher), (.heartRateVariability, .lower), (.respiratoryRate, .higher)]),
            HeartAlertsCopy.overnightFactors,
            HeartAlertsCopy.cardioFitnessRequest(id: "c", now: .now, calendar: utc8()).detail
        ]
        let banned = ["tachycardia", "bradycardia", "abnormal", "dangerous", "condition", "diagnos", "afib",
                      "arrhythmia", "irregular", "you may be sick", "sick", "—", "!"]
        for text in texts {
            for word in banned { #expect(!text.lowercased().contains(word), "\(word) in \(text)") }
        }
        #expect(texts[1].contains("while you seemed to be asleep"))
        #expect(texts[2].hasPrefix("Three of last night's readings were outside your usual range."))
        #expect(texts[2].contains("resting heart rate was higher, heart rate variability was lower and breathing rate was higher"))
    }

    @Test func heartAlertLinksOpenTheHeartAlertsScreen() {
        #expect(ShellDeepLink(notification: .heartAlert("high-1")) == .settings(.heartAlerts))
    }
}

/// Twenty ordinary nights, then a night with resting heart rate up and HRV down.
nonisolated private struct FixedNights: HeartAlertsOvernightSource {
    let today: Date
    var flaggedNights: Int = 2

    func nights(endingOn: Date, days: Int, calendar: Calendar) async -> [OvernightVitalsNight] {
        (0..<21).map { offset in
            let day = calendar.date(byAdding: .day, value: -(20 - offset), to: today)!
            let key = HeartAlertsDay.key(day, calendar: calendar)
            if offset >= 21 - flaggedNights {
                return OvernightVitalsNight(night: key, values: [.restingHeartRate: 63, .heartRateVariability: 38, .respiratoryRate: 14.5, .skinTemperatureDeviation: 35.6])
            }
            let wobble = Double(offset % 5) - 2
            return OvernightVitalsNight(night: key, values: [
                .restingHeartRate: 52 + wobble * 0.5, .heartRateVariability: 60 + wobble * 3, .respiratoryRate: 14.5 + wobble * 0.2, .skinTemperatureDeviation: 35
            ])
        }
    }

    func mainSleeps(endingOn: Date, days: Int, calendar: Calendar) async -> [DateInterval] { [] }
}
