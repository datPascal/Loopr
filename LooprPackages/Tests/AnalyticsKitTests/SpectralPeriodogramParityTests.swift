import XCTest
import Foundation
@testable import AnalyticsKit

/// The periodogram was rewritten to run against raw buffers and to split its
/// frequencies across cores. Neither is allowed to move a number, so pin one
/// spectrum against a straightforward reference implementation.
final class SpectralPeriodogramParityTests: XCTestCase {
    func testPeriodogramMatchesTheDirectSineAndCosineReference() throws {
        var times: [Double] = []
        var values: [Double] = []
        var clock = 0.0
        for index in 0..<400 {
            clock += 0.82 + 0.08 * sin(2 * Double.pi * 0.25 * Double(index))
            times.append(clock)
            values.append(1_000 * (0.82 + 0.08 * sin(2 * Double.pi * 0.25 * Double(index))))
        }
        let frequencies = SpectralAnalysis.frequencyGrid(lower: 0.15, upper: 0.4, count: 64)
        let spectrum = try XCTUnwrap(SpectralAnalysis.lombScargle(times: times, values: values, frequencies: frequencies))
        let reference = Self.reference(times: times, values: values, frequencies: frequencies)
        XCTAssertEqual(spectrum.points.count, reference.count)
        for index in spectrum.points.indices {
            XCTAssertEqual(spectrum.points[index].power.bitPattern, reference[index].bitPattern,
                           "frequency \(frequencies[index]) drifted")
        }
    }

    private static func reference(times: [Double], values: [Double], frequencies: [Double]) -> [Double] {
        let average = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - average }
        let variance = centered.reduce(0) { $0 + $1 * $1 } / Double(times.count - 1)
        return frequencies.map { frequency in
            let angular = 2 * Double.pi * frequency
            guard angular != 0 else { return 0 }
            var sineTwice = 0.0
            var cosineTwice = 0.0
            for time in times {
                sineTwice += sin(2 * angular * time)
                cosineTwice += cos(2 * angular * time)
            }
            let tau = atan2(sineTwice, cosineTwice) / (2 * angular)
            var cosineNumerator = 0.0, cosineDenominator = 0.0, sineNumerator = 0.0, sineDenominator = 0.0
            for index in times.indices {
                let argument = angular * (times[index] - tau)
                let cosine = cos(argument)
                let sine = sin(argument)
                cosineNumerator += centered[index] * cosine
                cosineDenominator += cosine * cosine
                sineNumerator += centered[index] * sine
                sineDenominator += sine * sine
            }
            let termOne = cosineDenominator == 0 ? 0 : cosineNumerator * cosineNumerator / cosineDenominator
            let termTwo = sineDenominator == 0 ? 0 : sineNumerator * sineNumerator / sineDenominator
            return 0.5 * (termOne + termTwo) / variance
        }
    }
}
