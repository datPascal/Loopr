import AIKit
import DomainKit
import FoodKit
import Foundation
import JournalKit
import StorageKit
import Testing
@testable import Loopr

private typealias F = PatternsFixtures4b

/// The app side of Patterns: what the exposures mean, where the statistics run, how a test starts, and what the
/// weekly review may say. Perth, Alex, and no network.
@Suite(.serialized)
struct PatternsRuntimeTests {
    // MARK: Exposure rules

    @Test func aLegSessionNeedsMostOfItsSetsOnTheLowerBody() {
        #expect(PatternExposureRules.isLegSession(setsByExercise: [(["quadriceps"], 4), (["glutes", "hamstrings"], 3), (["chest"], 2)]))
        #expect(!PatternExposureRules.isLegSession(setsByExercise: [(["chest"], 4), (["quadriceps"], 3), (["lats"], 3)]), "3 of 10 sets")
        #expect(!PatternExposureRules.isLegSession(setsByExercise: [(["calves"], 2)]), "under three sets")
        #expect(PatternExposureRules.isLegSession(setsByExercise: [(["quadriceps"], 3), (["biceps"], 3)]), "exactly half counts")
    }

    @Test func trainingAnswersStartAtTheFirstRecordedDayAndNeverBefore() {
        var input = PatternTrainingInput()
        input.earliestDay = "2026-10-10"; input.trainedDays = ["2026-10-10", "2026-10-13"]; input.legDays = ["2026-10-13"]
        let training = PatternExposureRules.trainingDays(input, from: "2026-10-01", to: "2026-10-14", zoneID: F.zoneID, leg: false)
        #expect(training.map(\.dayKey) == ["2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14"])
        #expect(training.map(\.exposed) == [true, false, false, true, false])
        let leg = PatternExposureRules.trainingDays(input, from: "2026-10-01", to: "2026-10-14", zoneID: F.zoneID, leg: true)
        #expect(leg.filter(\.exposed).map(\.dayKey) == ["2026-10-13"])
        #expect(PatternExposureRules.trainingDays(PatternTrainingInput(), from: "2026-10-01", to: "2026-10-14", zoneID: F.zoneID, leg: false).isEmpty,
                "no training on record means unknown, not no")
    }

    @Test func stepsAreAnsweredOnlyWhereThereIsACount() {
        let days = PatternExposureRules.stepDays(["2026-10-10": 10_001, "2026-10-11": 10_000, "2026-10-12": 4_200], over: 10_000, zoneID: F.zoneID)
        #expect(days.map(\.dayKey) == ["2026-10-10", "2026-10-11", "2026-10-12"])
        #expect(days.map(\.exposed) == [true, false, false], "over 10,000 means more than 10,000")
        #expect(PatternExposureRules.stepDays([:], over: 10_000, zoneID: F.zoneID).isEmpty)
    }

    @Test func theProviderAnswersJournalFoodTrainingAndStepsCandidates() async throws {
        let habit = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000005001")!), source: .custom,
                                    name: "Alcohol", question: "Did you have alcohol?", sortOrder: 0, createdAt: F.now)
        func record(_ day: String, _ answer: HabitAnswer) -> HabitDayRecord {
            let identity = DayIdentity(habitKey: day)!
            return HabitDayRecord(behaviorDay: identity, behaviorTimeZoneID: F.zoneID,
                responses: [HabitResponse(habitID: habit.id, behaviorDay: identity, behaviorTimeZoneID: F.zoneID, answer: answer,
                                          firstAnsweredAt: F.now, firstAnswerSource: .morningCheckIn)], completedAt: F.now, createdAt: F.now)
        }
        let box = PatternDataBox()
        box.update {
            $0.definitions = [habit]
            $0.records = [record("2026-10-10", .yes), record("2026-10-11", .no), record("2026-10-12", .skipped)]
            $0.food[.lateMeal] = [PatternExposureDay(dayKey: "2026-10-11", timeZoneID: F.zoneID, exposed: true)]
            $0.training = PatternTrainingInput(trainedDays: ["2026-10-12"], legDays: ["2026-10-12"], earliestDay: "2026-10-11")
            $0.steps = ["2026-10-12": 12_000]
        }
        let provider = LooprPatternExposureProvider(data: box, timeZone: { F.zone }, policy: F.shortPolicy)
        let candidates = try await provider.candidates()
        #expect(candidates.map(\.id) == ["journal.\(habit.id.rawValue.uuidString)", "food.lateMeal", "food.proteinTarget", "food.alcohol", "food.lateCaffeine",
                                         "training", "legDay", "steps10k"], "a custom Alcohol question does not replace the food answer")
        let series = Dictionary(uniqueKeysWithValues: try await provider.exposures(endingOn: "2026-10-16", windowDays: 120).map { ($0.candidateID, $0.days) })
        #expect(series["journal.\(habit.id.rawValue.uuidString)"]?.map(\.exposed) == [true, false], "a skipped answer is unknown")
        #expect(series["food.lateMeal"]?.map(\.dayKey) == ["2026-10-11"])
        #expect(series["training"]?.first(where: { $0.dayKey == "2026-10-12" })?.exposed == true)
        #expect(series["training"]?.first?.dayKey == "2026-10-11")
        #expect(series["legDay"]?.filter(\.exposed).count == 1)
        #expect(series["steps10k"]?.map(\.exposed) == [true])
    }

    @Test func aJournalQuestionThatJournalFillsFromFoodReplacesTheMatchingFoodCandidate() async throws {
        func preset(_ id: String, archived: Bool = false) -> HabitDefinition {
            HabitDefinition(id: HabitID(rawValue: UUID()), source: .preset(catalogID: id), name: HabitCatalog.byID[id]!.name,
                            question: HabitCatalog.byID[id]!.question, sortOrder: 0, archivedAt: archived ? F.now : nil, createdAt: F.now)
        }
        let food = { (habits: [HabitDefinition]) in LooprPatternExposureProvider.foodCandidates(journalHabits: habits).map(\.1.id) }
        #expect(food([]) == ["food.lateMeal", "food.proteinTarget", "food.alcohol", "food.lateCaffeine"])
        #expect(food([preset("alcohol")]) == ["food.lateMeal", "food.proteinTarget", "food.lateCaffeine"])
        #expect(food([preset("alcohol"), preset("late_caffeine")]) == ["food.lateMeal", "food.proteinTarget"])
        #expect(food([preset("alcohol", archived: true)]).contains("food.alcohol"), "an archived question no longer answers")

        let box = PatternDataBox()
        box.update {
            $0.definitions = [preset("alcohol")]
            $0.food[.alcohol] = [PatternExposureDay(dayKey: "2026-10-11", timeZoneID: F.zoneID, exposed: true)]
        }
        let series = try await LooprPatternExposureProvider(data: box, timeZone: { F.zone }, policy: F.shortPolicy)
            .exposures(endingOn: "2026-10-16", windowDays: 120).map(\.candidateID)
        #expect(!series.contains("food.alcohol") && series.contains("food.lateCaffeine"))
    }

    // MARK: Discovery

    @Test func discoveryFindsTheLateDinnerPatternAndRunsOffTheMainActor() async throws {
        let box = F.lateDinnerData()
        let store = InMemoryPatternStore()
        let engine = F.engine(store: store, data: box)
        let result = try #require(try await engine.discover(force: true))

        let found = try #require(result.patterns.first { $0.key == "food.lateMeal.sleepScore" })
        #expect(found.strength >= .clear)
        #expect(found.effect.difference < -8 && found.effect.difference > -16, "about 12 points lower, got \(found.effect.difference)")
        #expect(found.nights.with > 10 && found.nights.without > 10)
        #expect(try await store.foundPatterns().contains { $0.key == found.key })
        let reads = box.mainThreadReads
        #expect(!reads.isEmpty && reads.allSatisfy { !$0 }, "provider reads ran on the main thread")
        #expect(PatternsCopy.headline(found, locale: Locale(identifier: "en_GB")).hasPrefix("Sleep score is") && PatternsCopy.headline(found, locale: Locale(identifier: "en_GB")).contains("lower when you eat after 21:00"))
    }

    @Test func discoveryOnlyRunsWhenTheSettingIsOnAndAWeekHasPassed() async throws {
        let box = F.lateDinnerData()
        let store = InMemoryPatternStore()
        let engine = F.engine(store: store, data: box)
        #expect(try await engine.discover() == nil, "off by default")
        #expect(box.mainThreadReads.isEmpty, "nothing was read while the setting was off")

        try await engine.setLookForNewPatterns(true)
        #expect(try await engine.discover() != nil)
        #expect(try await engine.discover() == nil, "once a week")
        var settings = try await store.settings()
        #expect(settings.lastDiscoveryDay == F.today)
        settings.lastDiscoveryDay = "2026-10-09"
        try await store.saveSettings(settings)
        #expect(try await engine.discover() != nil, "seven days later it runs again")
    }

    // MARK: Tests

    /// ICP R1-VET-10: a protocol experiment and a pattern test never run on the same nights. The engine refuses, says
    /// which one runs, and Ask's starter gets no title to offer.
    @Test func aTestDoesNotStartWhileAProtocolExperimentRuns() async throws {
        let store = InMemoryPatternStore()
        let engine = PatternsEngine(store: store, provider: LooprPatternExposureProvider(data: F.lateDinnerData(), timeZone: { F.zone },
                                                                                        policy: F.shortPolicy),
                                    policy: F.shortPolicy, now: { F.now }, timeZone: { F.zone },
                                    runningExperiment: { "Magnesium glycinate, 300 mg" })
        await #expect(throws: PatternsEngineError.experimentRunning("Magnesium glycinate, 300 mg")) {
            try await engine.startTest(candidateID: "food.lateMeal", metric: "deepSleepMinutes", reminderMinuteOfDay: nil)
        }
        #expect(try await store.tests().isEmpty)
        #expect(await engine.testTitle(candidateID: "food.lateMeal", metric: "deepSleepMinutes") == nil)
        #expect(PatternsEngineError.experimentRunning("Magnesium glycinate, 300 mg").errorDescription
            == "Magnesium glycinate, 300 mg is still running. Loopr runs one test at a time, so two results never mix.")
    }

    /// ICP R1-VET-13, R1-SEN-20: counts instead of "Strong", and Not now in place of Dismiss.
    @MainActor
    @Test func patternWordsUseCountsAndSayWhatNotNowDoes() {
        #expect(PatternsCopy.caption(F.alcohol) == "9 nights with, 14 without")
        #expect(PatternsCopy.dismiss == "Not now" && PatternsCopy.dismissNote.contains("Hidden"))
        #expect(PatternsSegment.dismissed.title == "Hidden" && PatternsSegment.found.title == "Found")
        #expect(PatternsCopy.threshold(F.alcohol) == "Loopr lists a gap only when it is 3 ms or more.")
        #expect(PatternsCopy.likelyRange(F.alcohol) == nil, "no interval, no range")
        #expect(PatternsCopy.usualSpread(F.alcohol) == nil, "a pattern stored without a spread shows no spread line")
        #expect(PatternsFixtures.runsTest(arguments: ["--loopr-launch-mode=populated"]) == false,
                "beside the populated protocol's magnesium experiment the fixture runs no pattern test")
        #expect(PatternsFixtures.runsTest(arguments: ["--loopr-launch-mode=populated", "--loopr-protocol-fixture=empty"]))
        #expect(!PatternsFixtures.runsTest(arguments: ["--loopr-patterns-fixture=found", "--loopr-protocol-fixture=empty"]))
    }

    @Test func startingATestIsIdempotentAndOnlyOneRunsAtATime() async throws {
        let store = InMemoryPatternStore()
        let reminders = SpyPatternReminders()
        let engine = F.engine(store: store, data: F.lateDinnerData(), reminders: reminders)
        let first = try await engine.startTest(candidateID: "food.lateMeal", metric: "deepSleepMinutes", reminderMinuteOfDay: 20 * 60 + 15)
        #expect(first.startDay == F.today && first.timeZoneID == F.zoneID && first.outcomeMetric == .deepSleepMinutes)
        #expect(first.reminder?.minuteOfDay == 20 * 60 + 15 && reminders.scheduled == [first.id])

        let again = try await engine.startTest(candidateID: "food.lateMeal", metric: "deepSleepMinutes", reminderMinuteOfDay: 20 * 60 + 15)
        #expect(again.id == first.id)
        #expect(try await store.tests().count == 1 && reminders.scheduled.count == 1)

        await #expect(throws: PatternsEngineError.anotherTestRunning) {
            try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: nil)
        }
        await #expect(throws: PatternsEngineError.notAvailable) {
            try await engine.startTest(candidateID: "steps.unknown", metric: nil, reminderMinuteOfDay: nil)
        }
        await #expect(throws: PatternsEngineError.notAvailable) {
            try await engine.startTest(candidateID: "food.lateMeal", metric: "mood", reminderMinuteOfDay: nil)
        }
        #expect(await engine.testTitle(candidateID: "training", metric: nil) == nil, "another test is running")
        #expect(await engine.testTitle(candidateID: "food.lateMeal", metric: "sleepScore") == "Last meal after 21:00")
    }

    @Test func aDeniedReminderStillStartsTheTestWithoutOne() async throws {
        let reminders = SpyPatternReminders(); reminders.allow = false
        let engine = F.engine(data: F.lateDinnerData(), reminders: reminders)
        let test = try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: 20 * 60)
        #expect(test.reminder == nil && test.state == .running)
    }

    @Test func keepingTodayCountsOnceAndStoppingCancelsReminders() async throws {
        let store = InMemoryPatternStore()
        let reminders = SpyPatternReminders()
        let engine = F.engine(store: store, data: F.lateDinnerData(), reminders: reminders)
        let test = try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: 20 * 60)
        try await engine.keepToday(testID: test.id)
        let kept = try await engine.keepToday(testID: test.id)
        #expect(kept.keptDayKeys == [F.today])
        let progress = kept.progress(at: F.now)
        #expect(progress.dayNumber == 1 && progress.keptCount == 1 && progress.elapsedDays == 1)

        try await engine.stopTest(id: test.id)
        #expect(try await store.test(id: test.id)?.state == .stopped)
        #expect(reminders.cancelled == [test.id])
        #expect(try await engine.snapshot().tests.isEmpty, "a stopped test leaves the list")
    }

    @MainActor
    @Test func theFixtureTestShowsDay6Of14WithFiveKeptAndSixtySixAgainstFiftyFour() async throws {
        let parts = await PatternsFixtures.make(now: F.now)
        let snapshot = try await parts.engine.snapshot()
        let test = try #require(snapshot.running.first)
        let progress = test.progress(at: F.now)
        #expect(test.title == "Kitchen closed at 20:30")
        #expect(progress.dayNumber == 6 && progress.elapsedDays == 6 && progress.keptCount == 5 && progress.totalDays == 14)
        #expect(PatternsCopy.dayChip(progress, test: test) == "Day 6 of 14")

        let verdict = try #require(await parts.engine.verdict(for: test))
        #expect(verdict.nowMean == 66 && verdict.beforeMean == 54, "now \(String(describing: verdict.nowMean)), before \(String(describing: verdict.beforeMean))")
        #expect(!verdict.isConclusive && verdict.headline == "Too early to tell")
        #expect(PatternsCopy.status(test: test, progress: progress, verdict: verdict, locale: Locale(identifier: "en_GB")) == "Kept on 5 of 6 nights. Too early to tell. A reminder comes at 20:15.")

        #expect(snapshot.found.count == 3 && snapshot.dismissed.count == 1)
        #expect(snapshot.found.map(\.strength) == [.strong, .clear, .clear])
        #expect(snapshot.review.map(PatternsCopy.reviewDate) == "Sun 11 Oct")
        #expect(snapshot.settings.lookForNewPatterns)
        let preferences = try await parts.coach.preferences()
        #expect(preferences.morningEnabled && preferences.morningConsentAt != nil)
    }

    // MARK: Weekly review

    @Test func theReviewWeekIsTheMondayToSundayThatEndedOnTheLatestSunday() throws {
        func week(_ iso: String) throws -> String {
            let found = try #require(PatternsEngine.reviewWeek(now: ISO8601DateFormatter().date(from: iso)!, timeZone: F.zone))
            return "\(found.start) to \(found.end)"
        }
        // Sun 11 Oct, midday in Perth: the week ending today.
        #expect(try week("2026-10-11T04:00:00Z") == "2026-10-05 to 2026-10-11")
        // Mon 12 Oct and Fri 16 Oct: the week that ended on Sun 11 Oct.
        #expect(try week("2026-10-12T04:00:00Z") == "2026-10-05 to 2026-10-11")
        #expect(try week("2026-10-16T04:00:00Z") == "2026-10-05 to 2026-10-11")
        // Sat 10 Oct: the week before.
        #expect(try week("2026-10-10T04:00:00Z") == "2026-09-28 to 2026-10-04")
        // Perth is ahead of UTC: Sun 11 Oct 07:00 in Perth is still Sat 10 Oct in UTC.
        #expect(try week("2026-10-10T23:00:00Z") == "2026-10-05 to 2026-10-11")
    }

    @Test func theLocalReviewIsWrittenOnceFromStoredPatternsAndNeverClaimsCause() async throws {
        let store = InMemoryPatternStore()
        let engine = F.engine(store: store, data: F.lateDinnerData())
        #expect(try await engine.ensureWeeklyReview() == nil, "nothing to say, so no review")
        #expect(try await store.reviews().isEmpty)

        try await store.replaceFoundPatterns([F.alcohol, F.lateDinner])
        let review = try #require(try await engine.ensureWeeklyReview())
        #expect(review.weekStartDay == "2026-10-05" && review.weekEndDay == "2026-10-11")
        #expect(review.patternKeys.count == 2)
        #expect(review.text.contains("HRV was 8 ms lower on nights after you logged alcohol"))
        #expect(review.text.hasSuffix(PatternCopy.footnote))
        for word in ["because", "caused", "causes", "due to", "leads to", "makes you"] {
            #expect(!review.text.lowercased().contains(word), "\(word)")
        }
        let again = try #require(try await engine.ensureWeeklyReview())
        #expect(again == review, "same week, same review")
        #expect(try await store.reviews().count == 1)
    }

    @Test func aDismissedPatternStaysOutOfTheReviewAndTheFoundList() async throws {
        let store = InMemoryPatternStore()
        let engine = F.engine(store: store, data: F.lateDinnerData())
        try await store.replaceFoundPatterns([F.alcohol, F.lateDinner])
        try await engine.dismiss(key: F.alcohol.key)
        let snapshot = try await engine.snapshot()
        #expect(snapshot.found.map(\.key) == [F.lateDinner.key] && snapshot.dismissed.map(\.key) == [F.alcohol.key])
        let review = try #require(try await engine.ensureWeeklyReview())
        #expect(review.patternKeys == [F.lateDinner.key] && !review.text.contains("alcohol"))
        #expect(try await engine.restore(key: F.alcohol.key)?.key == F.alcohol.key)
        #expect(try await engine.snapshot().found.count == 2)
    }

    // MARK: AgentTestStarting

    private struct Proposing {
        let engine: PatternsEngine
        let store: InMemoryPatternStore
        let center: AgentProposalCenter
        let executor: AgentToolExecutor
        let writes = SpyWriteStore()
        let root: URL
    }

    private func proposing(_ suite: AgentFixtures.Suite) throws -> Proposing {
        let store = InMemoryPatternStore()
        let engine = F.engine(store: store, data: F.lateDinnerData(), reminders: SpyPatternReminders())
        let (database, root) = try AgentFixtures.temporaryDatabase()
        let starter = PatternTestStarter(engine: engine)
        let writes = SpyWriteStore()
        let applier = AgentProposalApplier(writes: writes, reminders: SpyReminders(), tests: starter, now: { F.now }, timeZone: { F.zone })
        let center = AgentProposalCenter(ledger: AIProposalLedger(persistence: try StorageDocumentProposalPersistence(database: database)), applier: applier)
        let maker = AgentProposalMaker(writes: writes, tests: starter, provider: .anthropic, model: "claude-haiku-5-5", now: F.now, timeZone: F.zone)
        let gate = AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults)
        let executor = AgentToolExecutor(readers: AgentReaders(gate: gate, source: FakeAgentSource()), proposals: center, maker: maker,
                                         session: AgentToolSession(), conversationID: UUID(), messageID: UUID(), now: F.now, timeZone: F.zone)
        return Proposing(engine: engine, store: store, center: center, executor: executor, root: root)
    }

    private func propose(_ rig: Proposing, candidate: String = "food.lateMeal", metric: String = "deepSleepMinutes") async throws -> UUID {
        let outcome = await rig.executor.execute(AgentFixtures.call(AgentToolName.proposeTest,
            ["candidateId": candidate, "metric": metric, "reminderTime": "20:15"]))
        #expect(!outcome.isError, "\(outcome.content)")
        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.content.utf8)) as? [String: Any])
        return try #require((json["proposalId"] as? String).flatMap(UUID.init(uuidString:)))
    }

    @Test func confirmingAProposalStartsTheTestAndNothingStartsBefore() async throws {
        let suite = AgentFixtures.Suite()
        let rig = try proposing(suite); defer { try? FileManager.default.removeItem(at: rig.root) }
        let id = try await propose(rig)
        #expect(try await rig.store.tests().isEmpty, "a proposal started a test")

        #expect(await rig.center.confirm(id: id, at: F.now).applied)
        let test = try #require(try await rig.store.tests().first)
        #expect(test.state == .running && test.candidateID == "food.lateMeal" && test.outcomeMetric == .deepSleepMinutes)
        #expect(test.startDay == F.today && test.testDays == 14 && test.baselineDays == 30)
        #expect(test.reminder?.minuteOfDay == 20 * 60 + 15)
    }

    @Test func notNowWritesNothingAndAConfirmedCardCanNotBeDismissedBack() async throws {
        let suite = AgentFixtures.Suite()
        let rig = try proposing(suite); defer { try? FileManager.default.removeItem(at: rig.root) }
        let id = try await propose(rig)
        _ = await rig.center.dismiss(id: id)
        #expect(try await rig.store.tests().isEmpty && rig.writes.writeCount == 0)
        let late = await rig.center.confirm(id: id, at: F.now)
        #expect(!late.applied, "a dismissed card stays dismissed")
        #expect(try await rig.store.tests().isEmpty)
    }

    @Test func aRepeatedConfirmStartsOneTestOnly() async throws {
        let suite = AgentFixtures.Suite()
        let rig = try proposing(suite); defer { try? FileManager.default.removeItem(at: rig.root) }
        let id = try await propose(rig)
        async let a = rig.center.confirm(id: id, at: F.now)
        async let b = rig.center.confirm(id: id, at: F.now)
        _ = await (a, b)
        _ = await rig.center.confirm(id: id, at: F.now)
        #expect(try await rig.store.tests().count == 1)
        // A second card for the same pattern finds the running test and starts nothing new.
        let second = try await propose(rig)
        _ = await rig.center.confirm(id: second, at: F.now)
        #expect(try await rig.store.tests().count == 1)
    }

    @Test func aProposalForAnotherPatternIsRefusedWhileATestRuns() async throws {
        let suite = AgentFixtures.Suite()
        let rig = try proposing(suite); defer { try? FileManager.default.removeItem(at: rig.root) }
        _ = await rig.center.confirm(id: try await propose(rig), at: F.now)
        let outcome = await rig.executor.execute(AgentFixtures.call(AgentToolName.proposeTest, ["candidateId": "training"]))
        #expect(outcome.isError, "the card should not offer a second test")
    }

    // MARK: Stage gate and old data

    @MainActor
    @Test func patternsFollowTheHabitInsightsStage() {
        #expect(!LooprPatternsRuntime.isEnabled(stage: .disabled))
        #expect(LooprPatternsRuntime.isEnabled(stage: .beta) && LooprPatternsRuntime.isEnabled(stage: .public))
        #expect(!AppHabitFeatureGate.stage(infoDictionary: ["LooprHabitInsightsStage": "disabled"]).exposesEntryPoints)
        let box = AgentTestStarterBox()
        #expect(!box.isSet, "propose_test stays off until a starter is set")
    }

    @Test func conversationsAndPreferencesSavedBeforeThisChangeStillDecode() throws {
        var chat = CoachConversation(configuration: AgentFixtures.configuration(), now: F.now)
        chat.kind = .weeklyReview
        let decoded = try JSONDecoder().decode(CoachConversation.self, from: JSONEncoder().encode(chat))
        #expect(decoded.kind == .weeklyReview && decoded.isBriefing)

        // An old briefing: `isBriefing` only, no `kind`.
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any])
        legacy["kind"] = nil; legacy["isBriefing"] = true
        let old = try JSONDecoder().decode(CoachConversation.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.kind == .morningBriefing && old.isBriefing)
        legacy["isBriefing"] = nil
        let older = try JSONDecoder().decode(CoachConversation.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(older.kind == .chat && !older.isBriefing)

        let prefs = try JSONDecoder().decode(CoachPreferences.self, from: Data(#"{"instructions":"","morningEnabled":true,"morningHour":7,"morningSharing":{"metrics":true},"lastAttemptDay":"2026-10-15"}"#.utf8))
        #expect(prefs.lastWeeklyReviewWeek == nil && prefs.morningEnabled)
        var saved = prefs; saved.lastWeeklyReviewWeek = "2026-10-05"
        #expect(try JSONDecoder().decode(CoachPreferences.self, from: JSONEncoder().encode(saved)).lastWeeklyReviewWeek == "2026-10-05")
    }
}

// MARK: Weekly review through the briefing runtime

private actor ReviewRepository: CoachConversationRepository {
    var rows: [UUID: CoachConversation] = [:]
    var prefs = CoachPreferences()
    func conversations() -> [CoachConversation] { rows.values.sorted { $0.updatedAt > $1.updatedAt } }
    func save(_ conversation: CoachConversation) { rows[conversation.id] = conversation }
    func delete(id: UUID) { rows[id] = nil }
    func preferences() -> CoachPreferences { prefs }
    func savePreferences(_ preferences: CoachPreferences) { prefs = preferences }
}

private actor ReviewContext: LooprCoachContextSource {
    func summary(sharing: CoachSharing, at date: Date) -> String { summaryResult(sharing: sharing, at: date).text }
    func summaryResult(sharing: CoachSharing, at date: Date) -> LooprCoachSummary {
        LooprCoachSummary(text: "Summary. answers=\(sharing.journalAnswers) metrics=\(sharing.metrics)", daysWithData: 3)
    }
    func saveAdvice(message: CoachChatMessage, at date: Date) -> UUID { message.id }
}

private final class ReviewTransport: CoachChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [CoachChatRequest] = []
    var requests: [CoachChatRequest] { lock.withLock { seen } }
    func stream(_ request: CoachChatRequest, key: String) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        lock.withLock { seen.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Your week held steady.")); continuation.yield(.completed); continuation.finish()
        }
    }
    func models(provider: CoachProvider, key: String) async throws -> [String] { [] }
}

extension PatternsRuntimeTests {
    @MainActor
    private struct ReviewRig {
        let briefing: CoachBriefingRuntime
        let repository: ReviewRepository
        let transport: ReviewTransport
        let store: InMemoryPatternStore
        let suite: AgentFixtures.Suite
    }

    @MainActor
    private func reviewRig(consent: Bool, domainsOn: Set<AgentDataDomain> = Set(AgentDataDomain.allCases)) async throws -> ReviewRig {
        let suite = AgentFixtures.Suite(); suite.setOnly(domainsOn)
        let transport = ReviewTransport()
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: transport)
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "test-key")
        let repository = ReviewRepository()
        var preferences = CoachPreferences()
        preferences.morningEnabled = consent; preferences.morningHour = 23
        preferences.morningConfiguration = try await runtime.selectedConfiguration()
        preferences.morningConsentAt = consent ? F.now : nil
        preferences.morningSharing = CoachSharing(metrics: true, journal: true, cycle: false)
        await repository.savePreferences(preferences)
        let store = InMemoryPatternStore()
        try await store.replaceFoundPatterns([F.alcohol, F.lateDinner])
        let patterns = LooprPatternsRuntime()
        patterns.install(F.engine(store: store, data: PatternDataBox()))
        let briefing = CoachBriefingRuntime(repository: repository, context: ReviewContext(), runtime: runtime, accessDefaults: suite.defaults,
                                            patterns: patterns, notify: { _, _ in })
        return ReviewRig(briefing: briefing, repository: repository, transport: transport, store: store, suite: suite)
    }

    @MainActor
    @Test func withoutBriefingConsentTheReviewStaysLocalAndNothingIsSent() async throws {
        let rig = try await reviewRig(consent: false)
        await rig.briefing.runWeeklyReviewIfDue(now: F.now)
        #expect(rig.transport.requests.isEmpty, "a request went out without briefing consent")
        let review = try #require(try await rig.store.reviews().first)
        #expect(review.weekStartDay == "2026-10-05" && !review.text.isEmpty)
        #expect(await rig.repository.conversations().isEmpty)
        #expect(await rig.repository.preferences().lastWeeklyReviewWeek == nil, "the week stays open until consent exists")
    }

    @MainActor
    @Test func withConsentAndAKeyAProviderWritesTheWordingFromGateFilteredFacts() async throws {
        let rig = try await reviewRig(consent: true)
        await rig.briefing.runWeeklyReviewIfDue(now: F.now)
        let sent = try #require(rig.transport.requests.first)
        #expect(rig.transport.requests.count == 1 && sent.recording.purpose == .weeklyReview)
        #expect(sent.context.contains("lower on nights after you logged alcohol") && sent.context.contains("Summary. answers=true"))
        #expect(sent.messages.last?.text.contains("Never say what caused") == true)
        let chat = try #require(await rig.repository.conversations().first)
        #expect(chat.kind == .weeklyReview && chat.isBriefing && chat.title == "Weekly review · Sun 11 Oct")
        #expect(chat.messages.last?.text == "Your week held steady.")
        #expect(await rig.repository.preferences().lastWeeklyReviewWeek == "2026-10-05")

        // One review for each week.
        await rig.briefing.runWeeklyReviewIfDue(now: F.now)
        #expect(rig.transport.requests.count == 1)
        #expect(await rig.repository.conversations().count == 1)
    }

    @MainActor
    @Test func aDomainTurnedOffInYourDataKeepsItsPatternsOutOfTheRequest() async throws {
        var on = Set(AgentDataDomain.allCases); on.remove(.journalAnswers)
        let rig = try await reviewRig(consent: true, domainsOn: on)
        await rig.briefing.runWeeklyReviewIfDue(now: F.now)
        let sent = try #require(rig.transport.requests.first)
        #expect(!sent.context.contains("alcohol"), "journal answers are off, so the alcohol pattern must not leave the phone")
        #expect(sent.context.contains("when you ate after 21:00"))
        #expect(sent.context.contains("answers=false"))

        let none = try await reviewRig(consent: true, domainsOn: [.cycle])
        await none.briefing.runWeeklyReviewIfDue(now: F.now)
        #expect(none.transport.requests.isEmpty, "with metrics off no pattern may be sent")
    }
}
