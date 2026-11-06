import DomainKit
import Foundation
@testable import RoutineKit

/// Shared inputs for the experiment tests. Fixed ids and dates, so a run never depends on the clock or on chance.
enum ExpFixtures {
    static let experimentID = ExperimentID(rawValue: UUID(uuidString: "6F1A2B3C-0000-4000-8000-000000000007")!)
    static let protocolID = ProtocolID(rawValue: UUID(uuidString: "6F1A2B3C-0000-4000-8000-0000000000A1")!)
    static let createdAt = Date(timeIntervalSince1970: 1_760_000_000)
    static let startDay = day(2026, 10, 12)

    static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> DayIdentity {
        DayIdentity(year: year, month: month, day: dayOfMonth)
    }

    /// The day `offset` civil days after night 1.
    static func night(_ offset: Int, from start: DayIdentity = startDay) -> DayIdentity { start.adding(days: offset)! }

    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    static func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    static func start(id: ExperimentID = experimentID, design: ExperimentDesign = .alternatingDays, washout: Int = 0,
                      minimum: Int = 3, planned: Int = 14, outcome: ExperimentMetric = .deepSleep,
                      startDay: DayIdentity = startDay, name: String = "magnesium",
                      timeZone: String = "Europe/Berlin") throws -> ExperimentStart {
        try ExperimentStart(id: id, protocolID: protocolID, title: "Magnesium glycinate, 300 mg", interventionName: name,
                            ruleKey: "magnesium", design: design, washout: washout, minimumNightsPerArm: minimum,
                            plannedNights: planned, outcome: outcome, startDay: startDay, timeZoneIdentifier: timeZone,
                            createdAt: createdAt)
    }

    static func experiment(id: ExperimentID = experimentID, design: ExperimentDesign = .alternatingDays, washout: Int = 0,
                           minimum: Int = 3, planned: Int = 14, outcome: ExperimentMetric = .deepSleep,
                           status: ExperimentStatus = .running, endDay: DayIdentity? = nil) throws -> Experiment {
        Experiment(start: try start(id: id, design: design, washout: washout, minimum: minimum, planned: planned,
                                    outcome: outcome), status: status, endDay: endDay)
    }

    /// Fourteen baseline nights whose back-to-back differences are 4, -5, 6, -5, 3, -5, 6, -3, 1, -5, 8, -5, 3. Their
    /// median is 1 and the median absolute deviation is exactly 5.
    static let baselineValues: [Double] = [50, 54, 49, 55, 50, 53, 48, 54, 51, 52, 47, 55, 50, 53]
    static let baselineMAD = 5.0
    /// 5 times 1.4826 over the square root of two.
    static var baselineSpread: Double { baselineMAD * 1.4826 / 2.0.squareRoot() }

    /// Baseline nights ending the day before `startDay`, in order, scaled by `scale`.
    static func baseline(values: [Double] = baselineValues, scale: Double = 1, before startDay: DayIdentity = startDay) -> [DayIdentity: Double] {
        var result: [DayIdentity: Double] = [:]
        for (index, value) in values.enumerated() {
            result[startDay.adding(days: index - values.count)!] = value * scale
        }
        return result
    }

    /// One stored night per scheduled night, in order. Washout nights get an absurd value so a test proves they are
    /// ignored. `through` limits how many nights are produced.
    static func nights(for experiment: Experiment, on: [Double], off: [Double], through: Int? = nil,
                       adherence: ExperimentAdherence = .kept) throws -> [ExperimentNight] {
        var onValues = on[...], offValues = off[...]
        var result: [ExperimentNight] = []
        for scheduled in experiment.schedule.nights.prefix(through ?? .max) {
            let arm: ExperimentArm, washout: Bool, value: Double?
            switch scheduled.role {
            case .on: arm = .on; washout = false; value = onValues.popFirst()
            case .off: arm = .off; washout = false; value = offValues.popFirst()
            case .washout(let washoutArm): arm = washoutArm; washout = true; value = 9_999
            case .outside: continue
            }
            result.append(try ExperimentNight(experimentID: experiment.id, day: scheduled.day, arm: arm, isWashout: washout,
                                              adherence: adherence, outcomeValue: value, recordedAt: createdAt))
        }
        return result
    }

    static func report(_ experiment: Experiment, nights: [ExperimentNight], baseline: [DayIdentity: Double]? = nil,
                       otherBaselines: [String: [DayIdentity: Double]] = [:], alsoMetrics: [ExperimentMetric] = [],
                       lastNight: DayIdentity? = nil) -> ExperimentReport {
        ExperimentAnalyzer.report(
            experiment: experiment, nights: nights, baseline: baseline ?? Self.baseline(),
            otherBaselines: otherBaselines, alsoMetrics: alsoMetrics,
            lastNight: lastNight ?? experiment.start.lastPlannedDay)
    }

    // Seven values per arm, built to land in one verdict each. The baseline spread is about 5.24.
    static let clearOn: [Double] = [80, 82, 78, 81, 79, 80, 80]
    static let clearOff: [Double] = [60, 62, 58, 61, 59, 60, 60]
    static let sameOn: [Double] = [60, 61, 59, 60, 62, 58, 60]
    static let sameOff: [Double] = [60, 59, 61, 60, 58, 62, 60]
    /// Mean 66.4 against 60: beyond the spread, but with swings that leave the range reaching into the band.
    static let noisyOn: [Double] = [90, 50, 80, 40, 85, 45, 75]
    static let steadyOff: [Double] = [60, 62, 58, 61, 59, 60, 60]
    /// Mean 66, about the same as `noisyOn`'s 66.4.
    static let level66Off: [Double] = [66, 67, 65, 66, 64, 68, 66]
}
