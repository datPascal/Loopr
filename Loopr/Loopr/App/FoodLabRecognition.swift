import AnalyticsKit
import CoreGraphics
import FoodKit
import Foundation
import PDFKit
import UIKit
import Vision

/// One piece of text Vision read on a lab report page: its top candidate, its box and how sure Vision was.
/// The box keeps Vision's convention, normalised to the page with its origin at the bottom left.
nonisolated struct FoodLabObservation: Sendable, Equatable {
    let text: String
    let box: CGRect
    let confidence: Double
}

/// Turns text recognition into the lines `LabReportParser` reads. Everything runs on this iPhone.
///
/// Low-confidence lines are kept, not dropped: the parser marks their values for a look, so a hard-to-read value
/// waits for the person instead of disappearing.
nonisolated enum FoodLabRecognition {
    /// The parser's lines from Vision's observations. A box is clamped to the page and a confidence to 0...1;
    /// blank text and boxes that are not on the page are left out.
    static func lines(from observations: [FoodLabObservation]) -> [LabTextLine] {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return observations.compactMap { observation in
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = observation.box
            guard !text.isEmpty, [raw.minX, raw.minY, raw.width, raw.height].allSatisfy(\.isFinite) else { return nil }
            let box = raw.standardized.intersection(unit)
            guard !box.isNull, box.height > 0 else { return nil }
            let confidence = observation.confidence.isFinite ? min(max(observation.confidence, 0), 1) : 0
            return LabTextLine(text: text, minX: Double(box.minX), minY: Double(box.minY), width: Double(box.width),
                               height: Double(box.height), confidence: confidence)
        }
    }

    /// One Vision observation as its top candidate. Nil when Vision gave no candidate.
    static func observation(_ recognized: RecognizedTextObservation) -> FoodLabObservation? {
        guard let candidate = recognized.topCandidates(1).first else { return nil }
        return FoodLabObservation(text: candidate.string, box: recognized.boundingBox.cgRect, confidence: Double(candidate.confidence))
    }

    /// Reads a report page with Vision, in English and German.
    static func lines(in page: CGImage) async throws -> [LabTextLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "de-DE")]
        let observations = try await request.perform(on: page)
        return lines(from: observations.compactMap(Self.observation))
    }
}

/// How Lab mode gets from a photo to text lines. `vision` lifts the page and reads it on this iPhone. Fixture
/// launches and tests pass their own.
nonisolated struct FoodLabReader: Sendable {
    /// Lifts the report page out of the photo bytes. Nil when the photo cannot be decoded.
    var lift: @Sendable (Data) async -> FoodLensReport?
    /// Reads the lifted page's text lines.
    var recognize: @Sendable (FoodLensReport?) async throws -> [LabTextLine]

    static let vision = FoodLabReader(
        lift: { data in await Task.detached(priority: .userInitiated) { FoodLensArt.report(photo: data) }.value },
        recognize: { report in
            guard let report else { throw FoodLabReadError.noPage }
            return try await FoodLabRecognition.lines(in: report.page)
        })
}

nonisolated enum FoodLabReadError: Error, Equatable {
    /// The photo could not be decoded, so there is no page to read.
    case noPage
}

/// A lab report PDF from the lab's portal, turned into page images the same reader takes. Each page is rendered on
/// this iPhone; nothing leaves it.
nonisolated enum FoodLabPDF {
    /// Pages past this are left out; a blood test report is rarely longer.
    static let maximumPages = 12
    /// The long side of a rendered page, in pixels: sharp enough for small print, small enough for Vision.
    static let longSide: CGFloat = 2_400

    enum Failure: Error, Equatable { case unreadable, noPages }

    /// Renders every page of the PDF at `url` as a JPEG photo dated `capturedAt`. The caller holds any security
    /// scope the URL needs.
    static func pages(at url: URL, capturedAt: Date) throws -> [FoodPhoto] {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
        guard document.pageCount > 0 else { throw Failure.noPages }
        var photos: [FoodPhoto] = []
        for index in 0..<min(document.pageCount, maximumPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let scale = longSide / max(bounds.width, bounds.height)
            let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let data = image.jpegData(compressionQuality: 0.85) else { continue }
            photos.append(try FoodPhoto(type: .jpeg, capturedAt: capturedAt, bytes: data))
        }
        guard !photos.isEmpty else { throw Failure.noPages }
        return photos
    }
}
