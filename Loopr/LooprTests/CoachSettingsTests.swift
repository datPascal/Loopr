import AIKit
import Foundation
import NotificationKit
import Testing

@testable import Loopr

private actor ThrowingCredentials: AICredentialStore {
    var failWrite = true
    var value: Data?
    func write(_ value: Data) throws {
        if failWrite { throw NSError(domain: NSOSStatusErrorDomain, code: -34018) }
        self.value = value
    }
    func read() throws -> Data? { value }
    func remove() throws { value = nil }
    func allowWrites() { failWrite = false }
}

struct CoachSettingsTests {
    private func runtime(_ store: ThrowingCredentials) throws -> (LooprAISettingsRuntime, UserDefaults, String) {
        let suite = "CoachSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: store, .anthropic: ThrowingCredentials()]), defaults, suite)
    }

    @Test func keychainWriteFailureIsReadableAndSavesNothing() async throws {
        let store = ThrowingCredentials()
        let (runtime, defaults, suite) = try runtime(store)
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            try await runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "sk-fixture")
            Issue.record("configure should throw")
        } catch let error as CoachSettingsError {
            #expect(error == .keychainWrite)
            let text = CoachSettingsCopy.message(for: error)
            #expect(!text.contains("OSStatus"))
            #expect(text.contains("Keychain"))
        }
        #expect(try await runtime.configurations().isEmpty)
    }

    @Test func rawOSStatusNeverReachesTheScreen() {
        let raw = NSError(domain: NSOSStatusErrorDomain, code: -34018)
        let text = CoachSettingsCopy.message(for: raw)
        #expect(!text.contains("34018"))
        #expect(CoachSettingsCopy.message(for: CoachProviderError.invalidKey, provider: .anthropic).contains("Claude"))
        #expect(CoachSettingsCopy.message(for: CancellationError()) == CoachSettingsCopy.genericFailure)
    }

    @Test func blankKeyWithNothingSavedStillThrowsMissingKey() async throws {
        let store = ThrowingCredentials()
        await store.allowWrites()
        let (runtime, defaults, suite) = try runtime(store)
        defer { defaults.removePersistentDomain(forName: suite) }
        await #expect(throws: CoachProviderError.missingKey) {
            try await runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "  ")
        }
    }

    @Test func hourLabelsFollowTheLocale() {
        let calendar = Calendar(identifier: .gregorian)
        let us = CoachSettingsCopy.hourLabel(7, locale: Locale(identifier: "en_US"), calendar: calendar)
        let de = CoachSettingsCopy.hourLabel(7, locale: Locale(identifier: "en_GB"), calendar: calendar)
        #expect(us.contains("7") && us.uppercased().contains("AM"))
        #expect(de.contains("7") && !de.uppercased().contains("AM") && !de.uppercased().contains("PM"), "got \(de) and \(us)")
    }

    @Test func lastBriefingDayReadsAsADate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-09T10:00:00Z")!
        let locale = Locale(identifier: "en_US")
        #expect(CoachSettingsCopy.dayText("2026-10-09", now: now, locale: locale, calendar: calendar) == "Today")
        #expect(CoachSettingsCopy.dayText("2026-10-08", now: now, locale: locale, calendar: calendar) == "Yesterday")
        #expect(CoachSettingsCopy.dayText("2026-10-01", now: now, locale: locale, calendar: calendar).contains("Oct"))
        #expect(CoachSettingsCopy.dayText("not a day", now: now, locale: locale, calendar: calendar) == "not a day")
    }

    @Test func briefingNotificationCarriesItsChatID() {
        let id = UUID()
        #expect(ShellDeepLink(notification: .coach(id.uuidString)) == .coachChat(id))
        #expect(ShellDeepLink(notification: .coach("briefing")) == .coach)
    }
}
