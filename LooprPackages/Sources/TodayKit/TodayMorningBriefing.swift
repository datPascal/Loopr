import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation

/// Deterministic wording shared by Today, its snapshot headline and the recap.
public enum TodayMorningSentence {
    public enum Signal: String, CaseIterable, Sendable { case hrv, restingHeartRate, breathing }
    public struct Driver: Equatable, Sendable {
        public let signal: Signal
        public let change: Double
        public let contribution: Double
        public init(signal: Signal, change: Double, contribution: Double) {
            self.signal = signal; self.change = change; self.contribution = contribution
        }
    }

    public static func make(score: Double, drivers: [Driver], sleepMinutes: Double?, sleepNeed: Double?) -> String {
        guard score.isFinite, (0...100).contains(score) else { return "Recovery needs at least two overnight heart readings with enough history." }
        let shown = score.rounded()
        let positive = shown >= 50
        // Do not name a direction hidden by the printed precision, or a term
        // whose direction disagrees with the value shown beside the hero.
        let eligible = drivers.filter { driver in
            let precision = driver.signal == .breathing ? 10.0 : 1.0
            let change = (driver.change * precision).rounded() / precision
            let goodSign = driver.signal == .hrv ? 1.0 : -1.0
            return change.isFinite && driver.contribution.isFinite && change != 0
                && driver.contribution != 0 && (driver.contribution > 0) == positive
                && (change * goodSign > 0) == (driver.contribution > 0)
        }.sorted {
            abs($0.contribution) == abs($1.contribution)
                ? $0.signal.rawValue < $1.signal.rawValue : abs($0.contribution) > abs($1.contribution)
        }
        var seen: Set<Signal> = []
        let chosen = eligible.filter { seen.insert($0.signal).inserted }.prefix(2)
        let clauses = chosen.map { driver in
            let higher = driver.change > 0
            return switch driver.signal {
            case .hrv: "\(higher ? "higher" : "lower") HRV"
            case .restingHeartRate: "a \(higher ? "higher" : "lower") resting heart rate"
            case .breathing: "a \(higher ? "higher" : "lower") breathing rate"
            }
        }
        let shortSleep = sleepMinutes.flatMap { minutes in
            sleepNeed.map { need in minutes.isFinite && need.isFinite && minutes > 0 && need > 0 && need - minutes >= 60 }
        } ?? false
        guard !clauses.isEmpty else {
            return shortSleep ? "Sleep fell short of your need; this score reflects your overnight heart readings."
                : "This score reflects the available overnight heart readings."
        }
        let subject = clauses.joined(separator: " and ")
        let verb = positive ? "supported" : "lowered"
        if shortSleep, !positive { return "Sleep was short, and \(subject) \(verb) this score." }
        let capitalized = subject.prefix(1).uppercased() + subject.dropFirst()
        return shortSleep ? "\(capitalized) \(verb) this score, while sleep fell short of your need."
            : "\(capitalized) \(verb) this score."
    }

    public static func plan(range: ClosedRange<Double>?, adjustment: StrainTarget.Adjustment? = nil) -> String? {
        guard let range, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.upperBound <= 21 else { return nil }
        let low = Int(range.lowerBound.rounded()), high = Int(range.upperBound.rounded())
        let reason = switch adjustment {
        case .heavy: " The range is lower after a heavy week."
        case .lighter: " A lighter week leaves more room today."
        case nil: ""
        }
        return "Keep strain between \(low) and \(high) today." + reason
    }
}
