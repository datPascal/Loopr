#if DEBUG
import AIKit
import DomainKit
import FoodKit
import Foundation
import JournalKit

/// DEBUG launch fixture for the Patterns screen, read with `--loopr-patterns-fixture`. Alex lives in
/// Australia/Perth. Nothing here touches a real store or the network.
///
/// What it holds, all relative to the moment the screen opens:
/// - a running test, "Kitchen closed at 20:30", on day 6 of 14, kept on 5 of 6 nights (day 3 missed, today kept),
///   deep sleep 66 min on kept nights against 54 min before, reminder at 20:15. Only when the launch's protocol runs
///   no experiment (`--loopr-protocol-fixture=empty`), because one experiment runs at a time; beside the populated
///   protocol the found patterns lead with the late-dinner one, as `found` does.
/// - three found patterns: alcohol and HRV (strong, 23 nights), leg day and resting heart rate (clear, 11 nights),
///   steps over 10,000 and sleep duration (clear, 29 nights). No pattern cites more nights than the populated fixture
///   holds: Today's sleep history and the Data tab cover 29 nights (ICP R3-OPT-4).
/// - one dismissed pattern: protein target and recovery
///   (`--loopr-patterns-fixture=found` leaves out the running test and leads with a late-dinner pattern, for Today's card)
/// - a weekly review dated Sun 11 Oct
/// - Morning briefing on with consent saved, and Look for new patterns on
///
/// Identifiers W7 and the UI tests rely on: `patterns-screen`, `patterns-segments` (buttons
/// `patterns-segments-testing|found|dismissed`), `patterns-test-card`, `patterns-found-list`,
/// `patterns-found-row-0...2`, `patterns-weekly-review`, `patterns-settings-card`, `patterns-morning-toggle`,
/// `patterns-discovery-toggle`, `patterns-detail-dismiss`, `patterns-dismissed-row-0`, `patterns-restore-0`.
@MainActor
enum PatternsFixtures {
    static let flag = "--loopr-patterns-fixture"
    /// `--loopr-patterns-fixture=found` is the same data without the running test, so Today's card can show
    /// both of its buttons and a test can start one.
    static let foundOnlyFlag = "--loopr-patterns-fixture=found"
    nonisolated static let zone = TimeZone(identifier: "Australia/Perth")!
    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(flag) || arguments.contains(foundOnlyFlag)
    }
    /// Fri 16 Oct 2026, 12:00 in Perth. The fixture reads this clock and not the real one, so "Day 6 of 14" and the review
    /// dated Sun 11 Oct stay true on any day the tests run.
    nonisolated static let fixedNow = ISO8601DateFormatter().date(from: "2026-10-16T04:00:00Z") ?? Date(timeIntervalSince1970: 1_792_123_200)
    /// The running test appears only when nothing else runs: the populated protocol fixture runs magnesium, and Loopr
    /// runs one experiment at a time (ICP R1-VET-10). Launch with `--loopr-protocol-fixture=empty` to see the test.
    static var runsTest: Bool { runsTest(arguments: ProcessInfo.processInfo.arguments) }

    static func runsTest(arguments: [String]) -> Bool {
        guard !arguments.contains(foundOnlyFlag) else { return false }
        let protocolRunsExperiment = LaunchModeParser.parse(arguments: arguments, environment: [:]) == .populated
            && !ProtocolTabFixture.startsEmpty(arguments)
        return !protocolRunsExperiment
    }
    /// The lead pattern's nights: the late dinners and the other nights of Today's 29-night sleep history.
    nonisolated static let leadNights = (with: 9, without: 20)

    private static var sharedParts: Parts?

    /// One fixture for the whole launch, so Today and the Patterns screen read and change the same data.
    static func shared() async -> Parts {
        if let sharedParts { return sharedParts }
        let created = isRequested ? await make() : empty()
        sharedParts = created
        return created
    }

    struct Parts {
        let engine: PatternsEngine
        let coach: any CoachConversationRepository
        let makeConsentModel: @MainActor () async -> CoachChatViewModel?
    }

    /// An empty store, for a fixture launch that did not ask for the data above.
    static func empty(now: Date = fixedNow) -> Parts {
        parts(store: InMemoryPatternStore(), coach: CoachFixtureRepository(), now: now)
    }

    /// - Parameter runsTest: nil reads the launch arguments (`runsTest`).
    static func make(now: Date = fixedNow, runsTest requested: Bool? = nil) async -> Parts {
        let runsTest = requested ?? Self.runsTest
        let store = InMemoryPatternStore()
        let today = PatternDays.key(at: now, timeZoneID: zone.identifier) ?? "2026-10-15"
        let start = PatternDays.add(-5, to: today) ?? today
        let keptKeys = [0, 1, 3, 4, 5].compactMap { PatternDays.add($0, to: start) }
        let kept = keptKeys.map { PatternKeptDay(dayKey: $0, recordedAt: PatternDays.endOfDay($0, timeZoneID: zone.identifier)?.addingTimeInterval(-3600) ?? now) }
        let test = PatternTest(
            id: UUID(uuidString: "FEEDFACE-0000-4000-8000-000000000001")!,
            candidateID: LooprPatternExposureProvider.lateDinner.id, habitID: FoodAssociationKind.lateMeal.id, title: "Kitchen closed at 20:30",
            predicate: .food(label: "a kitchen closed at 20:30"), outcomeMetric: .deepSleepMinutes, startDay: start,
            timeZoneID: zone.identifier, reminder: PatternReminder(enabled: true, minuteOfDay: 20 * 60 + 15),
            keptDays: kept, createdAt: PatternDays.endOfDay(PatternDays.add(-1, to: start) ?? start, timeZoneID: zone.identifier) ?? now)
        if runsTest { await store.saveTest(test) }

        func found(_ id: String, _ habit: String, _ title: String, _ predicate: PatternPredicate, _ metric: HabitOutcomeMetricID,
                   _ strength: PatternStrength, _ difference: Double, _ threshold: Double, with: Int, without: Int,
                   spread: Double? = nil) -> FoundPattern {
            FoundPattern(
                candidateID: id, habitID: HabitID(rawValue: UUID(uuidString: habit)!), title: title, predicate: predicate, metric: metric,
                strength: strength,
                effect: PatternEffect(adjustedDifference: difference, rawDifference: difference, withMean: nil, withoutMean: nil,
                                      intervalLower: difference - threshold / 2, intervalUpper: difference + threshold / 2, pValue: 0.004,
                                      practicalThreshold: threshold, unit: metric.unit, spread: spread),
                nights: PatternNights(with: with, without: without), windowEnd: today,
                algorithmVersion: PatternPolicy.default.algorithmVersion, foundAt: now)
        }
        let patterns = [
            found("journal.00000000-0000-0000-0000-000000005001", "00000000-0000-0000-0000-000000005001", "Alcohol",
                  .journalAnswer(name: "Alcohol"), .hrvRMSSD, .strong, -8, 3, with: 9, without: 14, spread: 11),
            found("legDay", "FC200000-0000-4000-8000-000000000002", "Leg day", .legDay, .restingHeartRate, .clear, 3, 2, with: 4, without: 7),
            found("steps10k", "FC200000-0000-4000-8000-000000000003", "Over 10,000 steps", .stepsOver(10_000), .sleepDuration, .clear, 24, 20,
                  with: 12, without: 17),
        ]
        let protein = found("food.proteinTarget", "FC100000-0000-4000-8000-000000000002", "Protein target met",
                            .food(label: "a day you met your protein target"), .recoveryScore, .clear, 4, 3, with: 8, without: 11)
        // Without the running test the fixture leads with the pattern a test can start from: eating after 21:00 and deep
        // sleep averaging 52 min on 9 nights against 71 min on the other 20. These are the 29 nights Today's morning note
        // reads, split the same way (9 late dinners, 20 with 4 h or more before bed). This is the one Today's card shows.
        let leadMetric = HabitOutcomeMetricID.deepSleepMinutes
        let lead = runsTest ? [] : [FoundPattern(
            candidateID: LooprPatternExposureProvider.lateDinner.id, habitID: FoodAssociationKind.lateMeal.id, title: "Last meal after 21:00",
            predicate: .food(label: "when you eat after 21:00"), metric: leadMetric, strength: .strong,
            effect: PatternEffect(adjustedDifference: -19, rawDifference: -19, withMean: 52, withoutMean: 71, intervalLower: -22, intervalUpper: -16,
                                  pValue: 0.004, practicalThreshold: 6, unit: leadMetric.unit, spread: 12),
            nights: PatternNights(with: leadNights.with, without: leadNights.without), windowEnd: today,
            algorithmVersion: PatternPolicy.default.algorithmVersion, foundAt: now)]
        await store.replaceFoundPatterns(lead + patterns + [protein])
        await store.dismiss(protein, at: now.addingTimeInterval(-3 * 86_400))
        await store.saveReview(WeeklyReview(
            weekStartDay: "2026-10-05", weekEndDay: "2026-10-11",
            text: "Recovery averaged 71, up 5. You hit protein on 4 of 7 days and trained 4 times. This week, aim for bed before 23:00 on training nights.",
            patternKeys: [], generatedAt: now))
        await store.saveSettings(PatternSettings(lookForNewPatterns: true, lastDiscoveryDay: today, lastDiscoveryAt: now))

        let coach = CoachFixtureRepository()
        var preferences = CoachPreferences()
        preferences.morningEnabled = true
        preferences.morningConsentAt = now.addingTimeInterval(-86_400)
        preferences.morningConfiguration = CoachProviderConfiguration(provider: .openAI, model: CoachProvider.openAI.defaultModel)
        await coach.savePreferences(preferences)
        return parts(store: store, coach: coach, now: now)
    }

    private static func parts(store: InMemoryPatternStore, coach: CoachFixtureRepository, now: Date) -> Parts {
        let engine = PatternsEngine(store: store, provider: FixturePatternProvider(), reminders: NoPatternReminders(),
                                    now: { now }, timeZone: { zone })
        return Parts(engine: engine, coach: coach, makeConsentModel: {
            guard let model = try? await CoachUITestFixtures.model(origin: nil, repository: coach) else { return nil }
            await model.load()
            return model
        })
    }
}

/// Supplies outcomes for the fixture test: 54 min of deep sleep before, 66 min on kept nights. The wobble
/// sums to zero on each side, so the means are exact.
nonisolated struct FixturePatternProvider: PatternExposureProvider {
    func candidates() async throws -> [PatternCandidate] {
        PatternCandidate.catalog(journalHabits: [], food: [LooprPatternExposureProvider.lateDinner, LooprPatternExposureProvider.protein])
    }
    func exposures(endingOn day: String, windowDays: Int) async throws -> [PatternExposureSeries] { [] }

    func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet {
        var yes = 0, no = 0
        let keptWobble: [Double] = [-2, 2, 0, -1, 1]
        var outcomes: [HabitOutcomeSnapshot] = []
        for record in records.sorted(by: { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }) {
            guard let answer = record.responses.first?.answer, answer != .skipped,
                  let next = PatternDays.add(1, to: record.behaviorDay.habitKey).flatMap(DayIdentity.init(habitKey:)) else { continue }
            let deep: Double
            if answer == .yes { deep = 66 + keptWobble[yes % keptWobble.count]; yes += 1 }
            else { deep = 54 + (no.isMultiple(of: 2) ? 2 : -2); no += 1 }
            outcomes.append(HabitOutcomeSnapshot(
                behaviorDay: record.behaviorDay, behaviorTimeZoneID: record.behaviorTimeZoneID, sleepSessionID: "fixture-\(record.behaviorDay.habitKey)",
                outcomeDay: next, metrics: [.deepSleepMinutes: deep, .sleepScore: 70 + deep / 10], priorDayStrain: nil,
                sourceVersions: ["fixture": "1"], builtAt: Date(timeIntervalSince1970: 0)))
        }
        return PatternOutcomeSet(outcomes: outcomes)
    }
}
#endif
