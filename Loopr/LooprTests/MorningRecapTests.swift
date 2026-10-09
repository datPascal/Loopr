import DesignSystem
import DomainKit
import Foundation
import NotificationKit
import SleepKit
import Testing
import TodayKit
@testable import Loopr

private actor MorningSchedulingSpy: NotificationSchedulingClient {
    var requests: [NotificationRequest] = []
    func schedule(_ request: NotificationRequest) async throws { requests.append(request) }
    func remove(identities: Set<NotificationIdentity>) async {}
    func count() -> Int { requests.count }
}

struct MorningRecapTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 6))! }
    private func summary(score: Double? = 48, headline: String? = "A higher resting heart rate lowered this score.") -> TodaySummary {
        TodaySummary(day: .init(year: 2026, month: 10, day: 7), overallState: .partial,
            freshness: .init(state: .partial, updatedAt: now, ageMinutes: 0, detail: ""),
            device: .init(connection: .connected, status: .partial),
            metrics: [.init(id: .recovery, title: "Recovery", value: score.map { String(Int($0)) }, unit: "%",
                state: score == nil ? .absent : .partial, source: "Synthetic", numericValue: score, numericUnit: .scorePoints)], headline: headline)
    }
    private func sleep(partial: Bool = false) -> SleepSessionSummary {
        .init(id: "night", start: now.addingTimeInterval(-8 * 3_600), end: now.addingTimeInterval(-600), durationMinutes: 470,
            isMainSleep: true, isPartial: partial, confidence: 0.8, state: .partial)
    }
    private func request(_ value: TodaySummary? = nil, partial: Bool = false, synced: Date? = nil) -> NotificationRequest? {
        LooprMorningRecapRequest.make(summary: value ?? summary(), sleep: sleep(partial: partial),
            target: StrainTarget(recovery: 48), syncedAt: synced ?? now, now: now, calendar: calendar)
    }

    @Test func contentMatchesTodayAndTheFamilyStartsOff() throws {
        let r = try #require(request())
        #expect(r.title == "Morning recap")
        #expect(r.detail == "Recovery 48. A higher resting heart rate lowered this score. Keep strain between 10 and 14 today.")
        #expect(r.lockScreenBody == r.detail)
        #expect(r.deepLink == .today("2026-10-07"))
        #expect(r.quietHoursBehavior == .deferUntilEnd)
        #expect(!NotificationFamily.recoveryReadiness.isEnabledByDefault)
        #expect(LooprNotificationRuntime.listedFamilies.contains(.recoveryReadiness))
    }
    @Test func incompleteMissingOldAndUnsyncedNightsDoNotSend() {
        #expect(request(partial: true) == nil)
        #expect(request(summary(score: nil)) == nil)
        #expect(request(summary(headline: nil)) == nil)
        #expect(request(synced: now.addingTimeInterval(-3_600)) == nil)
        #expect(LooprMorningRecapRequest.make(summary: summary(), sleep: nil, target: StrainTarget(recovery: 48),
            syncedAt: now, now: now, calendar: calendar) == nil)
        #expect(LooprMorningRecapRequest.make(summary: summary(), sleep: sleep(), target: StrainTarget(recovery: 48),
            syncedAt: now, now: now.addingTimeInterval(86_400), calendar: calendar) == nil)
    }
    @Test func repeatedSyncAndRelaunchStillScheduleOnceAndQuietHoursDefer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = MorningSchedulingSpy()
        let claimsURL = directory.appendingPathComponent("claims.json")
        let r = try #require(request())
        let policy = NotificationPolicy(client: spy, claims: NotificationClaimLedger(persistenceURL: claimsURL),
            calendar: calendar, now: { @Sendable [r] in r.fireDate })
        await policy.setAuthorization(.authorized)
        try await policy.setEnabled(true, for: .recoveryReadiness)
        await policy.setQuietHours(.standard)
        #expect(try await policy.schedule(r) == .deferred)
        #expect(try await policy.schedule(r) == .duplicate)
        let reopened = NotificationPolicy(client: spy, claims: NotificationClaimLedger(persistenceURL: claimsURL),
            calendar: calendar, now: { @Sendable [r] in r.fireDate })
        await reopened.setAuthorization(.authorized)
        try await reopened.setEnabled(true, for: .recoveryReadiness)
        #expect(try await reopened.schedule(r) == .duplicate)
        #expect(await spy.count() == 1)
    }
}
