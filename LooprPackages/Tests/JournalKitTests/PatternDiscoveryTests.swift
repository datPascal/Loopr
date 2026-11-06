import DomainKit
import Foundation
import JournalKit
import XCTest

final class PatternDiscoveryTests: XCTestCase {
    private typealias F = PatternFixtures

    // MARK: Strength thresholds

    func testStrongNeedsTwiceThePracticalThresholdAndPBelowOnePercent() {
        // Sleep score: practical threshold 3, so strong starts at an adjusted effect of 6.
        XCTAssertEqual(PatternPolicy.default.practicalThreshold(for: .sleepScore), 3)
        XCTAssertEqual(PatternStrength.classify(F.metric(.sleepScore, status: .clearAssociation, adjusted: 6, p: 0.009)), .strong)
        XCTAssertEqual(PatternStrength.classify(F.metric(.sleepScore, status: .clearAssociation, adjusted: -6, p: 0.009)), .strong)
        XCTAssertEqual(PatternStrength.classify(F.metric(.sleepScore, status: .clearAssociation, adjusted: 5.99, p: 0.0001)), .clear)
        XCTAssertEqual(PatternStrength.classify(F.metric(.sleepScore, status: .clearAssociation, adjusted: 12, p: 0.01)), .clear,
                       "p must be below 0.01, not equal to it")
        XCTAssertEqual(PatternStrength.classify(F.metric(.sleepScore, status: .clearAssociation, adjusted: 12, p: 0.04)), .clear)
        XCTAssertEqual(PatternStrength.classify(F.metric(.sleepScore, status: .clearAssociation, adjusted: 12, p: nil)), .clear,
                       "no p-value cannot earn Strong")
    }

    func testRecoveryHasNoHolmValueSoItsBootstrapPValueDecidesStrong() {
        let strong = F.metric(.recoveryScore, status: .clearAssociation, adjusted: 7, p: nil, bootstrapP: 0.004)
        XCTAssertEqual(PatternStrength.classify(strong), .strong)
        let weakP = F.metric(.recoveryScore, status: .clearAssociation, adjusted: 7, p: nil, bootstrapP: 0.02)
        XCTAssertEqual(PatternStrength.classify(weakP), .clear)
        let small = F.metric(.recoveryScore, status: .clearAssociation, adjusted: 4, p: nil, bootstrapP: 0.001)
        XCTAssertEqual(PatternStrength.classify(small), .clear)
    }

    func testThresholdsComeFromTheMetricNotAFixedNumber() {
        // HRV threshold is 5 ms, so 10 ms is strong and 9.9 ms is not.
        XCTAssertEqual(PatternStrength.classify(F.metric(.hrvRMSSD, status: .clearAssociation, adjusted: -10, p: 0.001)), .strong)
        XCTAssertEqual(PatternStrength.classify(F.metric(.hrvRMSSD, status: .clearAssociation, adjusted: -9.9, p: 0.001)), .clear)
        // Resting heart rate threshold is 1 bpm.
        XCTAssertEqual(PatternStrength.classify(F.metric(.restingHeartRate, status: .clearAssociation, adjusted: 2, p: 0.001)), .strong)
    }

    func testEarlySignalIsEarlyAndOnlyInDetail() throws {
        let early = F.metric(.sleepScore, status: .earlySignal, adjusted: nil, raw: 9, p: nil, yes: 6, no: 6)
        XCTAssertEqual(PatternStrength.classify(early), .early)
        XCTAssertFalse(PatternStrength.early.isHeadlineWorthy)
        XCTAssertTrue(PatternStrength.clear.isHeadlineWorthy)
        XCTAssertTrue(PatternStrength.strong.isHeadlineWorthy)
        XCTAssertLessThan(PatternStrength.early, .clear)
        XCTAssertLessThan(PatternStrength.clear, .strong)
        let none = F.metric(.sleepScore, status: .earlySignal, adjusted: nil, raw: nil, p: nil)
        XCTAssertNil(PatternStrength.classify(none), "an early signal with no number has nothing to show")
    }

    func testEverythingElseIsHidden() {
        let other = HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000009999")!)
        for status in [HabitInsightStatus.cannotSeparate, .noClearAssociation, .stale, .collecting, .unavailable, .enoughData] {
            XCTAssertNil(PatternStrength.classify(F.metric(.sleepScore, status: status)), "\(status)")
        }
        XCTAssertNil(PatternStrength.classify(F.metric(.sleepScore, status: .clearAssociation, overlapping: other)),
                     "an overlapping habit hides the result even if the status was not downgraded")
        var noSample = F.metric(.sleepScore, status: .clearAssociation)
        noSample = HabitMetricEstimate(metricID: .sleepScore, yesMean: 1, noMean: 2, rawDifference: 1,
                                       adjustedDifference: 1, intervalLower: nil, intervalUpper: nil)
        XCTAssertNil(PatternStrength.classify(noSample))
    }

    func testCannotSeparateResultsNeverReachTheList() {
        let late = F.lateDinner
        let other = HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000009999")!)
        let estimate = F.estimate(habit: late.habitID, metrics: [
            F.metric(.sleepScore, status: .cannotSeparate, overlapping: other),
            F.metric(.deepSleepMinutes, status: .cannotSeparate, overlapping: other)])
        let result = PatternDiscoveryEngine(policy: F.shortPolicy)
            .result(candidates: [late], estimates: [estimate], windowEnd: F.discoveryEnd, calculatedAt: F.date(F.discoveryEnd))
        XCTAssertTrue(result.patterns.isEmpty)
        XCTAssertTrue(result.headline.isEmpty)
        XCTAssertEqual(result.cannotSeparateCount, 1)
    }

    // MARK: Engine

    func testEngineFindsStrongClearAndEarlyPatternsAndHidesTheRest() async throws {
        let engine = PatternDiscoveryEngine(policy: F.shortPolicy)
        let now = F.date(F.discoveryEnd, hour: 21)
        let result = try await engine.discoverInBackground(provider: F.discoveryProvider(), endingOn: F.discoveryEnd, calculatedAt: now)
        let keys = result.patterns.map(\.key)
        let alcoholKey = "journal.00000000-0000-0000-0000-000000005001.hrvRMSSD"
        XCTAssertEqual(keys, ["food.lateMeal.sleepScore", alcoholKey, "steps10k.sleepDuration", "steps10k.sleepScore"],
                       "strong, clear, then two early reads on the twelve step days, nothing else")

        let strong = try XCTUnwrap(result.patterns.first)
        XCTAssertEqual(strong.strength, .strong)
        XCTAssertEqual(strong.metric, .sleepScore)
        XCTAssertEqual(strong.effect.difference, -12, accuracy: 2)
        XCTAssertGreaterThanOrEqual(abs(strong.effect.difference), 2 * strong.effect.practicalThreshold)
        XCTAssertLessThan(try XCTUnwrap(strong.effect.pValue), 0.01)
        XCTAssertEqual(strong.nights, PatternNights(with: 26, without: 34))
        XCTAssertEqual(strong.windowEnd, F.discoveryEnd)
        XCTAssertEqual(strong.algorithmVersion, "patterns.v1/journal.habit-impact.v2")
        XCTAssertEqual(strong.effect.unit, .scorePoints)

        let clear = result.patterns[1]
        XCTAssertEqual(clear.strength, .clear)
        XCTAssertEqual(clear.effect.difference, -7, accuracy: 2)
        XCTAssertLessThan(abs(clear.effect.difference), 2 * clear.effect.practicalThreshold)

        let early = result.patterns[2]
        XCTAssertEqual(early.strength, .early)
        XCTAssertEqual(early.nights, PatternNights(with: 6, without: 6))
        XCTAssertEqual(early.effect.difference, 30, accuracy: 5)
        XCTAssertEqual(result.patterns[3].strength, .early)
        XCTAssertEqual(result.patterns.map(\.strength), [.strong, .clear, .early, .early])

        XCTAssertEqual(result.headline.map(\.key), Array(keys.prefix(2)), "early stays out of the headline list")
        XCTAssertEqual(result.cannotSeparateCount, 2, "training day and leg day carry identical answers")
        XCTAssertFalse(keys.contains { $0.hasPrefix("training.") || $0.hasPrefix("legDay.") })
        XCTAssertFalse(keys.contains("food.lateMeal.deepSleepMinutes"), "no association is not a pattern")
    }

    /// ICP R2-VET-09: each found pattern carries the person's usual night-to-night spread of its measure, the number
    /// Experiments calls the usual spread, so the gap can be read against a normal night.
    func testAFoundPatternCarriesTheUsualSpreadOfItsMeasure() async throws {
        let engine = PatternDiscoveryEngine(policy: F.shortPolicy)
        let result = try await engine.discover(provider: F.discoveryProvider(includeTrainingPair: false, includeSteps: false),
                                               endingOn: F.discoveryEnd, calculatedAt: F.date(F.discoveryEnd, hour: 21))
        XCTAssertFalse(result.patterns.isEmpty)
        for pattern in result.patterns {
            let spread = try XCTUnwrap(pattern.effect.spread, pattern.key)
            XCTAssertTrue(spread.isFinite && spread > 0, pattern.key)
        }

        // Fourteen nights whose back-to-back changes have a median of 1 and a median absolute deviation of exactly 5,
        // so the spread is 5 scaled to one night, 5 x 1.4826 / root 2. A measure with three nights has none.
        let values: [Double] = [50, 54, 49, 55, 50, 53, 48, 54, 51, 52, 47, 55, 50, 53]
        let keys = PatternDays.range(from: "2026-09-01", count: values.count)
        let outcomes = zip(keys, values).map { F.outcome($0, [.deepSleepMinutes: $1]) }
            + keys.prefix(3).map { F.outcome($0, [.hrvRMSSD: 40]) }
        let spreads = engine.spreads(PatternOutcomeSet(outcomes: outcomes), endingOn: try XCTUnwrap(DayIdentity(habitKey: "2026-09-14")))
        XCTAssertEqual(try XCTUnwrap(spreads[.deepSleepMinutes]), 5 * 1.4826 / 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertNil(spreads[.hrvRMSSD])
    }

    /// A pattern stored before the spread existed decodes with none, so the screen leaves the line out.
    func testAPatternStoredBeforeTheSpreadDecodesWithoutOne() throws {
        let old = #"{"adjustedDifference":-8,"practicalThreshold":3,"unit":"milliseconds"}"#
        let effect = try JSONDecoder().decode(PatternEffect.self, from: Data(old.utf8))
        XCTAssertNil(effect.spread)
        XCTAssertEqual(effect.difference, -8)
        let again = try JSONDecoder().decode(PatternEffect.self, from: try JSONEncoder().encode(
            PatternEffect(adjustedDifference: -8, rawDifference: nil, withMean: nil, withoutMean: nil, intervalLower: nil,
                          intervalUpper: nil, pValue: nil, practicalThreshold: 3, unit: .milliseconds, spread: 11)))
        XCTAssertEqual(again.spread, 11)
    }

    func testInBackgroundAndInlineRunsAgree() async throws {
        let engine = PatternDiscoveryEngine(policy: F.shortPolicy)
        let provider = F.discoveryProvider(includeTrainingPair: false, includeSteps: false)
        let now = F.date(F.discoveryEnd, hour: 21)
        let inline = try await engine.discover(provider: provider, endingOn: F.discoveryEnd, calculatedAt: now)
        let background = try await engine.discoverInBackground(provider: provider, endingOn: F.discoveryEnd, calculatedAt: now)
        XCTAssertEqual(inline, background, "same seed, same input, same patterns")
        XCTAssertEqual(inline.cannotSeparateCount, 0)
        XCTAssertEqual(inline.patterns.map(\.strength), [.strong, .clear])
    }

    func testWindowEndFollowsTheRequestedDayAndTwentyOneNightsCannotBeMoreThanEarly() async throws {
        let engine = PatternDiscoveryEngine(policy: F.shortPolicy)
        let early = PatternDays.add(-39, to: F.discoveryEnd)!
        XCTAssertEqual(early, "2026-08-22")
        let result = try await engine.discover(provider: F.discoveryProvider(includeTrainingPair: false, includeSteps: false),
                                               endingOn: early, calculatedAt: F.date(early, hour: 21))
        XCTAssertEqual(result.windowEnd, early)
        XCTAssertFalse(result.patterns.isEmpty)
        for pattern in result.patterns {
            XCTAssertEqual(pattern.windowEnd, early)
            XCTAssertEqual(pattern.strength, .early, "under 30 eligible days nothing reaches Clear")
        }
        XCTAssertTrue(result.headline.isEmpty)
    }

    func testCancellationStopsTheRunWithoutAResult() async {
        let engine = PatternDiscoveryEngine(policy: F.shortPolicy)
        let provider = F.discoveryProvider()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.discoverInBackground(provider: provider, endingOn: F.discoveryEnd, calculatedAt: F.date(F.discoveryEnd))
        }
        do { _ = try await task.value; XCTFail("a cancelled run must not publish") }
        catch is CancellationError { }
        catch { XCTFail("unexpected \(error)") }
    }

    // MARK: Candidates

    func testCatalogCoversJournalFoodTrainingLegDayAndSteps() {
        let archived = HabitDefinition(id: HabitID(rawValue: UUID()), source: .custom, name: "Old", question: "Old?",
                                       sortOrder: 5, archivedAt: F.date("2026-08-05"), createdAt: F.date("2026-08-01"))
        let catalog = PatternCandidate.catalog(journalHabits: [F.alcoholDefinition, archived], food: [F.lateDinner])
        XCTAssertEqual(catalog.map(\.kind), [.journalHabit, .food, .trainingDay, .legDay, .steps])
        XCTAssertEqual(Set(catalog.map(\.habitID)).count, catalog.count, "every candidate has its own fixed habit ID")
        XCTAssertEqual(catalog.last?.predicate, .stepsOver(10_000))
        XCTAssertEqual(catalog.last?.id, "steps10k")
        XCTAssertEqual(catalog[1].habitID.rawValue.uuidString, "FC100000-0000-4000-8000-000000000001")
        XCTAssertEqual(catalog.map(\.targetMetric).count, 5)
        XCTAssertEqual(PatternCandidate.catalog(journalHabits: [], food: [F.lateDinner, F.lateDinner]).filter { $0.kind == .food }.count, 1)
    }

    // MARK: Copy

    func testSummariesDescribeNightsAndNeverCause() {
        let late = FoundPattern(
            candidateID: F.lateDinner.id, habitID: F.lateDinner.habitID, title: "Late dinner", predicate: F.lateDinner.predicate,
            metric: .deepSleepMinutes, strength: .strong,
            effect: PatternEffect(adjustedDifference: -14.04, rawDifference: -15, withMean: 55, withoutMean: 70, intervalLower: -20,
                                  intervalUpper: -8, pValue: 0.001, practicalThreshold: 15, unit: .minutes),
            nights: .init(with: 12, without: 38), windowEnd: F.discoveryEnd, algorithmVersion: "x", foundAt: F.date(F.discoveryEnd))
        XCTAssertEqual(late.summary, "Deep sleep was 14 min lower on nights after a late dinner than on other nights.")
        XCTAssertEqual(late.nightsLabel, "12 nights with, 38 without")
        let steps = FoundPattern(
            candidateID: "steps10k", habitID: F.steps.habitID, title: "Over 10,000 steps", predicate: .stepsOver(10_000),
            metric: .hrvRMSSD, strength: .clear,
            effect: PatternEffect(adjustedDifference: 6.5, rawDifference: nil, withMean: nil, withoutMean: nil, intervalLower: nil,
                                  intervalUpper: nil, pValue: nil, practicalThreshold: 5, unit: .milliseconds),
            nights: .init(with: 20, without: 30), windowEnd: F.discoveryEnd, algorithmVersion: "x", foundAt: F.date(F.discoveryEnd))
        XCTAssertEqual(steps.summary, "HRV was 6.5 ms higher on nights after a day over 10,000 steps than on other nights.")
        let same = FoundPattern(
            candidateID: "training", habitID: F.steps.habitID, title: "Training day", predicate: .trainingDay,
            metric: .sleepScore, strength: .early,
            effect: PatternEffect(adjustedDifference: 0.01, rawDifference: nil, withMean: nil, withoutMean: nil, intervalLower: nil,
                                  intervalUpper: nil, pValue: nil, practicalThreshold: 3, unit: .scorePoints),
            nights: .init(with: 6, without: 6), windowEnd: F.discoveryEnd, algorithmVersion: "x", foundAt: F.date(F.discoveryEnd))
        XCTAssertEqual(same.summary, "Sleep score was the same on nights after a training day as on other nights.")
        for text in [late.summary, steps.summary, PatternCopy.foundEmpty, PatternCopy.footnote] {
            for word in ["because", "caused", "causes", "leads to", "due to", "results in"] {
                XCTAssertFalse(text.lowercased().contains(word), "\(text) reads as causal")
            }
            XCTAssertFalse(text.contains("\u{2014}"))
        }
        XCTAssertEqual(PatternCopy.footnote, "These compare your own nights. They do not show cause.")
        XCTAssertEqual(PatternCopy.foundEmpty, "Nothing clear yet. Loopr needs about 5 nights on each side before it says anything.")
    }

    func testAStandaloneFoodClauseReadsNaturallyAndNeverRepeatsAfter() {
        let eat = PatternPredicate.food(label: "when you eat after 21:00")
        XCTAssertEqual(eat.clause, "when you eat after 21:00")
        XCTAssertEqual(eat.question, "Did you eat after 21:00?")
        XCTAssertEqual(PatternPredicate.food(label: "a late dinner").clause, "after a late dinner", "an older label keeps its form")
        XCTAssertEqual(PatternPredicate.legDay.clause, "after a leg day")
        XCTAssertEqual(PatternPredicate.journalAnswer(name: "Alcohol").clause, "after you logged alcohol")
        let pattern = FoundPattern(
            candidateID: "food.lateMeal", habitID: F.lateDinner.habitID, title: "Last meal after 21:00", predicate: eat,
            metric: .deepSleepMinutes, strength: .strong,
            effect: PatternEffect(adjustedDifference: -19, rawDifference: -19, withMean: 52, withoutMean: 71, intervalLower: -22,
                                  intervalUpper: -16, pValue: 0.004, practicalThreshold: 6, unit: .minutes),
            nights: .init(with: 9, without: 32), windowEnd: F.discoveryEnd, algorithmVersion: "x", foundAt: F.date(F.discoveryEnd))
        XCTAssertEqual(pattern.summary, "Deep sleep was 19 min lower on nights when you ate after 21:00 than on other nights.")
        XCTAssertEqual(PatternCopy.counts(for: pattern, locale: Locale(identifier: "en_GB")),
                       "On 9 nights when you ate after 21:00, deep sleep averaged 52 min. On the other 32 nights it was 71 min.")
        let twelveHour = PatternCopy.counts(for: pattern, locale: Locale(identifier: "en_AU")).replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(twelveHour, "On 9 nights when you ate after 9:00 pm, deep sleep averaged 52 min. On the other 32 nights it was 71 min.")
    }

    func testTheCountsFallBackToTheDifferenceWithoutAverages() {
        func pattern(_ difference: Double, with: Int = 1, without: Int = 1) -> FoundPattern {
            FoundPattern(
                candidateID: "legDay", habitID: F.steps.habitID, title: "Leg day", predicate: .legDay, metric: .restingHeartRate,
                strength: .clear,
                effect: PatternEffect(adjustedDifference: difference, rawDifference: nil, withMean: nil, withoutMean: nil, intervalLower: nil,
                                      intervalUpper: nil, pValue: nil, practicalThreshold: 2, unit: .beatsPerMinute),
                nights: .init(with: with, without: without), windowEnd: F.discoveryEnd, algorithmVersion: "x", foundAt: F.date(F.discoveryEnd))
        }
        XCTAssertEqual(PatternCopy.counts(for: pattern(3, with: 4, without: 7), locale: Locale(identifier: "en_GB")),
                       "On 4 nights after a leg day, resting heart rate was 3 bpm higher than on the other 7 nights.")
        XCTAssertEqual(PatternCopy.counts(for: pattern(0), locale: Locale(identifier: "en_GB")), "On 1 night after a leg day, resting heart rate was the same as on the other 1 night.")
        for word in ["because", "caused", "causes", "leads to", "due to", "results in"] {
            XCTAssertFalse(PatternCopy.counts(for: pattern(3, with: 4, without: 7)).lowercased().contains(word))
        }
    }

    // MARK: Old data

    func testStoredPatternsDecodeWithMissingFields() throws {
        let json = """
        {"candidateID":"food.lateMeal","habitID":{"rawValue":"FC100000-0000-4000-8000-000000000001"},"metric":"sleepScore"}
        """.data(using: .utf8)!
        let pattern = try JSONDecoder().decode(FoundPattern.self, from: json)
        XCTAssertEqual(pattern.key, "food.lateMeal.sleepScore")
        XCTAssertEqual(pattern.strength, .early, "an unknown strength falls back to the weakest")
        XCTAssertEqual(pattern.nights, PatternNights(with: 0, without: 0))
        XCTAssertEqual(pattern.schemaVersion, 1)
        let candidate = try JSONDecoder().decode(PatternCandidate.self, from: """
        {"id":"training","habitID":{"rawValue":"FC200000-0000-4000-8000-000000000001"},"targetMetric":"hrvRMSSD"}
        """.data(using: .utf8)!)
        XCTAssertEqual(candidate.targetMetrics, [.hrvRMSSD])
        XCTAssertEqual(candidate.kind, .journalHabit)
        let roundTrip = try JSONDecoder().decode(PatternCandidate.self, from: JSONEncoder().encode(PatternCandidate.legDay))
        XCTAssertEqual(roundTrip, .legDay)
        for predicate in [PatternPredicate.trainingDay, .legDay, .stepsOver(12_000), .food(label: "a late dinner"), .journalAnswer(name: "Alcohol")] {
            XCTAssertEqual(try JSONDecoder().decode(PatternPredicate.self, from: JSONEncoder().encode(predicate)), predicate)
        }
    }
}
