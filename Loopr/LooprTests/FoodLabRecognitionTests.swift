import AnalyticsKit
import CoreGraphics
import Foundation
import Testing
@testable import Loopr

/// The adapter from Vision's observations to the parser's lines (LV-05.4).
struct FoodLabRecognitionTests {
    private func close(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-9 }

    @Test func aBoxAndItsConfidenceMapStraightIntoAParserLine() throws {
        let lines = FoodLabRecognition.lines(from: [
            FoodLabObservation(text: "Albumin", box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05), confidence: 0.87)
        ])
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(line.text == "Albumin")
        // Vision's convention is kept: normalised to the page, origin at the bottom left.
        #expect(close(line.minX, 0.1) && close(line.minY, 0.2) && close(line.width, 0.3) && close(line.height, 0.05))
        #expect(close(line.confidence, 0.87))
    }

    @Test func boxesAreClampedToThePageAndTextOffThePageOrBlankIsLeftOut() throws {
        let lines = FoodLabRecognition.lines(from: [
            FoodLabObservation(text: "  Kreatinin  ", box: CGRect(x: -0.1, y: 0.9, width: 0.5, height: 0.2), confidence: 0.9),
            FoodLabObservation(text: "   ", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.02), confidence: 0.9),
            FoodLabObservation(text: "Off the page", box: CGRect(x: 1.5, y: 0.5, width: 0.2, height: 0.1), confidence: 0.9),
            FoodLabObservation(text: "Not a box", box: CGRect(x: CGFloat.nan, y: 0.5, width: 0.2, height: 0.1), confidence: 0.9),
            FoodLabObservation(text: "Flat", box: CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0), confidence: 0.9)
        ])
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(line.text == "Kreatinin")
        #expect(close(line.minX, 0) && close(line.minY, 0.9) && close(line.width, 0.4) && close(line.height, 0.1))
    }

    @Test func confidenceIsClampedAndLowConfidenceTextIsKept() {
        let box = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.02)
        let lines = FoodLabRecognition.lines(from: [
            FoodLabObservation(text: "high", box: box, confidence: 1.4),
            FoodLabObservation(text: "below", box: box, confidence: -0.2),
            FoodLabObservation(text: "unknown", box: box, confidence: .nan),
            FoodLabObservation(text: "faint", box: box, confidence: 0.2)
        ])
        #expect(lines.map(\.text) == ["high", "below", "unknown", "faint"])
        #expect(lines.map(\.confidence) == [1, 0, 0, 0.2])
    }

    @Test func aFaintRowReachesTheParserAndWaitsForALook() throws {
        let y = 0.8
        let cells: [(String, CGFloat, Double)] = [("hs-CRP", 0.05, 0.3), ("0.6", 0.36, 0.3), ("mg/L", 0.53, 0.3), ("< 3.0", 0.7, 0.3),
                                                  ("Albumin", 0.05, 0.97), ("4.6", 0.36, 0.97), ("g/dL", 0.53, 0.97)]
        let observations = cells.enumerated().map { index, cell in
            FoodLabObservation(text: cell.0, box: CGRect(x: cell.1, y: index < 4 ? y : y - 0.03, width: 0.08, height: 0.015),
                               confidence: cell.2)
        }
        let draft = LabReportParser.parse(lines: FoodLabRecognition.lines(from: observations), capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                          timeZone: TimeZone(identifier: "Australia/Perth")!)
        let crp = try #require(draft.values.first { $0.subject == .marker(.crp) })
        #expect(crp.needsReview && crp.scanConfidence == 0.3 && crp.unit == "mg/L")
        let albumin = try #require(draft.values.first { $0.subject == .marker(.albumin) })
        #expect(!albumin.needsReview)
    }
}
