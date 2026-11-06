import DomainKit
import Foundation
import JournalKit
import RoutineKit

/// Experiments for the Experiments segment tests. Night 1 of the running one is Mon 6 Nov 2023, and the last night
/// that is over is Mon 13 Nov, so it is at night 9 of 14, as in the contract.
enum ProtocolExperimentTestData {
    static let protocolID = ProtocolID(rawValue: UUID(uuidString: "6F1A2B3C-0000-4000-8000-0000000000B1")!)
    static let createdAt = Date(timeIntervalSince1970: 1_699_000_000)
    static func day(_ month: Int, _ value: Int) -> DayIdentity { DayIdentity(year: 2023, month: month, day: value) }
    static let lastNight = day(11, 13)

    /// 28 nights before `startDay` whose night-to-night spread reads exactly `spread`: back-to-back differences of one
    /// 0 and then plus and minus m in turn have a median of 0 and a median absolute deviation of m.
    static func baseline(mean: Double, spread: Double, before startDay: DayIdentity) -> [DayIdentity: Double] {
        let step = spread * 2.0.squareRoot() / 1.4826
        var result: [DayIdentity: Double] = [:]
        var value = mean - step / 2
        for index in 0..<28 {
            if index >= 2 { value += index % 2 == 0 ? step : -step }
            result[startDay.adding(days: index - 28)!] = value
        }
        return result
    }

    static func start(name: String = "magnesium", title: String = "Magnesium glycinate, 300 mg", startDay: DayIdentity,
                      planned: Int, minimum: Int, design: ExperimentDesign = .alternatingDays, washout: Int = 0,
                      outcome: ExperimentMetric = .deepSleep) throws -> ExperimentStart {
        try ExperimentStart(protocolID: protocolID, title: title, interventionName: name, ruleKey: RuleKey(rawValue: name),
                            design: design, washout: washout, minimumNightsPerArm: minimum, plannedNights: planned,
                            outcome: outcome, startDay: startDay, timeZoneIdentifier: "UTC", createdAt: createdAt)
    }

    /// One stored night per scheduled night with a value, on values and off values in night order. `override` replaces a
    /// night by its 1-based number.
    static func nights(_ experiment: Experiment, on: [Double], off: [Double],
                       override: [Int: (ExperimentAdherence, Double?)] = [:]) throws -> [ExperimentNight] {
        var onValues = on[...], offValues = off[...]
        var result: [ExperimentNight] = []
        for night in experiment.schedule.nights {
            let arm: ExperimentArm, washout: Bool
            switch night.role {
            case .on: arm = .on; washout = false
            case .off: arm = .off; washout = false
            case .washout(let washoutArm): arm = washoutArm; washout = true
            case .outside: continue
            }
            guard let value = washout ? 999 : (arm == .on ? onValues.popFirst() : offValues.popFirst()) else { continue }
            let (adherence, stored) = override[night.number] ?? (arm == .on ? .kept : .missed, value)
            result.append(try ExperimentNight(experimentID: experiment.id, day: night.day, arm: arm, isWashout: washout,
                                              adherence: adherence, outcomeValue: stored, recordedAt: createdAt))
        }
        return result
    }

    static func item(_ experiment: Experiment, nights: [ExperimentNight], baseline: [DayIdentity: Double],
                     lastNight: DayIdentity = lastNight, keptVersion: Int? = nil, canKeep: Bool = false,
                     otherBaselines: [String: [DayIdentity: Double]] = [:],
                     alsoMetrics: [ExperimentMetric] = []) -> ProtocolExperimentItem {
        let report = ExperimentAnalyzer.report(experiment: experiment, nights: nights, baseline: baseline,
                                               otherBaselines: otherBaselines, alsoMetrics: alsoMetrics, lastNight: lastNight)
        return ProtocolExperimentItem(experiment: experiment, report: report, nights: nights, keptVersion: keptVersion,
                                      canKeep: canKeep)
    }

    /// Magnesium at night 9 of 14, 4 nights on at 86, 81, 90 and 79 (average 84) and 4 off at 76, 82, 74 and 80
    /// (average 78), against a spread of 9.
    static func running(minimum: Int = 7) throws -> ProtocolExperimentItem {
        let startDay = day(11, 6)
        let experiment = Experiment(start: try start(startDay: startDay, planned: 14, minimum: minimum))
        return item(experiment, nights: try nights(experiment, on: [86, 81, 90, 79], off: [76, 82, 74, 80]),
                    baseline: baseline(mean: 78, spread: 9, before: startDay))
    }

    static let clearOn: [Double] = [80, 82, 78, 81, 79, 80, 80]
    static let clearOff: [Double] = [60, 62, 58, 61, 59, 60, 60]
    static let sameOn: [Double] = [60, 61, 59, 60, 62, 58, 60]
    static let sameOff: [Double] = [60, 59, 61, 60, 58, 62, 60]

    /// A finished 14-night alternating experiment, minimum 3, against a spread of 5.
    static func finished(on: [Double] = clearOn, off: [Double] = clearOff, status: ExperimentStatus = .finished,
                         endNight: Int = 14, keptVersion: Int? = nil, canKeep: Bool = false) throws -> ProtocolExperimentItem {
        let startDay = day(10, 1)
        let plan = try start(startDay: startDay, planned: 14, minimum: 3)
        let experiment = Experiment(start: plan, status: status, endDay: startDay.adding(days: endNight - 1))
        return item(experiment, nights: try nights(experiment, on: on, off: off), baseline: baseline(mean: 60, spread: 5, before: startDay),
                    keptVersion: keptVersion, canKeep: canKeep)
    }
}
