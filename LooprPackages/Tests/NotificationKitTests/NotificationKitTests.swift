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
    func testDisableWaitsForAnOutstandingScheduleThenRemovesIt() async throws {
        let spy = PausedSchedulingSpy()
        let claims = NotificationClaimLedger()
        let policy = NotificationPolicy(client: spy, claims: claims)
        await policy.setAuthorization(.authorized)
        let scheduling = Task { try await policy.schedule(request()) }
        await spy.waitForSchedule()
        let disabling = Task { try await policy.setEnabled(false, for: .battery) }
        while await policy.isEnabled(.battery) { await Task.yield() }
        // Keep the external write pending while disable traverses its awaits.
        for _ in 0..<100 { await Task.yield() }
        await spy.release()
        _ = try await scheduling.value
        try await disabling.value
        let count = await spy.count()
        let claimCount = await claims.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(claimCount, 0)
    }

    func testCancelledScheduleCleansUpAnExternalWriteThatAlreadySucceeded() async throws {
        let spy = PausedSchedulingSpy()
        let claims = NotificationClaimLedger()
        let policy = NotificationPolicy(client: spy, claims: claims)
        await policy.setAuthorization(.authorized)
        let scheduling = Task { try await policy.schedule(request()) }
        await spy.waitForSchedule()
        scheduling.cancel()
        await spy.release()
        do {
            _ = try await scheduling.value
            XCTFail("Cancellation must not leave a pending notification")
        } catch is CancellationError {}
        let count = await spy.count()
        let claimCount = await claims.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(claimCount, 0)
    }

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
    func testTwentyFamiliesAndIndependentDefaults() async {
        XCTAssertEqual(NotificationFamily.allCases.count, 20)
        let policy = NotificationPolicy(client: SchedulingSpy(), claims: .init())
        let enabledByDefault: Set<NotificationFamily> = [
            .detectedWorkouts, .battery, .chargeGuidance, .disconnect, .staleData,
            .workoutCompletion, .breathingCompletion, .userReminders
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
        XCTAssertEqual(reminder.lockScreenBody, "Ready for yesterday's check-in?")
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

private actor PausedSchedulingSpy: NotificationSchedulingClient {
    private var requests: [NotificationRequest] = []
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func schedule(_ request: NotificationRequest) async throws {
        entered = true
        entry?.resume(); entry = nil
        await withCheckedContinuation { blocked = $0 }
        requests.append(request)
    }
    func waitForSchedule() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func release() { blocked?.resume(); blocked = nil }
    func remove(identities: Set<NotificationIdentity>) async { requests.removeAll { identities.contains($0.identity) } }
    func count() -> Int { requests.count }
}


// MARK: Reminders you set

private func reminderRequest(_ id: String, source: UserReminderSource = .ask, hour: Int = 9, minute: Int = 0,
                             repeats: NotificationRepeat? = nil, expiresAt: Date? = nil,
                             day: String = "once", title: String = "Stretch") -> NotificationRequest {
    let fire = utc().date(from: DateComponents(year: 2026, month: 10, day: 20, hour: hour, minute: minute))!
    return NotificationRequest(
        identity: .init(family: .userReminders, objectID: id, day: day), fireDate: fire, title: title,
        detail: "Ten slow reps.", sensitivity: .userRequestedAlert,
        deepLink: source == .ask ? .ask(id) : .patterns(id),
        quietHoursBehavior: .suppress, expiresAt: expiresAt, repeats: repeats, reminderSource: source)
}

/// A client that also answers what the system still holds as pending.
private actor ReminderSpy: NotificationSchedulingClient {
    private(set) var requests: [NotificationRequest] = []
    private(set) var removals: [Set<NotificationIdentity>] = []
    private var failing = false
    func failNext() { failing = true }
    func schedule(_ request: NotificationRequest) async throws {
        if failing { failing = false; throw NotificationPersistenceError.unreadableClaims }
        requests.append(request)
    }
    func remove(identities: Set<NotificationIdentity>) async {
        removals.append(identities)
        requests.removeAll { identities.contains($0.identity) }
    }
    func pending(among identities: Set<NotificationIdentity>) async -> Set<NotificationIdentity>? {
        Set(requests.map(\.identity)).intersection(identities)
    }
    func lose(_ identity: NotificationIdentity) { requests.removeAll { $0.identity == identity } }
    func count() -> Int { requests.count }
}

final class UserReminderFamilyTests: XCTestCase {
    private let day = utc().date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!

    private func makePolicy(client: any NotificationSchedulingClient, quiet: Bool = true, directory: URL? = nil,
                            clock: TestClock? = nil) -> NotificationPolicy {
        let value = clock ?? TestClock(day)
        return NotificationPolicy(
            client: client, claims: .init(persistenceURL: directory?.appendingPathComponent("claims.json")),
            calendar: utc(), preferenceURL: directory?.appendingPathComponent("preferences.json"),
            deliveryURL: directory?.appendingPathComponent("delivery.json"),
            reminderURL: directory?.appendingPathComponent("reminders.json"),
            historyURL: directory?.appendingPathComponent("history.json"),
            now: { value.now })
    }

    func testFamilyIsOnByDefaultAndUserScheduled() async {
        let policy = makePolicy(client: ReminderSpy())
        let enabled = await policy.isEnabled(.userReminders)
        XCTAssertTrue(enabled)
        XCTAssertTrue(NotificationFamily.userReminders.isUserScheduled)
        XCTAssertEqual(NotificationFamily.userReminders.pendingLimit, 10)
        XCTAssertEqual(NotificationCategoryCatalog.category(for: .userReminders), NotificationCategoryCatalog.reminder)
    }

    func testLockScreenShowsTheConfirmedText() {
        let value = reminderRequest("a1")
        XCTAssertEqual(value.lockScreenBody, "Ten slow reps.")
        XCTAssertEqual(value.title, "Stretch")
    }

    func testReminderArrivesInsideQuietHoursAtTheChosenTime() async throws {
        let spy = ReminderSpy()
        let policy = makePolicy(client: spy)
        await policy.setAuthorization(.authorized)
        try await policy.setDeliverySettings(.init(quietHoursEnabled: true, quietHours: .standard))
        let late = reminderRequest("late", hour: 23, minute: 30)
        let result = try await policy.schedule(late)
        XCTAssertEqual(result, .scheduled)
        let sent = await spy.requests
        XCTAssertEqual(sent.map(\.fireDate), [late.fireDate])
        let inside = await policy.quietHoursContain(minuteOfDay: 23 * 60 + 30)
        let outside = await policy.quietHoursContain(minuteOfDay: 9 * 60)
        XCTAssertTrue(inside)
        XCTAssertFalse(outside)
        try await policy.setDeliverySettings(.init(quietHoursEnabled: false))
        let off = await policy.quietHoursContain(minuteOfDay: 23 * 60 + 30)
        XCTAssertFalse(off)
    }

    func testQuietHoursStillSuppressOtherFamiliesAtTheSameMinute() async throws {
        let policy = makePolicy(client: ReminderSpy())
        await policy.setAuthorization(.authorized)
        try await policy.setDeliverySettings(.init(quietHoursEnabled: true, quietHours: .standard))
        let battery = request(family: .battery, hour: 23)
        let result = try await policy.schedule(battery)
        XCTAssertEqual(result, .quietHours)
    }

    func testTurningTheFamilyOffRemovesWaitingRemindersAndStopsNewOnes() async throws {
        let spy = ReminderSpy()
        let policy = makePolicy(client: spy)
        await policy.setAuthorization(.authorized)
        _ = try await policy.schedule(reminderRequest("a1"))
        _ = try await policy.schedule(reminderRequest("a2"))
        try await policy.setEnabled(false, for: .userReminders)
        var waiting = try await policy.pendingReminders()
        let sentAfterOff = await spy.count()
        XCTAssertTrue(waiting.isEmpty)
        XCTAssertEqual(sentAfterOff, 0)
        let result = try await policy.schedule(reminderRequest("a3"))
        XCTAssertEqual(result, .disabled)
        waiting = try await policy.pendingReminders()
        let sentAfterRefused = await spy.count()
        XCTAssertTrue(waiting.isEmpty)
        XCTAssertEqual(sentAfterRefused, 0)
        let history = await policy.reminderHistory()
        XCTAssertEqual(history.first?.outcome, .familyOff)
    }

    func testDeniedPermissionSchedulesNothingAndIsRecorded() async throws {
        let spy = ReminderSpy()
        let policy = makePolicy(client: spy)
        await policy.setAuthorization(.denied)
        let result = try await policy.schedule(reminderRequest("a1"))
        XCTAssertEqual(result, .denied)
        let sent = await spy.count()
        let waiting = try await policy.pendingReminders()
        let history = await policy.reminderHistory()
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(waiting.isEmpty)
        XCTAssertEqual(history.map(\.outcome), [.notAllowed])
    }

    func testDailyReminderRepeatsAndSurvivesItsFirstFireDate() async throws {
        let spy = ReminderSpy()
        let clock = TestClock(day)
        let policy = makePolicy(client: spy, clock: clock)
        await policy.setAuthorization(.authorized)
        let daily = reminderRequest("daily", hour: 8, minute: 15, repeats: .daily, day: "recurring")
        let once = reminderRequest("once", hour: 8, minute: 15)
        _ = try await policy.schedule(daily)
        _ = try await policy.schedule(once)
        let sent = await spy.requests
        XCTAssertEqual(sent.map(\.repeats), [.daily, nil])
        XCTAssertEqual(daily.identity.day, "recurring")
        // Two days later the one-shot has fired. The daily reminder is still waiting and comes round at 08:15.
        clock.now = utc().date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
        let waiting = try await policy.pendingReminders()
        XCTAssertEqual(waiting.map(\.identity.objectID), ["daily"])
        let next = waiting[0].nextFireDate(after: clock.now, calendar: utc())
        XCTAssertEqual(next, utc().date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 8, minute: 15)))
        let firedStillThere = await spy.requests.map(\.identity.objectID)
        XCTAssertTrue(firedStillThere.contains("once"), "a fired reminder stays in Notification Center")
    }

    func testListShowsTimeRepeatAndSourceSoonestFirst() async throws {
        let policy = makePolicy(client: ReminderSpy())
        await policy.setAuthorization(.authorized)
        _ = try await policy.schedule(reminderRequest("late", hour: 21, minute: 0))
        _ = try await policy.schedule(reminderRequest("test", source: .patternsTest, hour: 7, minute: 45, repeats: .daily, day: "recurring"))
        let waiting = try await policy.pendingReminders()
        XCTAssertEqual(waiting.map(\.identity.objectID), ["test", "late"])
        XCTAssertEqual(waiting.map(\.reminderSource), [.patternsTest, .ask])
        XCTAssertEqual(waiting[0].minuteOfDay(calendar: utc()), 7 * 60 + 45)
        XCTAssertEqual(waiting[0].repeats, .daily)
        XCTAssertEqual(waiting[0].deepLink, .patterns("test"))
        XCTAssertEqual(waiting[1].deepLink, .ask("late"))
    }

    /// ICP R2-HAB-06: a rule reminder on three weekdays is three weekly requests and one reminder in the cap.
    func testTheCapCountsAReminderOnSeveralWeekdaysOnce() async throws {
        let policy = makePolicy(client: ReminderSpy())
        await policy.setAuthorization(.authorized)
        for index in 0..<9 {
            _ = try await policy.schedule(reminderRequest("r\(index)", hour: 10, minute: index))
        }
        for day in ["weekday-2", "weekday-4", "weekday-6"] {
            let result = try await policy.schedule(reminderRequest("protocol.rule.gym", hour: 18, repeats: .weekly, day: day))
            XCTAssertEqual(result, .scheduled, day)
        }
        let eleventh = try await policy.schedule(reminderRequest("r9", hour: 20))
        XCTAssertEqual(eleventh, .limitReached, "nine and the gym rule are ten")
    }

    func testTenReminderCapRefusesTheEleventhAndSchedulesNothing() async throws {
        let spy = ReminderSpy()
        let policy = makePolicy(client: spy)
        await policy.setAuthorization(.authorized)
        for index in 0..<10 {
            let result = try await policy.schedule(reminderRequest("r\(index)", hour: 10 + index % 8, minute: index))
            XCTAssertEqual(result, .scheduled)
        }
        let eleventh = try await policy.schedule(reminderRequest("r10", hour: 20))
        XCTAssertEqual(eleventh, .limitReached)
        let sent = await spy.count()
        XCTAssertEqual(sent, 10)
        // The same reminder again does not need a free place.
        let again = try await policy.schedule(reminderRequest("r3", hour: 13, minute: 3))
        XCTAssertEqual(again, .duplicate)
        // Cancelling one frees a place.
        try await policy.remove(family: .userReminders, objectID: "r0")
        let afterCancel = try await policy.schedule(reminderRequest("r10", hour: 20))
        XCTAssertEqual(afterCancel, .scheduled)
        let history = await policy.reminderHistory()
        XCTAssertTrue(history.contains { $0.outcome == .full })
    }

    func testCapIgnoresOtherFamiliesAndFiredReminders() async throws {
        let spy = ReminderSpy()
        let clock = TestClock(day)
        let policy = makePolicy(client: spy, clock: clock)
        await policy.setAuthorization(.authorized)
        for index in 0..<10 { _ = try await policy.schedule(reminderRequest("r\(index)", hour: 10, minute: index)) }
        let battery = try await policy.schedule(request(family: .battery, hour: 12, objectID: "b1"))
        XCTAssertEqual(battery, .scheduled)
        clock.now = utc().date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        let next = try await policy.schedule(reminderRequest("later", hour: 10, minute: 30, day: "2026-10-22"))
        XCTAssertEqual(next, .scheduled, "reminders that already fired free their places")
    }

    func testCancelOneFromTheListRemovesItFromTheSystemAndTheList() async throws {
        let spy = ReminderSpy()
        let policy = makePolicy(client: spy)
        await policy.setAuthorization(.authorized)
        _ = try await policy.schedule(reminderRequest("patterns.t1", source: .patternsTest, repeats: .daily, day: "recurring"))
        _ = try await policy.schedule(reminderRequest("keep"))
        try await policy.remove(family: .userReminders, objectID: "patterns.t1")
        let waiting = try await policy.pendingReminders()
        let sent = await spy.requests.map(\.identity.objectID)
        XCTAssertEqual(waiting.map(\.identity.objectID), ["keep"])
        XCTAssertEqual(sent, ["keep"])
    }

    func testDeleteAllLeavesNoReminderInTheListOrTheSystem() async throws {
        let spy = ReminderSpy()
        let policy = makePolicy(client: spy)
        await policy.setAuthorization(.authorized)
        for index in 0..<4 { _ = try await policy.schedule(reminderRequest("r\(index)", hour: 10, minute: index)) }
        _ = try await policy.schedule(reminderRequest("d", repeats: .daily, day: "recurring"))
        try await policy.remove()
        let waiting = try await policy.pendingReminders()
        let sent = await spy.count()
        XCTAssertTrue(waiting.isEmpty)
        XCTAssertEqual(sent, 0)
    }

    func testAReminderTheSystemNoLongerHoldsDropsOutOfTheList() async throws {
        let spy = ReminderSpy()
        let policy = makePolicy(client: spy)
        await policy.setAuthorization(.authorized)
        let gone = reminderRequest("gone", repeats: .daily, day: "recurring")
        _ = try await policy.schedule(gone)
        _ = try await policy.schedule(reminderRequest("kept"))
        await spy.lose(gone.identity)
        let waiting = try await policy.pendingReminders()
        XCTAssertEqual(waiting.map(\.identity.objectID), ["kept"])
    }

    func testAnExpiredDailyReminderIsCancelledInTheSystem() async throws {
        let spy = ReminderSpy()
        let clock = TestClock(day)
        let policy = makePolicy(client: spy, clock: clock)
        await policy.setAuthorization(.authorized)
        let expiry = utc().date(from: DateComponents(year: 2026, month: 10, day: 21))!
        _ = try await policy.schedule(reminderRequest("patterns.t1", source: .patternsTest, repeats: .daily, expiresAt: expiry, day: "recurring"))
        var waiting = try await policy.pendingReminders()
        XCTAssertEqual(waiting.count, 1)
        clock.now = utc().date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!
        waiting = try await policy.pendingReminders()
        let sent = await spy.count()
        XCTAssertTrue(waiting.isEmpty)
        XCTAssertEqual(sent, 0)
    }

    func testRemindersAndHistorySurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = ReminderSpy()
        let first = makePolicy(client: spy, directory: directory)
        await first.setAuthorization(.authorized)
        _ = try await first.schedule(reminderRequest("a1", hour: 8, minute: 15, repeats: .daily, day: "recurring"))
        let second = makePolicy(client: spy, directory: directory)
        await second.setAuthorization(.authorized)
        let waiting = try await second.pendingReminders()
        let history = await second.reminderHistory()
        XCTAssertEqual(waiting.map(\.identity.objectID), ["a1"])
        XCTAssertEqual(waiting.first?.repeats, .daily)
        XCTAssertEqual(waiting.first?.reminderSource, .ask)
        XCTAssertEqual(history.map(\.outcome), [.set])
        XCTAssertEqual(history.first?.minuteOfDay, 8 * 60 + 15)
        XCTAssertEqual(history.first?.repeatsDaily, true)
    }

    func testHistoryKeepsTheLatestThirtyResultsNewestFirst() async throws {
        let policy = makePolicy(client: ReminderSpy())
        await policy.setAuthorization(.denied)
        for index in 0..<35 { _ = try await policy.schedule(reminderRequest("r\(index)", title: "T\(index)")) }
        let history = await policy.reminderHistory()
        XCTAssertEqual(history.count, 30)
        XCTAssertEqual(history.first?.title, "T34")
        XCTAssertEqual(history.last?.title, "T5")
    }

    func testASchedulingFailureIsRecordedAndNothingStaysClaimed() async throws {
        let spy = ReminderSpy()
        let policy = makePolicy(client: spy)
        await policy.setAuthorization(.authorized)
        await spy.failNext()
        do {
            _ = try await policy.schedule(reminderRequest("a1"))
            XCTFail("a failed system call must reach the caller")
        } catch {}
        let waiting = try await policy.pendingReminders()
        let history = await policy.reminderHistory()
        XCTAssertTrue(waiting.isEmpty)
        XCTAssertEqual(history.map(\.outcome), [.failed])
        let retry = try await policy.schedule(reminderRequest("a1"))
        XCTAssertEqual(retry, .scheduled)
    }

    func testAnOutsideRefusalCanBeWrittenToTheHistory() async {
        let policy = makePolicy(client: ReminderSpy())
        await policy.recordReminderOutcome(.notAllowed, source: .patternsTest, title: "Test", minuteOfDay: 21 * 60, repeatsDaily: true)
        let history = await policy.reminderHistory()
        XCTAssertEqual(history.first?.source, .patternsTest)
        XCTAssertEqual(history.first?.outcome, .notAllowed)
    }

    func testARequestSavedBeforeRepeatsExistedStillDecodes() throws {
        let value = reminderRequest("a1")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        json["repeats"] = nil; json["reminderSource"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(NotificationRequest.self, from: data)
        XCTAssertNil(decoded.repeats)
        XCTAssertNil(decoded.reminderSource)
        XCTAssertEqual(decoded.identity, value.identity)
    }

    func testDeepLinksToAskAndPatternsRoundTrip() throws {
        for link in [NotificationDeepLink.ask("a1"), .patterns("t1")] {
            let info = try NotificationResponsePayload.userInfo(for: link)
            XCTAssertEqual(try NotificationResponsePayload.deepLink(from: info), link)
        }
        let request = reminderRequest("a1")
        let info = try NotificationResponsePayload.userInfo(for: request)
        XCTAssertEqual(NotificationResponsePayload.family(from: info), .userReminders)
        XCTAssertEqual(try NotificationResponsePayload.deepLink(from: info), .ask("a1"))
    }
}

// MARK: Rule reminders planned day by day (ICP round 4, Q1b and Q5)

extension UserReminderFamilyTests {
    /// A rule reminder on a week whose count is met has nothing waiting, but it stays on: it survives a restart, counts
    /// toward the ten, and "Delete all data" forgets it.
    func testAStandingReminderIsKeptCountedAndForgotten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("standing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("standing.json")
        func policy() -> NotificationPolicy {
            NotificationPolicy(client: ReminderSpy(), claims: .init(), calendar: utc(), standingURL: url, now: { [day] in day })
        }
        let first = policy()
        await first.setStanding("protocol.rule.sauna", minuteOfDay: 18 * 60)
        let restored = await policy().standingReminders()
        XCTAssertEqual(restored, ["protocol.rule.sauna": 18 * 60], "kept across a restart")

        let second = policy()
        await second.setAuthorization(.authorized)
        for index in 0..<9 {
            let result = try await second.schedule(reminderRequest("r\(index)", hour: 10, minute: index))
            XCTAssertEqual(result, .scheduled)
        }
        let eleventh = try await second.schedule(reminderRequest("r9", hour: 20))
        XCTAssertEqual(eleventh, .limitReached, "nine waiting and the sauna rule are ten")
        let own = try await second.schedule(reminderRequest("protocol.rule.sauna", hour: 18, day: "2026-10-26"))
        XCTAssertEqual(own, .scheduled, "the rule's own day needs no free place")

        try await second.forgetUserReminders()
        let forgotten = await second.standingReminders()
        XCTAssertEqual(forgotten, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await second.setStanding("protocol.rule.walk", minuteOfDay: 60)
        await second.setStanding("protocol.rule.walk", minuteOfDay: nil)
        let off = await second.standingReminders()
        XCTAssertEqual(off, [:])
    }

    /// A plan Loopr makes by itself writes no history; the person's own save still does.
    func testAReminderPlannedAgainWritesNoHistory() async throws {
        let policy = makePolicy(client: ReminderSpy())
        await policy.setAuthorization(.authorized)
        _ = try await policy.schedule(reminderRequest("protocol.rule.sauna", hour: 18, day: "2026-10-26"), recordsHistory: false)
        let quiet = await policy.reminderHistory()
        XCTAssertTrue(quiet.isEmpty)
        _ = try await policy.schedule(reminderRequest("protocol.rule.sauna", hour: 18, day: "2026-10-27"))
        let recorded = await policy.reminderHistory()
        XCTAssertEqual(recorded.map(\.outcome), [.set])
    }

    /// Requests saved before reminders named their category decode unchanged and keep the catalog's category.
    func testARequestSavedBeforeCategoriesDecodes() throws {
        let old = """
        [{"identity":{"family":"userReminders","objectID":"protocol.rule.magnesium","day":"recurring"},
          "fireDate":815000000,"title":"Magnesium, 300 mg","detail":"A rule from your protocol is due now.",
          "lockScreenBody":"A rule from your protocol is due now.","sensitivity":"userRequestedAlert",
          "deepLink":{"journal":{"_0":"2026-10-26"}},"quietHoursBehavior":"deliver","repeats":"daily"}]
        """
        let decoded = try JSONDecoder().decode([NotificationRequest].self, from: Data(old.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].category)
        XCTAssertEqual(decoded[0].categoryIdentifier, NotificationCategoryCatalog.protocolRule)
        XCTAssertEqual(decoded[0].repeats, .daily)
    }
}
