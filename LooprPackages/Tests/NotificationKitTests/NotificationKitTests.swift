import NotificationKit
import Foundation
import XCTest

private actor SchedulingSpy: NotificationSchedulingClient {
    var requests: [NotificationRequest] = []
    func schedule(_ request: NotificationRequest) async throws { requests.append(request) }
    func remove(identities: Set<NotificationIdentity>) async { requests.removeAll { identities.contains($0.identity) } }
    func count() -> Int { requests.count }
    func identities() -> Set<NotificationIdentity> { Set(requests.map(\.identity)) }
}

private func request(family: NotificationFamily = .battery, hour: Int = 12,
                     objectID: String = "object", day: String = "2026-08-23") -> NotificationRequest {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: hour))!
    let id = NotificationIdentity(family: family, objectID: objectID, day: day)
    return .init(identity: id, fireDate: date, title: "Update", detail: "Heart rate 142",
                 sensitivity: .healthDerived, deepLink: NotificationPolicy.deepLink(for: family, target: "object"))
}

final class NotificationDedupeTests: XCTestCase {
    func testTenConcurrentRequestsScheduleOnce() async {
        let spy = SchedulingSpy(); let claims = NotificationClaimLedger()
        let policy = NotificationPolicy(client: spy, claims: claims)
        await policy.setAuthorization(.authorized)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try? await policy.schedule(request()) } }
        }
        let scheduledCount = await spy.count()
        let claimCount = await claims.count()
        XCTAssertEqual(scheduledCount, 1)
        XCTAssertEqual(claimCount, 1)
    }

    func testPersistedClaimSurvivesProcessRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("notification-claims.json")
        let identity = request().identity
        let original = NotificationClaimLedger(persistenceURL: url)
        let originalClaim = try await original.claim(identity)
        XCTAssertTrue(originalClaim)

        let restored = NotificationClaimLedger(persistenceURL: url)
        let duplicateClaim = try await restored.claim(identity)
        let count = await restored.count()
        XCTAssertFalse(duplicateClaim)
        XCTAssertEqual(count, 1)
    }

    func testClaimWriteFailureDoesNotReserveTheNotificationInMemory() async throws {
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-notification-claim-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        try Data().write(to: blockedDirectory)
        let claims = NotificationClaimLedger(
            persistenceURL: blockedDirectory.appendingPathComponent("claims.json")
        )

        do {
            _ = try await claims.claim(request().identity)
            XCTFail("a claim write failure must be reported")
        } catch {}

        let count = await claims.count()
        XCTAssertEqual(count, 0)
    }

    func testCorruptClaimLedgerFailsClosed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-corrupt-notification-claims-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not-json".utf8).write(to: url)
        let claims = NotificationClaimLedger(persistenceURL: url)

        do {
            _ = try await claims.claim(request().identity)
            XCTFail("corrupt claim state must block scheduling")
        } catch {
            XCTAssertEqual(error as? NotificationPersistenceError, .unreadableClaims)
        }
    }
}

final class NotificationQuietHoursTests: XCTestCase {
    func testDefaultOffThenConfiguredSuppression() async throws {
        let spy = SchedulingSpy(); let policy = NotificationPolicy(client: spy, claims: .init(), calendar: {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
        }())
        await policy.setAuthorization(.authorized)
        let defaultResult = try await policy.schedule(request(hour: 23))
        XCTAssertEqual(defaultResult, .scheduled)
        await policy.setQuietHours(.init(startHour: 22, endHour: 7))
        let other = NotificationRequest(identity: .init(family: .battery, objectID: "other", day: "2026-08-24"),
            fireDate: request(hour: 23).fireDate, title: "Update", detail: "detail",
            sensitivity: .ordinary, deepLink: .device("other"))
        let quietResult = try await policy.schedule(other)
        XCTAssertEqual(quietResult, .quietHours)
    }
}

final class NotificationSensitiveContentTests: XCTestCase {
    func testHealthValueNeverAppearsOnLockScreen() {
        let value = request()
        XCTAssertFalse(value.lockScreenBody.contains("142"))
        XCTAssertEqual(value.detail, "Heart rate 142")
    }
}

final class NotificationDeniedStateTests: XCTestCase {
    func testDeniedNoOpsAndUndeterminedQueuesThenResolves() async throws {
        let spy = SchedulingSpy(); let policy = NotificationPolicy(client: spy, claims: .init())
        let queuedResult = try await policy.schedule(request())
        XCTAssertEqual(queuedResult, .queued)
        let queuedCount = await spy.count()
        XCTAssertEqual(queuedCount, 0)
        await policy.setAuthorization(.authorized)
        let resolvedCount = await spy.count()
        XCTAssertEqual(resolvedCount, 1)
        let denied = NotificationPolicy(client: SchedulingSpy(), claims: .init())
        await denied.setAuthorization(.denied)
        let deniedResult = try await denied.schedule(request())
        XCTAssertEqual(deniedResult, .denied)
    }
}

final class NotificationPreferenceMatrixTests: XCTestCase {
    // Updated for the heart alerts work: four opt-in heart families were
    // added, and the six families nothing publishes now default to off
    // instead of showing a toggle that does nothing.
    func testNineteenFamiliesAndIndependentDefaults() async {
        XCTAssertEqual(NotificationFamily.allCases.count, 19)
        let policy = NotificationPolicy(client: SchedulingSpy(), claims: .init())
        let enabledByDefault: Set<NotificationFamily> = [
            .detectedWorkouts, .battery, .chargeGuidance, .disconnect, .staleData,
            .workoutCompletion, .breathingCompletion
        ]
        for family in NotificationFamily.allCases {
            let enabled = await policy.isEnabled(family)
            XCTAssertEqual(enabled, enabledByDefault.contains(family), "\(family)")
        }
    }

    func testEveryHeartAlertFamilyStartsOff() async {
        let policy = NotificationPolicy(client: SchedulingSpy(), claims: .init())
        for family in NotificationFamily.heartAlerts {
            let enabled = await policy.isEnabled(family)
            XCTAssertFalse(enabled)
        }
    }

    func testHabitReminderUsesGenericLockCopyAndDayDeepLink() async {
        let fireDate = Date(timeIntervalSince1970: 1_700_000_000)
        let reminder = HabitReminderRequestFactory.request(
            behaviorDay: "2026-08-29",
            fireDate: fireDate
        )
        XCTAssertEqual(reminder.identity.family, .journaling)
        XCTAssertEqual(reminder.identity.objectID, "habit-check-in")
        XCTAssertEqual(reminder.fireDate, fireDate)
        XCTAssertEqual(reminder.deepLink, .journal("2026-08-29"))
        XCTAssertEqual(reminder.lockScreenBody, "Ready for yesterday's habit check-in?")
        XCTAssertFalse(reminder.lockScreenBody.localizedCaseInsensitiveContains("alcohol"))
    }

    func testPreferencesPersistAndCycleRequiresSeparateOptIn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("notification-preferences.json")
        let first = NotificationPolicy(
            client: SchedulingSpy(), claims: .init(), preferenceURL: url
        )
        try await first.setEnabled(false, for: .battery)
        try await first.setEnabled(true, for: .cycleReminders)

        let restored = NotificationPolicy(
            client: SchedulingSpy(), claims: .init(), preferenceURL: url
        )
        let batteryEnabled = await restored.isEnabled(.battery)
        let cycleEnabled = await restored.isEnabled(.cycleReminders)
        XCTAssertFalse(batteryEnabled)
        XCTAssertTrue(cycleEnabled)

        let context = NotificationFamilyContext(
            targetID: "cycle", day: "2026-08-23", fireDate: Date(),
            title: "Cycle", detail: "Update", cycleTrackingEnabled: false
        )
        XCTAssertNil(NotificationFamilyFactory.request(family: .cycleReminders, context: context))
    }

    func testAllFifteenFamiliesToggleIndependently() async throws {
        let policy = NotificationPolicy(client: SchedulingSpy(), claims: .init())
        for family in NotificationFamily.allCases { try await policy.setEnabled(true, for: family) }
        for family in NotificationFamily.allCases {
            try await policy.setEnabled(false, for: family)
            for observed in NotificationFamily.allCases {
                let enabled = await policy.isEnabled(observed)
                XCTAssertEqual(enabled, observed != family)
            }
            try await policy.setEnabled(true, for: family)
        }
    }

    func testPreferenceWriteFailureRollsBackTheToggle() async throws {
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-notification-preference-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        try Data().write(to: blockedDirectory)
        let policy = NotificationPolicy(
            client: SchedulingSpy(),
            claims: .init(),
            preferenceURL: blockedDirectory.appendingPathComponent("preferences.json")
        )

        do {
            try await policy.setEnabled(false, for: .battery)
            XCTFail("a preference write failure must be reported")
        } catch {}

        let batteryEnabled = await policy.isEnabled(.battery)
        XCTAssertTrue(batteryEnabled)
    }

    func testCorruptPreferencesFailClosed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-corrupt-notification-preferences-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not-json".utf8).write(to: url)
        let policy = NotificationPolicy(
            client: SchedulingSpy(), claims: .init(), preferenceURL: url
        )

        for family in NotificationFamily.allCases {
            let enabled = await policy.isEnabled(family)
            XCTAssertFalse(enabled)
        }
    }
}

final class NotificationFamilyDeepLinkTests: XCTestCase {
    func testEveryFamilyMapsToTypedLink() {
        let links = NotificationFamily.allCases.map { NotificationPolicy.deepLink(for: $0, target: $0.rawValue) }
        XCTAssertEqual(links.count, NotificationFamily.allCases.count)
        XCTAssertEqual(NotificationPolicy.deepLink(for: .highHeartRate, target: "high-1"), .heartAlert("high-1"))
        XCTAssertEqual(NotificationPolicy.deepLink(for: .workoutCompletion, target: "w1"), .workout("w1"))
    }

    func testResponsePayloadRoundTripsEveryFamily() throws {
        for family in NotificationFamily.allCases {
            let expected = NotificationPolicy.deepLink(for: family, target: family.rawValue)
            let userInfo = try NotificationResponsePayload.userInfo(for: expected)
            XCTAssertEqual(try NotificationResponsePayload.deepLink(from: userInfo), expected)
        }
    }

    func testSensitiveFactoryRejectsUnvalidatedHealthData() {
        let context = NotificationFamilyContext(
            targetID: "health", day: "2026-08-23", fireDate: Date(),
            title: "Health", detail: "Private", isValidated: false
        )
        XCTAssertNil(NotificationFamilyFactory.request(family: .validatedHealthChanges, context: context))
        XCTAssertNotNil(NotificationFamilyFactory.request(family: .battery, context: context))
    }
}

final class ProductNotificationEventSourceTests: XCTestCase {
    func testWorkoutAndBreathingCompletionFireOncePerSession() async throws {
        let spy = SchedulingSpy()
        let policy = NotificationPolicy(client: spy, claims: .init())
        await policy.setAuthorization(.authorized)
        let source = ProductNotificationEventSource(policy: policy)

        try await source.workoutCompleted(id: "workout-1", day: "2026-08-24")
        try await source.workoutCompleted(id: "workout-1", day: "2026-08-24")
        try await source.breathingCompleted(id: "breathing-1", day: "2026-08-24")
        try await source.breathingCompleted(id: "breathing-1", day: "2026-08-24")

        let identities = await spy.identities()
        XCTAssertEqual(identities.count, 2)
        XCTAssertTrue(identities.contains(.init(family: .workoutCompletion, objectID: "workout-1", day: "2026-08-24")))
        XCTAssertTrue(identities.contains(.init(family: .breathingCompletion, objectID: "breathing-1", day: "2026-08-24")))
    }

    func testPublishedConnectionAndBatteryTransitionsUseCentralPolicy() async throws {
        let spy = SchedulingSpy()
        let policy = NotificationPolicy(client: spy, claims: .init())
        await policy.setAuthorization(.authorized)
        let source = ProductNotificationEventSource(policy: policy)
        for family in [NotificationFamily.disconnect, .staleData, .battery, .chargeGuidance] {
            _ = try await source.publish(
                family,
                targetID: "strap-1",
                day: "2026-08-24",
                title: "Device update",
                detail: "Open Device Center for details."
            )
        }
        let identities = await spy.identities()
        XCTAssertEqual(Set(identities.map(\.family)), [.disconnect, .staleData, .battery, .chargeGuidance])
    }
}

final class NotificationDeletionMatrixTests: XCTestCase {
    func testPreferenceDisableRemovesPendingRequest() async throws {
        let spy = SchedulingSpy(); let policy = NotificationPolicy(client: spy, claims: .init())
        await policy.setAuthorization(.authorized)
        _ = try await policy.schedule(request())
        try await policy.setEnabled(false, for: .battery)
        let pendingCount = await spy.count()
        XCTAssertEqual(pendingCount, 0)
    }

    func testPreferenceDisableRemovesRequestScheduledBeforeProcessRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claimURL = directory.appendingPathComponent("claims.json")
        let preferenceURL = directory.appendingPathComponent("preferences.json")
        let spy = SchedulingSpy()
        let original = NotificationPolicy(
            client: spy,
            claims: NotificationClaimLedger(persistenceURL: claimURL),
            preferenceURL: preferenceURL
        )
        await original.setAuthorization(.authorized)
        _ = try await original.schedule(request())

        let restored = NotificationPolicy(
            client: spy,
            claims: NotificationClaimLedger(persistenceURL: claimURL),
            preferenceURL: preferenceURL
        )
        try await restored.setEnabled(false, for: .battery)

        let pendingCount = await spy.count()
        XCTAssertEqual(pendingCount, 0)
    }


    func testDeletingUnderlyingObjectAndDayRemovesOnlyMatchingPendingRequests() async throws {
        let spy = SchedulingSpy(); let policy = NotificationPolicy(client: spy, claims: .init())
        await policy.setAuthorization(.authorized)
        _ = try await policy.schedule(request(objectID: "first", day: "2026-08-23"))
        _ = try await policy.schedule(request(objectID: "second", day: "2026-08-24"))
        try await policy.remove(objectID: "first")
        var identities = await spy.identities()
        XCTAssertEqual(identities.map(\.objectID), ["second"])
        try await policy.remove(day: "2026-08-24")
        identities = await spy.identities()
        XCTAssertTrue(identities.isEmpty)
    }
}

private func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
}

private func heartRequest(hour: Int, minute: Int = 0, behavior: QuietHoursBehavior,
                          expiresAt: Date? = nil) -> NotificationRequest {
    let date = utc().date(from: DateComponents(year: 2026, month: 9, day: 23, hour: hour, minute: minute))!
    return NotificationRequest(
        identity: .init(family: .highHeartRate, objectID: "high-\(hour)-\(minute)", day: "2026-09-23"),
        fireDate: date, title: "High heart rate",
        detail: "Your heart rate stayed above 120 bpm for 10 minutes while you seemed to be at rest.",
        sensitivity: .userRequestedAlert, deepLink: .heartAlert("high-\(hour)"),
        quietHoursBehavior: behavior, expiresAt: expiresAt)
}

final class NotificationQuietHoursBehaviorTests: XCTestCase {
    func testMinuteBoundariesAndMidnightWrap() {
        let calendar = utc()
        let hours = QuietHours(startMinute: 22 * 60 + 30, endMinute: 6 * 60 + 45)
        func at(_ h: Int, _ m: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: h, minute: m))!
        }
        XCTAssertFalse(hours.contains(at(22, 29), calendar: calendar))
        XCTAssertTrue(hours.contains(at(22, 30), calendar: calendar))
        XCTAssertTrue(hours.contains(at(3, 0), calendar: calendar))
        XCTAssertTrue(hours.contains(at(6, 44), calendar: calendar))
        XCTAssertFalse(hours.contains(at(6, 45), calendar: calendar))
        XCTAssertEqual(hours.end(after: at(23, 0), calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 6, minute: 45)))
        XCTAssertEqual(hours.end(after: at(2, 0), calendar: calendar), at(6, 45))
        XCTAssertFalse(QuietHours(startHour: 7, endHour: 7).contains(at(7, 0), calendar: calendar))
        XCTAssertEqual(QuietHours.standard, QuietHours(startHour: 22, endHour: 7))
    }

    func testHeartAlertsDeferUntilQuietHoursEndUnlessAllowed() async throws {
        let spy = SchedulingSpy()
        let policy = NotificationPolicy(client: spy, claims: .init(), calendar: utc())
        await policy.setAuthorization(.authorized)
        await policy.setQuietHours(.standard)
        try await policy.setEnabled(true, for: .highHeartRate)

        let deferred = try await policy.schedule(heartRequest(hour: 3, behavior: .deferUntilEnd))
        XCTAssertEqual(deferred, .deferred)
        let scheduledDates = await spy.requests.map(\.fireDate)
        XCTAssertEqual(scheduledDates, [utc().date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 7))!])

        let allowed = try await policy.schedule(heartRequest(hour: 3, minute: 5, behavior: .deliver))
        XCTAssertEqual(allowed, .scheduled)

        let suppressed = try await policy.schedule(heartRequest(hour: 3, minute: 10, behavior: .suppress))
        XCTAssertEqual(suppressed, .quietHours)

        let daytime = try await policy.schedule(heartRequest(hour: 14, behavior: .deferUntilEnd))
        XCTAssertEqual(daytime, .scheduled)
    }

    func testRemindersThePersonScheduledIgnoreQuietHours() async throws {
        let spy = SchedulingSpy()
        let policy = NotificationPolicy(client: spy, claims: .init(), calendar: utc())
        await policy.setAuthorization(.authorized)
        await policy.setQuietHours(.standard)
        try await policy.setEnabled(true, for: .journaling)
        let late = utc().date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 22, minute: 30))!
        let reminder = HabitReminderRequestFactory.request(behaviorDay: "2026-09-23", fireDate: late)
        let result = try await policy.schedule(reminder)
        XCTAssertEqual(result, .scheduled)
    }

    func testDeliverySettingsPersistAndDefaultToQuietHoursOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delivery.json")
        let fresh = NotificationPolicy(client: SchedulingSpy(), claims: .init(), deliveryURL: url)
        let initial = await fresh.deliverySettings()
        XCTAssertEqual(initial, .standard)
        XCTAssertTrue(initial.quietHoursEnabled)

        let edited = NotificationDeliverySettings(quietHoursEnabled: true,
                                                  quietHours: QuietHours(startMinute: 23 * 60, endMinute: 6 * 60 + 30))
        try await fresh.setDeliverySettings(edited)
        let restored = NotificationPolicy(client: SchedulingSpy(), claims: .init(), deliveryURL: url)
        let restoredSettings = await restored.deliverySettings()
        XCTAssertEqual(restoredSettings, edited)

        try Data("not-json".utf8).write(to: url)
        let corrupt = NotificationPolicy(client: SchedulingSpy(), claims: .init(), deliveryURL: url)
        let corruptSettings = await corrupt.deliverySettings()
        XCTAssertEqual(corruptSettings, .standard)
    }
}

final class NotificationPendingQueueTests: XCTestCase {
    func testQueuedRequestsSurviveAnExitAndFlushOnceAuthorized() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pendingURL = directory.appendingPathComponent("pending.json")
        let first = NotificationPolicy(client: SchedulingSpy(), claims: .init(), pendingURL: pendingURL)
        let queued = try await first.schedule(request())
        XCTAssertEqual(queued, .queued)
        let duplicateQueue = try await first.schedule(request())
        XCTAssertEqual(duplicateQueue, .queued)
        let firstPending = await first.pendingRequests()
        XCTAssertEqual(firstPending.count, 1)

        // The process exits; a new one restores the queue from disk.
        let spy = SchedulingSpy()
        let second = NotificationPolicy(client: spy, claims: .init(), pendingURL: pendingURL)
        let restored = await second.pendingRequests()
        XCTAssertEqual(restored, [request()])
        await second.setAuthorization(.authorized)
        let delivered = await spy.count()
        XCTAssertEqual(delivered, 1)
        let remaining = await second.pendingRequests()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
    }

    func testExpiredRequestsAreDroppedInsteadOfDeliveredLate() async throws {
        let spy = SchedulingSpy()
        let clock = TestClock(utc().date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 14, minute: 1))!)
        let policy = NotificationPolicy(client: spy, claims: .init(), calendar: utc(), now: { clock.now })
        try await policy.setEnabled(true, for: .highHeartRate)
        let old = heartRequest(hour: 14, behavior: .deferUntilEnd,
                               expiresAt: utc().date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 15)))
        let queued = try await policy.schedule(old)
        XCTAssertEqual(queued, .queued)
        // Permission arrives long after the alert stopped being useful.
        clock.now = utc().date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 18))!
        await policy.setAuthorization(.authorized)
        let count = await spy.count()
        XCTAssertEqual(count, 0)
    }
}

final class NotificationPresentationTests: XCTestCase {
    func testUserRequestedAlertsShowTheirTextOnTheLockScreen() {
        let alert = heartRequest(hour: 14, behavior: .deferUntilEnd)
        XCTAssertEqual(alert.lockScreenBody, alert.detail)
        XCTAssertTrue(alert.lockScreenBody.contains("120 bpm"))
    }

    func testEveryFamilyHasARegisteredCategory() {
        let registered = Set(NotificationCategoryCatalog.all.map(\.identifier))
        for family in NotificationFamily.allCases {
            XCTAssertTrue(registered.contains(NotificationCategoryCatalog.category(for: family)), "\(family)")
        }
        let heart = NotificationCategoryCatalog.all.first { $0.identifier == NotificationCategoryCatalog.heartAlert }
        XCTAssertEqual(heart?.actions.map(\.identifier), [NotificationCategoryCatalog.pauseForTodayAction])
    }

    func testUserInfoCarriesFamilyForActionHandlers() throws {
        let alert = heartRequest(hour: 14, behavior: .deferUntilEnd)
        let info = try NotificationResponsePayload.userInfo(for: alert)
        XCTAssertEqual(NotificationResponsePayload.family(from: info), .highHeartRate)
        XCTAssertEqual(try NotificationResponsePayload.deepLink(from: info), .heartAlert("high-14"))
    }

    func testRequestsRoundTripThroughJSON() throws {
        let alert = heartRequest(hour: 3, behavior: .deliver, expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(alert)
        XCTAssertEqual(try JSONDecoder().decode(NotificationRequest.self, from: data), alert)
    }

    func testUnwiredFamiliesAreOffAndOptIn() {
        for family in NotificationFamily.unwired {
            XCTAssertFalse(family.isEnabledByDefault)
        }
        XCTAssertEqual(NotificationFamily.unwired.count, 5)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
