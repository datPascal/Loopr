import DomainKit
import Foundation

/// Writes the weekly review locally and deterministically from what is already
/// stored. Same input, same text. It only mentions patterns that passed the
/// strength gate (strong or clear) and are not dismissed, and it never claims cause.
public struct WeeklyReviewBuilder: Sendable {
    public static let maxPatterns = 2

    public init() {}

    /// - Parameters:
    ///   - weekStartDay: first day of the review week; the week is seven days.
    ///   - found: found patterns, any strength. Early ones are left out.
    ///   - dismissedKeys: keys of dismissed patterns, which stay out of the review.
    ///   - tests: all tests; a running test and a test that ended this week are mentioned.
    ///   - verdicts: the latest verdict per test, when the caller has computed one.
    public func build(
        weekStartDay: String,
        found: [FoundPattern],
        dismissedKeys: Set<String> = [],
        tests: [PatternTest] = [],
        verdicts: [UUID: PatternTestVerdict] = [:],
        now: Date
    ) -> WeeklyReview {
        let weekEnd = PatternDays.add(6, to: weekStartDay) ?? weekStartDay
        let patterns = PatternDiscoveryEngine.ordered(found)
            .filter { $0.strength.isHeadlineWorthy && !dismissedKeys.contains($0.key) }
            .prefix(Self.maxPatterns)
        var paragraphs: [String] = []
        var mentionsEvidence = false

        for (index, pattern) in patterns.enumerated() {
            let lead = index == 0 ? "" : "A second pattern. "
            paragraphs.append("\(lead)\(pattern.summary) That comes from \(pattern.nights.with) nights with and \(pattern.nights.without) without.")
            mentionsEvidence = true
        }

        let relevant = tests
            .filter { test in
                switch test.state {
                case .running: true
                case .completed: test.endDay >= weekStartDay && test.endDay <= weekEnd
                case .stopped: false
                }
            }
            .sorted { ($0.startDay, $0.id.uuidString) < ($1.startDay, $1.id.uuidString) }
        for test in relevant {
            let progress = test.progress(at: now)
            if test.state == .running && !progress.isOver {
                paragraphs.append("Your \(test.testDays)-day test \"\(test.title)\" is on day \(progress.dayNumber). You kept \(progress.keptCount) of \(progress.elapsedDays) nights.")
                continue
            }
            guard let verdict = verdicts[test.id] else {
                paragraphs.append("Your \(test.testDays)-day test \"\(test.title)\" has ended.")
                continue
            }
            if verdict.isConclusive {
                let body = verdict.detail.replacingOccurrences(of: " " + PatternTestVerdict.footnote, with: "")
                paragraphs.append("Your \(test.testDays)-day test \"\(test.title)\" has ended. \(body)")
                mentionsEvidence = true
            } else {
                paragraphs.append("Your \(test.testDays)-day test \"\(test.title)\" has ended with too few nights to tell.")
            }
        }

        if paragraphs.isEmpty {
            paragraphs.append(PatternCopy.foundEmpty)
        } else if mentionsEvidence {
            paragraphs.append(PatternCopy.footnote)
        }

        return WeeklyReview(
            weekStartDay: weekStartDay, weekEndDay: weekEnd, text: paragraphs.joined(separator: "\n\n"),
            patternKeys: patterns.map(\.key), testIDs: relevant.map(\.id), generatedAt: now)
    }
}
