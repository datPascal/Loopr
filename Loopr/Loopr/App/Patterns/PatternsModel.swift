import AIKit
import Combine
import DomainKit
import Foundation
import JournalKit
import RoutineKit

enum PatternsSegment: String, CaseIterable, Identifiable {
    case testing, found, dismissed
    var id: String { rawValue }
    /// "Dismissed" reads as deleted, so that segment is "Hidden" (ICP R1-SEN-20).
    var title: String { self == .dismissed ? PatternsCopy.dismissedHeader : rawValue.capitalized }
}

/// State and actions behind the Patterns screen. Every change is one tap on one control, and the statistics
/// run in the engine, off the main actor.
@MainActor
final class PatternsModel: ObservableObject {
    @Published var segment = PatternsSegment.testing
    @Published private(set) var snapshot = PatternsSnapshot()
    @Published private(set) var verdicts: [UUID: PatternTestVerdict] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var message: String?
    @Published private(set) var morningOn = false
    @Published private(set) var isSearching = false
    /// The pattern whose detail sheet is open.
    @Published var selected: FoundPattern?
    /// The protocol experiment running now, read on each load. A pattern test over the same nights would mix its result
    /// with the experiment's, so the detail sheet says so before a test starts (ICP R2-OPT-14).
    @Published private(set) var runningExperiment: PatternsRunningExperiment?
    /// The active protocol's rules, so a pattern's detail names the rule it is about. The check-in's pattern line left
    /// the rule out to stay short, and points here for it (ICP R4 Q7).
    @Published private(set) var protocolRules: [ProtocolRule] = []
    /// The existing Coach preferences sheet, opened to review sharing before a briefing is switched on.
    @Published var consentModel: CoachChatViewModel?

    let engine: PatternsEngine
    private let coach: any CoachConversationRepository
    private let makeConsentModel: @MainActor () async -> CoachChatViewModel?
    private let clock: @Sendable () -> Date
    private var loadGeneration = 0

    private let readRunningExperiment: @Sendable () async -> PatternsRunningExperiment?
    private let readRules: @Sendable () async -> [ProtocolRule]

    init(engine: PatternsEngine, coach: any CoachConversationRepository,
         makeConsentModel: @escaping @MainActor () async -> CoachChatViewModel?,
         now: @escaping @Sendable () -> Date = { Date() },
         runningExperiment: @escaping @Sendable () async -> PatternsRunningExperiment? = { nil },
         rules: @escaping @Sendable () async -> [ProtocolRule] = { [] }) {
        self.engine = engine; self.coach = coach; self.makeConsentModel = makeConsentModel; clock = now
        readRunningExperiment = runningExperiment
        readRules = rules
    }

    /// "Your rule: Kitchen closes." for a pattern about a rule on the person's list. Nil when none matches.
    func ruleLine(for pattern: FoundPattern) -> String? {
        ProtocolPatternFinding.make(pattern)?.naming(rules: protocolRules).ruleLine
    }

    var timeZone: TimeZone { .current }
    var hasRunningTest: Bool { !snapshot.running.isEmpty }

    /// Why a new test cannot start now and the day it can, naming what runs: one experiment at a time across Patterns
    /// and the protocol (ICP R1-VET-10, R2-SEN-12). Nil when nothing runs.
    var blockingReason: String? {
        if let test = snapshot.running.first { return PatternsCopy.startsAfter(test) }
        if let experiment = runningExperiment { return PatternsCopy.startsAfter(experiment) }
        return nil
    }

    /// The model's clock. Fixture launches pin it, so a running test shows the same day on any date.
    var now: Date { clock() }

    func progress(of test: PatternTest) -> PatternTestProgress { test.progress(at: clock()) }

    // MARK: Loading

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            _ = try? await engine.ensureWeeklyReview()
            let value = try await engine.snapshot()
            let preferences = (try? await coach.preferences()) ?? CoachPreferences()
            let experiment = await readRunningExperiment()
            let rules = await readRules()
            guard generation == loadGeneration else { return }
            snapshot = value
            runningExperiment = experiment
            protocolRules = rules
            morningOn = preferences.morningEnabled && preferences.morningConsentAt != nil
            isLoading = false
            message = nil
            for test in value.tests where test.state != .stopped {
                if let verdict = await engine.verdict(for: test) {
                    guard generation == loadGeneration else { return }
                    verdicts[test.id] = verdict
                }
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            message = "Patterns could not load. Try again in a moment."
        }
    }

    private func reload() async { await load() }

    // MARK: Tests

    func start(_ pattern: FoundPattern) async {
        do {
            let minute = snapshot.settings.defaultReminderMinuteOfDay
            try await engine.startTest(candidateID: pattern.candidateID, metric: pattern.metric.rawValue, reminderMinuteOfDay: minute)
            selected = nil; segment = .testing
            await reload()
        } catch { message = error.localizedDescription }
    }

    func keepToday(_ test: PatternTest) async {
        do { try await engine.keepToday(testID: test.id); await reload() }
        catch { message = error.localizedDescription }
    }

    func stop(_ test: PatternTest) async {
        do { try await engine.stopTest(id: test.id); await reload() }
        catch { message = error.localizedDescription }
    }

    // MARK: Found and dismissed

    func dismiss(_ pattern: FoundPattern) async {
        do { try await engine.dismiss(key: pattern.key); selected = nil; await reload() }
        catch { message = error.localizedDescription }
    }

    func restore(key: String) async {
        do { try await engine.restore(key: key); await reload() }
        catch { message = error.localizedDescription }
    }

    // MARK: Settings

    func setDiscovery(_ on: Bool) async {
        var settings = snapshot.settings
        settings.lookForNewPatterns = on
        snapshot.settings = settings
        do {
            try await engine.setLookForNewPatterns(on)
            if on {
                isSearching = true
                defer { isSearching = false }
                _ = try await engine.discover(force: false)
            }
            await reload()
        } catch {
            message = "Loopr could not change that setting."
            await reload()
        }
    }

    /// Off drops consent, as the Coach preferences screen does. On opens that screen at its sharing review.
    func setMorning(_ on: Bool) async {
        if on {
            let preferences = (try? await coach.preferences()) ?? CoachPreferences()
            if preferences.morningConsentAt != nil, preferences.morningConfiguration != nil {
                var latest = preferences; latest.morningEnabled = true
                do { try await coach.savePreferences(latest); morningOn = true; await CoachBriefingRuntime.shared.schedule() }
                catch { message = "Loopr could not change that setting." }
                return
            }
            morningOn = false
            consentModel = await makeConsentModel()
            if consentModel == nil { message = "Morning briefings are not available right now." }
        } else {
            await CoachBriefingRuntime.shared.cancel()
            do {
                var latest = try await coach.preferences()
                latest.morningEnabled = false; latest.morningConsentAt = nil
                try await coach.savePreferences(latest)
                morningOn = false
            } catch { message = "Loopr could not change that setting." }
        }
    }

    /// The Coach preferences sheet closed. Read what it saved.
    func consentClosed() async {
        consentModel = nil
        let preferences = (try? await coach.preferences()) ?? CoachPreferences()
        morningOn = preferences.morningEnabled && preferences.morningConsentAt != nil
    }
}

/// A protocol experiment that is running, as the Patterns sheet names it.
nonisolated struct PatternsRunningExperiment: Equatable, Sendable {
    let title: String
    /// "deep sleep".
    let outcome: String
    /// Tonight's night of the plan, nil outside it.
    var night: Int?
    var plannedNights: Int?
    /// "You can start this after the magnesium test ends on 20 Nov." Nil when the start is not known.
    var startsAfter: String?

    init(title: String, outcome: String, night: Int? = nil, plannedNights: Int? = nil, startsAfter: String? = nil) {
        self.title = title; self.outcome = outcome; self.night = night; self.plannedNights = plannedNights
        self.startsAfter = startsAfter
    }

    /// - Parameter today: the day tonight's night starts on, for "night 9 of 14". Nil leaves the night out.
    init(_ experiment: Experiment, today: DayIdentity? = nil) {
        let name = experiment.start.outcome.title
        // "Deep sleep" reads "deep sleep" mid-sentence; "HRV" stays "HRV".
        let lowered = name.count > 1 && name.dropFirst().first?.isUppercase == true ? name : name.prefix(1).lowercased() + name.dropFirst()
        self.init(title: experiment.start.title, outcome: lowered,
                  night: today.flatMap { experiment.schedule.nightNumber(on: $0) }, plannedNights: experiment.start.plannedNights,
                  startsAfter: ExperimentCopy.startsAfter(experiment.start))
    }

    /// The day `now` falls on in `timeZone`, the day an experiment's night is counted from.
    static func day(_ now: Date, timeZone: TimeZone) -> DayIdentity {
        ProtocolWeekCalendar(timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX")).day(now)
    }

    /// "Night 9 of 14", or nil outside the plan.
    var nightLine: String? {
        guard let night, let plannedNights else { return nil }
        return "Night \(night) of \(plannedNights)"
    }

    /// The Testing tab's line for a protocol experiment, which runs under Protocol rather than here (ICP R3-OPT-8).
    var testingLine: String {
        "This experiment runs from your protocol and tracks \(outcome). Its nights and result are under Protocol, Experiments. "
            + "Loopr runs one experiment at a time, so a new test waits until this one ends."
    }

    /// "Magnesium glycinate, 300 mg is running on deep sleep. A pattern test on the same nights mixes the two results."
    var warning: String {
        "\(title) is running on \(outcome). A pattern test on the same nights mixes the two results."
    }
}
