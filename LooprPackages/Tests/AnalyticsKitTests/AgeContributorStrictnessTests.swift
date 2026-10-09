import AnalyticsKit
import XCTest

/// Deterministic, canonical-only snapshots used by the ANA-07A contributor
/// acceptance tests.  The fixtures intentionally use UTC civil days so the
/// coverage and ISO-week assertions do not depend on the host timezone.
enum AgeStrictFixture {
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let start = date(year: 2024, month: 1, day: 1)

    static func date(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 0))!
    }

    static func day(_ offset: Int) -> Date {
        start.addingTimeInterval(Double(offset) * 86_400)
    }

    static func interval(days: Int) -> DateInterval {
        DateInterval(start: start, duration: Double(days) * 86_400)
    }

    static func metric(
        _ value: Double,
        unit: String,
        source: String,
        quality: Double = 1,
        coverage: Double = 1
    ) -> AgeMetricValue {
        AgeMetricValue(
            value: value,
            unit: unit,
            source: source,
            quality: quality,
            coverage: coverage,
            isCanonical: true
        )
    }

    static func snapshot(
        day: Date,
        quality: AgeSnapshotQuality = AgeSnapshotQuality(),
        missing: [AgeContributorKind] = [],
        movement: Double = 8_000,
        lowModerate: Double = 10,
        vigorous: Double = 5,
        strength: Double = 2,
        sleepDuration: Double = 7.5
    ) -> DailyAgeContributorSnapshot {
        let missingNames = Set(missing.map(\.rawValue))
        func present(_ kind: AgeContributorKind) -> Bool {
            !missingNames.contains(kind.rawValue)
        }

        return DailyAgeContributorSnapshot(
            day: day,
            quality: quality,
            cardioCapacity: present(.cardioCapacity) ? metric(42, unit: "mL/kg/min", source: "canonical.cardio") : nil,
            restingHeartRate: present(.restingHeartRate) ? metric(55, unit: "bpm", source: "canonical.rhr") : nil,
            bodyComposition: present(.bodyComposition) ? metric(65, unit: "kg", source: "canonical.body") : nil,
            dailyMovement: present(.dailyMovement) ? metric(movement, unit: "steps", source: "canonical.movement") : nil,
            lowModerateAerobicMinutes: present(.lowModerateAerobicActivity) ? metric(lowModerate, unit: "min", source: "canonical.zone1_3") : nil,
            vigorousAerobicMinutes: present(.vigorousAerobicActivity) ? metric(vigorous, unit: "min", source: "canonical.zone4_5") : nil,
            strengthMinutes: present(.strengthActivity) ? metric(strength, unit: "min", source: "canonical.strength") : nil,
            sleepDurationHours: present(.sleepDuration) ? metric(sleepDuration, unit: "hours", source: "canonical.sleep") : nil,
            sleepOnsetMinuteOfDay: present(.sleepConsistency) ? 1_380 : nil,
            sleepOffsetMinuteOfDay: present(.sleepConsistency) ? 420 : nil
        )
    }

    static var requiredCoreKinds: [AgeContributorKind] {
        [
            .cardioCapacity,
            .restingHeartRate,
            .dailyMovement,
            .lowModerateAerobicActivity,
            .vigorousAerobicActivity,
            .strengthActivity,
            .sleepDuration,
            .sleepConsistency
        ]
    }

    static func contributor(
        _ result: AgeAggregationResult,
        kind: AgeContributorKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AgeContributor {
        try XCTUnwrap(
            result.contributors.first { $0.kind.rawValue == kind.rawValue },
            "missing contributor \(kind.rawValue)",
            file: file,
            line: line
        )
    }
}

extension ContributorSnapshotTests {
    func testAllNineContributorsArePopulatedFromCanonicalSources() throws {
        let result = AgeContributorAggregator().aggregate(
            snapshots: [AgeStrictFixture.snapshot(day: AgeStrictFixture.start)],
            modelWindow: AgeStrictFixture.interval(days: 1),
            timeZone: AgeStrictFixture.utc
        )

        XCTAssertEqual(result.contributors.count, AgeContributorKind.allCases.count)
        XCTAssertEqual(
            Set(result.contributors.map { $0.kind.rawValue }),
            Set(AgeContributorKind.allCases.map { $0.rawValue })
        )

        for kind in AgeContributorKind.allCases {
            let contributor = try AgeStrictFixture.contributor(result, kind: kind)
            XCTAssertNotNil(contributor.rawAggregate, kind.rawValue)
            XCTAssertGreaterThan(contributor.coverage, 0, kind.rawValue)
            XCTAssertTrue(contributor.source.hasPrefix("canonical."), kind.rawValue)
            XCTAssertEqual(contributor.availability, .available, kind.rawValue)
        }
    }
}

extension ContributorAggregationTests {
    func testRobustMediansRetainDistributionsAndWeeklyActivityIgnoresOneExtremeWeek() throws {
        let snapshots = (0..<90).map { offset in
            AgeStrictFixture.snapshot(
                day: AgeStrictFixture.day(offset),
                movement: offset == 0 ? 1_000_000 : 8_000,
                lowModerate: offset == 0 ? 1_000 : 10,
                vigorous: offset == 0 ? 800 : 5,
                strength: offset == 0 ? 400 : 2,
                sleepDuration: offset == 0 ? 24 : 7.5
            )
        }
        let result = AgeContributorAggregator().aggregate(
            snapshots: snapshots,
            modelWindow: AgeStrictFixture.interval(days: 90),
            timeZone: AgeStrictFixture.utc
        )

        let movement = try AgeStrictFixture.contributor(result, kind: .dailyMovement)
        XCTAssertEqual(try XCTUnwrap(movement.rawAggregate), 8_000, accuracy: 1e-9)
        XCTAssertEqual(movement.distribution.count, 90)
        XCTAssertTrue(movement.distribution.contains(1_000_000))

        let lowModerate = try AgeStrictFixture.contributor(result, kind: .lowModerateAerobicActivity)
        XCTAssertEqual(try XCTUnwrap(lowModerate.rawAggregate), 70, accuracy: 1e-9)
        XCTAssertGreaterThan(lowModerate.distribution.count, 2)
        XCTAssertTrue(lowModerate.distribution.contains { $0 > 1_000 })
        XCTAssertEqual(lowModerate.modelTransform, "weekly sum of HR zones 1-3")

        let sleep = try AgeStrictFixture.contributor(result, kind: .sleepDuration)
        XCTAssertEqual(try XCTUnwrap(sleep.rawAggregate), 7.5, accuracy: 1e-9)
        XCTAssertEqual(sleep.distribution.count, 90)
        XCTAssertEqual(result.confidenceTier, .provisional)
    }

    func testExactlySeventyPercentDomainCoveragePassesAndOneDayBelowItAbstains() throws {
        let completeDays = 63
        let complete = (0..<90).map { offset in
            AgeStrictFixture.snapshot(
                day: AgeStrictFixture.day(offset),
                missing: offset < completeDays ? [] : AgeStrictFixture.requiredCoreKinds
            )
        }
        let atThreshold = AgeContributorAggregator().aggregate(
            snapshots: complete,
            modelWindow: AgeStrictFixture.interval(days: 90),
            timeZone: AgeStrictFixture.utc
        )
        XCTAssertEqual(atThreshold.coverage.eligibleDays, 90)
        XCTAssertTrue(atThreshold.coverage.strongCoverage)
        XCTAssertEqual(atThreshold.confidenceTier, .provisional)
        let thresholdRHR = try AgeStrictFixture.contributor(atThreshold, kind: .restingHeartRate)
        XCTAssertEqual(thresholdRHR.coverage, 0.70, accuracy: 1e-12)
        XCTAssertEqual(thresholdRHR.availability, .available)

        let below = (0..<90).map { offset in
            AgeStrictFixture.snapshot(
                day: AgeStrictFixture.day(offset),
                missing: offset < completeDays - 1 ? [] : AgeStrictFixture.requiredCoreKinds
            )
        }
        let belowThreshold = AgeContributorAggregator().aggregate(
            snapshots: below,
            modelWindow: AgeStrictFixture.interval(days: 90),
            timeZone: AgeStrictFixture.utc
        )
        XCTAssertFalse(belowThreshold.coverage.strongCoverage)
        XCTAssertEqual(belowThreshold.confidenceTier, .unavailable)
        XCTAssertEqual(belowThreshold.absenceReason, .insufficientCoverage)
        let belowRHR = try AgeStrictFixture.contributor(belowThreshold, kind: .restingHeartRate)
        XCTAssertEqual(belowRHR.coverage, 62.0 / 90.0, accuracy: 1e-12)
        XCTAssertEqual(belowRHR.availability, .absent(reason: .insufficientCoverage))
    }

    func testLowWearIllnessUnsupportedMedicationAndFailedQualityAreExcluded() throws {
        let snapshots = (0..<180).map { offset -> DailyAgeContributorSnapshot in
            let quality: AgeSnapshotQuality
            switch offset {
            case 0: quality = AgeSnapshotQuality(lowWear: true)
            case 1: quality = AgeSnapshotQuality(acuteIllness: true)
            case 2: quality = AgeSnapshotQuality(unsupportedMedication: true)
            case 3: quality = AgeSnapshotQuality(qualityScore: 0)
            default: quality = AgeSnapshotQuality()
            }
            return AgeStrictFixture.snapshot(
                day: AgeStrictFixture.day(offset),
                quality: quality,
                movement: offset < 4 ? 1_000_000 : 8_000
            )
        }

        let result = AgeContributorAggregator().aggregate(
            snapshots: snapshots,
            modelWindow: AgeStrictFixture.interval(days: 180),
            timeZone: AgeStrictFixture.utc
        )
        let movement = try AgeStrictFixture.contributor(result, kind: .dailyMovement)
        XCTAssertEqual(result.coverage.eligibleDays, 176)
        XCTAssertEqual(movement.distribution.count, 176)
        XCTAssertEqual(try XCTUnwrap(movement.rawAggregate), 8_000, accuracy: 1e-9)
        XCTAssertTrue(result.coverage.strongCoverage)
        XCTAssertEqual(result.confidenceTier, .provisional)
        XCTAssertNil(result.absenceReason)
    }

    func testIllnessOrLowWearPausesPublicationWhenEligibleHistoryFallsBelowMinimum() {
        let snapshots = (0..<90).map { offset in
            AgeStrictFixture.snapshot(
                day: AgeStrictFixture.day(offset),
                quality: offset == 0
                    ? AgeSnapshotQuality(lowWear: true)
                    : AgeSnapshotQuality()
            )
        }
        let result = AgeContributorAggregator().aggregate(
            snapshots: snapshots,
            modelWindow: AgeStrictFixture.interval(days: 90),
            timeZone: AgeStrictFixture.utc
        )
        XCTAssertEqual(result.coverage.eligibleDays, 89)
        XCTAssertEqual(result.confidenceTier, .unavailable)
        XCTAssertEqual(result.absenceReason, .illnessOrLowWear)
    }
}

extension AgeConfidenceTierTests {
    func testAllFourConfidenceTiersRequireTheirSpecificGate() {
        let aggregator = AgeContributorAggregator()
        let unavailable = aggregator.aggregate(
            snapshots: [],
            modelWindow: AgeStrictFixture.interval(days: 180),
            timeZone: AgeStrictFixture.utc
        )
        XCTAssertEqual(unavailable.confidenceTier, .unavailable)
        XCTAssertEqual(unavailable.absenceReason, .insufficientCoverage)

        let provisional = aggregator.aggregate(
            snapshots: (0..<90).map { AgeStrictFixture.snapshot(day: AgeStrictFixture.day($0)) },
            modelWindow: AgeStrictFixture.interval(days: 90),
            timeZone: AgeStrictFixture.utc
        )
        XCTAssertEqual(provisional.confidenceTier, .provisional)
        XCTAssertNil(provisional.absenceReason)

        let established = aggregator.aggregate(
            snapshots: (0..<180).map { AgeStrictFixture.snapshot(day: AgeStrictFixture.day($0)) },
            modelWindow: AgeStrictFixture.interval(days: 180),
            timeZone: AgeStrictFixture.utc
        )
        XCTAssertEqual(established.confidenceTier, .established)
        XCTAssertNil(established.absenceReason)

        let lowConfidence = aggregator.aggregate(
            snapshots: (0..<180).map { AgeStrictFixture.snapshot(day: AgeStrictFixture.day($0)) },
            modelWindow: AgeStrictFixture.interval(days: 180),
            timeZone: AgeStrictFixture.utc,
            uncertaintyMaterial: true
        )
        XCTAssertEqual(lowConfidence.confidenceTier, .lowConfidence)
        XCTAssertNil(lowConfidence.absenceReason)
    }
}

extension AgeAbstentionIdempotenceTests {
    func testEveryListedAbsenceCaseRemainsExplicit() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let selector = VO2MaxSourceSelector()
        XCTAssertEqual(
            selector.select(now: now, measuredCPET: [], healthKit: []),
            .unavailable(reason: .noVO2MaxSource)
        )

        let calculator = CardioAgeCalculator()
        XCTAssertEqual(
            calculator.calculate(
                vo2max: 33,
                referenceGroup: .female,
                curve: .version1,
                calculationAge: 18
            ).absenceReason,
            .unsupportedPopulation
        )
        XCTAssertEqual(
            calculator.calculate(vo2max: 33, referenceGroup: nil, curve: .version1).absenceReason,
            .declinedReferenceCurve
        )

        let insufficient = AgeContributorAggregator().aggregate(
            snapshots: [],
            modelWindow: AgeStrictFixture.interval(days: 180),
            timeZone: AgeStrictFixture.utc
        )
        XCTAssertEqual(insufficient.confidenceTier, .unavailable)
        XCTAssertEqual(insufficient.absenceReason, .insufficientCoverage)

        let excluded = (0..<90).map { offset in
            AgeStrictFixture.snapshot(
                day: AgeStrictFixture.day(offset),
                quality: offset == 0 ? AgeSnapshotQuality(lowWear: true) : AgeSnapshotQuality()
            )
        }
        let illnessOrLowWear = AgeContributorAggregator().aggregate(
            snapshots: excluded,
            modelWindow: AgeStrictFixture.interval(days: 90),
            timeZone: AgeStrictFixture.utc
        )
        XCTAssertEqual(illnessOrLowWear.confidenceTier, .unavailable)
        XCTAssertEqual(illnessOrLowWear.absenceReason, .illnessOrLowWear)
    }

    func testStaleVO2SourcesDoNotBecomeAValue() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let staleCPET = MeasuredCPETSample(
            vo2max: 45,
            measuredAt: now.addingTimeInterval(-181 * 86_400)
        )
        let staleHealthKit = (0..<3).map { offset in
            HealthKitVO2MaxSample(
                vo2max: 35 + Double(offset),
                sampledAt: now.addingTimeInterval(-43 * 86_400 - Double(offset) * 86_400),
                sourceIdentifier: "stale"
            )
        }
        let selection = VO2MaxSourceSelector().select(
            now: now,
            measuredCPET: [staleCPET],
            healthKit: staleHealthKit
        )
        XCTAssertEqual(selection, .unavailable(reason: .noVO2MaxSource))
    }
}
