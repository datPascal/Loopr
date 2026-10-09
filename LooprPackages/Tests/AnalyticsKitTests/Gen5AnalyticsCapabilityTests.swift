import XCTest
@testable import AnalyticsKit

final class Gen5SubstrateFeedTests: XCTestCase {
    func testOnlyValidatedFieldsReachBandAgnosticPipeline() {
        let source = Gen5ValidatedSubstrate(
            timestamp: 1_780_916_150, index: 25_443_699, heartRate: 102,
            rrMilliseconds: [602, 613], gravity: SIMD3(-0.7252, 0.4944, 0.4969)
        )
        let mapped = Gen5SubstrateMapper.heartInput(from: source)
        XCTAssertEqual(mapped, BandAgnosticHeartInput(
            timestamp: source.timestamp,
            heartRate: source.heartRate,
            rrMilliseconds: source.rrMilliseconds
        ))
        XCTAssertEqual(Set(Mirror(reflecting: source).children.compactMap(\.label)),
                       ["timestamp", "index", "heartRate", "rrMilliseconds", "gravity"])
    }
}

final class Gen5AnalyticsParityTests: XCTestCase {
    func testRealV18CaptureUsesCanonicalPresenceAndRoundingRules() {
        let capture = Gen5ValidatedSubstrate(
            timestamp: 1_780_916_150, index: 25_443_699, heartRate: 102,
            rrMilliseconds: [602, 613], gravity: SIMD3(-0.7252, 0.4944, 0.4969)
        )
        let gen5 = Gen5SubstrateMapper.heartInput(from: capture)
        let equivalentGen4 = BandAgnosticHeartInput(
            timestamp: 1_780_916_150, heartRate: 102, rrMilliseconds: [602, 613]
        )
        XCTAssertEqual(gen5, equivalentGen4)
        XCTAssertEqual(gen5.rrMilliseconds.map(Int.init).reduce(0, +), 1215)
    }
}

final class Gen5CapabilityBadgeUITests: XCTestCase {
    func testFourStatesRenderDistinctlyWithProvenanceAndBetaBadge() {
        let projections = Gen5SurfaceCapability.allCases.map {
            Gen5MetricSurfaceProjection(modelLabel: "WHOOP 5.0", firmware: "50.38.1.0", capability: $0, value: nil)
        }
        XCTAssertEqual(Set(projections.map(\.capability)).count, 4)
        XCTAssertTrue(projections.allSatisfy { $0.modelLabel == "WHOOP 5.0" })
        XCTAssertTrue(projections.allSatisfy { $0.firmware == "50.38.1.0" })
        XCTAssertTrue(projections.allSatisfy { $0.betaBadge == "Experimental Beta" })
    }
}

final class Gen5UnsupportedMetricAbsenceTests: XCTestCase {
    func testUnavailableValueIsAbsentNeverZeroOrSubstituted() {
        let projection = Gen5MetricSurfaceProjection(
            modelLabel: "WHOOP 5.0", firmware: "unknown",
            capability: .connected, value: nil
        )
        XCTAssertNil(projection.value)
        XCTAssertNotNil(projection.unavailableReason)
    }
}

final class Gen5CandidateMetricExportBlockTests: XCTestCase {
    func testEveryCandidateMetricHasNoExportShareOrHealthWritePath() {
        for metric in Gen5CandidateMetric.allCases {
            XCTAssertFalse(Gen5ExportPolicy.permits(metric))
            XCTAssertFalse(Gen5ExportPolicy.allowedFields.contains(metric.rawValue))
        }
    }
}
