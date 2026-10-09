import AnalyticsKit
import XCTest

final class RealAgeTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testBirthdayAndLeapDayAreCalendarCorrect() {
        let calculator = RealAgeCalculator()
        let birth = date(2000, 2, 29)
        XCTAssertEqual(calculator.completedYears(dateOfBirth: birth, on: date(2023, 2, 28), timeZone: utc), 23)
        XCTAssertEqual(calculator.completedYears(dateOfBirth: birth, on: date(2023, 3, 1), timeZone: utc), 23)
        XCTAssertEqual(calculator.completedYears(dateOfBirth: date(1990, 8, 17), on: date(2026, 8, 16), timeZone: utc), 35)
        XCTAssertEqual(calculator.completedYears(dateOfBirth: date(1990, 8, 17), on: date(2026, 8, 17), timeZone: utc), 36)
    }

    func testTimezoneDayAndRestoredProfileUseDateOfBirth() {
        let calculator = RealAgeCalculator()
        let birth = date(2000, 1, 2, hour: 23, timeZone: utc)
        let calculation = date(2026, 1, 3, hour: 0, timeZone: utc)
        XCTAssertEqual(calculator.completedYears(dateOfBirth: birth, on: calculation, timeZone: utc), 26)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, timeZone: TimeZone? = nil) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

final class FriendReferenceFixtureTests: XCTestCase {
    func testVersionOneMatchesPublishedTable() {
        let curve = FriendReferenceCurve.version1
        XCTAssertEqual(curve.referenceVersion, 1)
        XCTAssertEqual(curve.unit, "mL/kg/min")
        XCTAssertEqual(curve.points.map(\.calculationAge), [25, 35, 45, 55, 65, 75])
        XCTAssertEqual(curve.points.map(\.femaleMedian), [37.6, 30.2, 26.7, 23.4, 20.0, 18.3])
        XCTAssertEqual(curve.points.map(\.maleMedian), [48.0, 42.4, 37.8, 32.6, 28.2, 24.4])
    }

    func testTrackedJSONFixtureParsesToTheSameCurve() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Analytics/friend_reference_v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let loaded = try JSONDecoder().decode(FriendReferenceCurve.self, from: data)
        XCTAssertEqual(loaded, .version1)
    }
}

final class CardioAgeInterpolationTests: XCTestCase {
    func testInterpolationAndEvidenceBoundaries() {
        let calculator = CardioAgeCalculator()
        let midpoint = calculator.calculate(vo2max: 33.9, referenceGroup: .female, curve: .version1, source: .healthKit)
        XCTAssertEqual(midpoint.ageYears!, 30, accuracy: 1e-9)
        XCTAssertNil(midpoint.displayLabel)

        let young = calculator.calculate(vo2max: 40, referenceGroup: .female, curve: .version1)
        XCTAssertEqual(young.ageYears, 25)
        XCTAssertEqual(young.displayLabel, "25 or younger")
        let old = calculator.calculate(vo2max: 10, referenceGroup: .female, curve: .version1)
        XCTAssertEqual(old.ageYears, 75)
        XCTAssertEqual(old.displayLabel, "75 or older")
        XCTAssertEqual(calculator.calculate(vo2max: 30, referenceGroup: nil, curve: .version1).absenceReason, .declinedReferenceCurve)
    }
}

final class VO2maxSourceSelectionTests: XCTestCase {
    func testPrecedenceAndHealthKitCoverageGate() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let selector = VO2MaxSourceSelector()
        let healthKit = [
            HealthKitVO2MaxSample(vo2max: 30, sampledAt: now.addingTimeInterval(-20 * 86_400), sourceIdentifier: "hk", testType: .maxExercise),
            HealthKitVO2MaxSample(vo2max: 32, sampledAt: now.addingTimeInterval(-10 * 86_400), sourceIdentifier: "hk", testType: .predictionSubMaxExercise),
            HealthKitVO2MaxSample(vo2max: 31, sampledAt: now.addingTimeInterval(-1 * 86_400), sourceIdentifier: "hk", testType: .predictionSubMaxExercise)
        ]
        let selected = selector.select(now: now, measuredCPET: [], healthKit: healthKit)
        XCTAssertEqual(selected.value!, 31, accuracy: 1e-9)
        XCTAssertEqual(selected.source, .healthKit)

        let cpet = MeasuredCPETSample(vo2max: 45, measuredAt: now.addingTimeInterval(-10 * 86_400))
        XCTAssertEqual(selector.select(now: now, measuredCPET: [cpet], healthKit: healthKit).source, .measuredCPET)
        let estimate = LooprExerciseVO2MaxEstimate(vo2max: 50, estimatedAt: now, protocolIdentifier: "field")
        XCTAssertEqual(selector.select(now: now, measuredCPET: [], healthKit: [], looprEstimate: estimate), .unavailable(reason: .noVO2MaxSource))
    }

    func testOnlyExerciseTestTypesReachCardioAge() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let values: [HealthKitVO2MaxTestType?] = [
            .maxExercise, .predictionSubMaxExercise, .predictionNonExercise, .predictionStepTest, nil
        ]
        let samples = values.enumerated().map { index, type in
            HealthKitVO2MaxSample(vo2max: Double(30 + index),
                sampledAt: now.addingTimeInterval(-Double(20 - index * 5) * 86_400),
                sourceIdentifier: "health", testType: type)
        }
        let selector = VO2MaxSourceSelector(minimumHealthKitSamples: 2, minimumHealthKitSpan: 5 * 86_400)
        let selected = selector.select(now: now, measuredCPET: [], healthKit: samples)
        XCTAssertEqual(selected.source, .healthKit)
        XCTAssertEqual(selected.value!, 30.5, accuracy: 1e-9)
        XCTAssertEqual(selector.select(now: now, measuredCPET: [], healthKit: Array(samples.suffix(3))),
                       .unavailable(reason: .noVO2MaxSource))
    }
}

final class NoHeuristicFitnessAgeTests: XCTestCase {
    func testExerciseEstimateCannotProduceCardioAgeWithoutValidation() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let estimate = LooprExerciseVO2MaxEstimate(vo2max: 50, estimatedAt: now, protocolIdentifier: "field")
        let selection = VO2MaxSourceSelector().select(now: now, measuredCPET: [], healthKit: [], looprEstimate: estimate)
        XCTAssertEqual(selection, .unavailable(reason: .noVO2MaxSource))
    }
}

final class ContributorSnapshotTests: XCTestCase {
    func testSnapshotCarriesCanonicalSourcesAndQuality() {
        let snapshot = DailyAgeContributorSnapshot(
            day: Date(timeIntervalSince1970: 2_000_000_000),
            quality: AgeSnapshotQuality(wearCoverage: 0.9, qualityScore: 0.8),
            cardioCapacity: AgeMetricValue(value: 42, unit: "mL/kg/min", source: "VO2MaxCanonical")
        )
        XCTAssertEqual(snapshot.cardioCapacity?.source, "VO2MaxCanonical")
        XCTAssertTrue(snapshot.quality.isEligible)
    }

    func testRawStreamValueIsNotAcceptedAsAContributor() {
        let raw = DailyAgeContributorSnapshot(
            day: Date(timeIntervalSince1970: 2_000_000_000),
            cardioCapacity: AgeMetricValue(value: 42, unit: "mL/kg/min", source: "raw-stream", isCanonical: false)
        )
        let result = AgeContributorAggregator().aggregate(
            snapshots: [raw],
            modelWindow: DateInterval(start: Date(timeIntervalSince1970: 2_000_000_000), duration: 86_400)
        )
        let cardio = result.contributors.first { $0.kind == .cardioCapacity }
        XCTAssertNil(cardio?.rawAggregate)
    }
}

final class ContributorAggregationTests: XCTestCase {
    func testNinetyDaysAreProvisionalAndOneHundredEightyAreEstablished() {
        let aggregator = AgeContributorAggregator()
        let ninety = makeSnapshots(days: 90)
        let provisional = aggregator.aggregate(snapshots: ninety, modelWindow: interval(days: 90))
        XCTAssertEqual(provisional.confidenceTier, .provisional)

        let established = aggregator.aggregate(snapshots: makeSnapshots(days: 180), modelWindow: interval(days: 180))
        XCTAssertEqual(established.confidenceTier, .established)
        XCTAssertEqual(established.coverage.coverageFraction, 1, accuracy: 1e-9)
    }

    private func makeSnapshots(days: Int) -> [DailyAgeContributorSnapshot] {
        (0..<days).map { offset in
            DailyAgeContributorSnapshot(
                day: Date(timeIntervalSince1970: 2_000_000_000 + Double(offset) * 86_400),
                cardioCapacity: AgeMetricValue(value: 40, unit: "mL/kg/min", source: "canonical"),
                restingHeartRate: AgeMetricValue(value: 55, unit: "bpm", source: "canonical"),
                dailyMovement: AgeMetricValue(value: 8_000, unit: "steps", source: "canonical"),
                lowModerateAerobicMinutes: AgeMetricValue(value: 30, unit: "min", source: "canonical"),
                vigorousAerobicMinutes: AgeMetricValue(value: 15, unit: "min", source: "canonical"),
                strengthMinutes: AgeMetricValue(value: 20, unit: "min", source: "canonical"),
                sleepDurationHours: AgeMetricValue(value: 7.5, unit: "hours", source: "canonical"),
                sleepOnsetMinuteOfDay: 1_380,
                sleepOffsetMinuteOfDay: 420
            )
        }
    }

    private func interval(days: Int) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: 2_000_000_000), duration: Double(days) * 86_400)
    }
}

final class AgeConfidenceTierTests: XCTestCase {
    func testUnavailableForInsufficientCoverage() {
        let result = AgeContributorAggregator().aggregate(
            snapshots: [],
            modelWindow: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 180 * 86_400)
        )
        XCTAssertEqual(result.confidenceTier, .unavailable)
        XCTAssertEqual(result.absenceReason, .insufficientCoverage)
    }
}

final class CompositeUnavailableInANA07ATests: XCTestCase {
    func testPublicStageAInitializerCannotPopulateComposite() {
        let result = LooprAgeResult(
            realAgeYears: 40,
            cardioAge: nil,
            modelWindow: DateInterval(start: .distantPast, end: .distantFuture),
            contributors: [],
            coverage: .empty,
            confidence: 0,
            confidenceTier: .unavailable,
            modelVersion: 1,
            referenceVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNil(result.looprAgeYears)
        XCTAssertEqual(result.absenceReason, .compositeNotYetValidated)
    }
}

final class AgeAbstentionIdempotenceTests: XCTestCase {
    func testSameInputProducesEqualSnapshotsAndAbsentVO2() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let input = AgeDerivationInput(
            dateOfBirth: Date(timeIntervalSince1970: 0),
            calculationDate: now,
            modelWindow: DateInterval(start: now.addingTimeInterval(-180 * 86_400), end: now),
            referenceGroup: .female,
            contributorSnapshots: []
        )
        let engine = AgeDerivationEngine()
        let lhs = try await engine.derive(input)
        let rhs = try await engine.derive(input)
        XCTAssertEqual(lhs, rhs)
        XCTAssertNil(lhs.cardioAge?.ageYears)
        XCTAssertNil(lhs.looprAgeYears)
    }

    func testAgeOutputIsReadableThroughTheDomainCanonicalSeam() async throws {
        let result = LooprAgeResult(
            realAgeYears: 40,
            cardioAge: nil,
            modelWindow: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1),
            contributors: [],
            coverage: .empty,
            confidence: 0,
            confidenceTier: .unavailable,
            modelVersion: 1,
            referenceVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let repository = InMemoryAgeResultRepository()
        try await repository.save(result)
        let latest = try await repository.readLatestAgeResult()
        XCTAssertEqual(latest, result)
    }

    func testAgeResultHasNoHealthKitExportMetadata() {
        let result = LooprAgeResult(
            realAgeYears: 40,
            cardioAge: nil,
            modelWindow: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1),
            contributors: [],
            coverage: .empty,
            confidence: 0,
            confidenceTier: .unavailable,
            modelVersion: 1,
            referenceVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let labels = Mirror(reflecting: result).children.compactMap(\.label).joined(separator: "|")
        XCTAssertFalse(labels.localizedCaseInsensitiveContains("healthkit"))
        XCTAssertFalse(labels.localizedCaseInsensitiveContains("quantity"))
    }
}

final class AgeCancellationTests: XCTestCase {
    func testCancelledDerivationThrowsCancellation() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let input = AgeDerivationInput(
            dateOfBirth: Date(timeIntervalSince1970: 0),
            calculationDate: now,
            modelWindow: DateInterval(start: now.addingTimeInterval(-180 * 86_400), end: now),
            referenceGroup: .female
        )
        let gate = AsyncStream<Void>.makeStream()
        let task = Task { () -> LooprAgeResult? in
            for await _ in gate.stream { break }
            return try await AgeDerivationEngine().derive(input)
        }
        task.cancel()
        gate.continuation.finish()
        do {
            _ = try await task.value
            XCTFail("cancelled derivation should not publish")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
