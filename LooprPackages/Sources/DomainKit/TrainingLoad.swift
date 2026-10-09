import Foundation

/// Daily strain smoothed over 42 days and 7 days. Missing days break the run.
/// Context for training, never an input to a recovery score.
public struct TrainingLoad: Equatable, Hashable, Codable, Sendable {
    public static let algorithmVersion = "loopr.training-load.1"
    public static let minimumDays = 14
    public static let establishedDays = 42
    public let fitness: Double
    public let fatigue: Double
    public let days: Int
    public var form: Double { fitness - fatigue }
    public var ratio: Double? { fitness > 0 ? fatigue / fitness : nil }
    public var relativeForm: Double? { fitness > 0 ? form / fitness : nil }
    public var isEstablished: Bool { days >= Self.establishedDays }

    public init(fitness: Double, fatigue: Double, days: Int) {
        self.fitness = fitness; self.fatigue = fatigue; self.days = days
    }

    /// Oldest first, one entry per civil day. A recorded zero is a rest day;
    /// an absent or invalid entry resets the history instead of inventing rest.
    public static func contiguousDays(_ dailyStrain: [Double?]) -> [Double] {
        var run: [Double] = []
        for value in dailyStrain {
            guard let value, value.isFinite, (0...21).contains(value) else { run.removeAll(); continue }
            run.append(value)
        }
        return run
    }

    /// Seven-day mean prime, then exponential updates with 42- and 7-day
    /// time constants. The descriptive model follows the Banister approach
    /// documented in OpenStrap analytics clinical/load_trimp.dart, MIT.
    public static func compute(dailyStrain: [Double?]) -> TrainingLoad? {
        let run = contiguousDays(dailyStrain)
        guard run.count >= minimumDays else { return nil }
        let seed = run.prefix(7).reduce(0, +) / 7
        var fitness = seed, fatigue = seed
        for value in run.dropFirst(7) {
            fitness += (1 - exp(-1.0 / 42)) * (value - fitness)
            fatigue += (1 - exp(-1.0 / 7)) * (value - fatigue)
        }
        return TrainingLoad(fitness: fitness, fatigue: fatigue, days: run.count)
    }
}
