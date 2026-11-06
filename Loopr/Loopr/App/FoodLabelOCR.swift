import FoodKit
import SwiftUI
import Vision

nonisolated enum FoodLabelOCR {
    static func text(from data: Data) async throws -> String {
        let request = RecognizeTextRequest()
        let observations = try await request.perform(on: data)
        // Join candidates on the same baseline before parsing each nutrition row.
        let rows = observations.compactMap { observation -> (String, CGRect)? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.35 else { return nil }
            return (candidate.string, observation.boundingBox.cgRect)
        }.sorted { $0.1.midY > $1.1.midY }
        var groups: [[(String, CGRect)]] = []
        for row in rows {
            if let last = groups.last, let first = last.first, abs(first.1.midY - row.1.midY) <= min(first.1.height, row.1.height) * 0.5 {
                groups[groups.count - 1].append(row)
            } else { groups.append([row]) }
        }
        return groups.map { $0.sorted { $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ") }.joined(separator: "\n")
    }
}
