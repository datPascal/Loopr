import Foundation
import RoutineKit

public extension CapacityCadence {
    /// The cadence each test has in the protocol's rules. A rule counts when it is in the Tests group and its
    /// target metric is the test's `ruleMetric` (`capacity_grip`, `capacity_dead_hang`, `capacity_sit_to_stand`,
    /// `capacity_one_leg_balance`). The target's `value` is how many units apart tests fall (1 when absent) and its
    /// `unit` names the unit, so `unit: "month"` is monthly and `value: 3, unit: "months"` is every three months.
    /// The first readable rule per test wins; a test without one has no retest date.
    static func cadences(from rules: [ProtocolRule]) -> [CapacityTestKind: CapacityCadence] {
        var result: [CapacityTestKind: CapacityCadence] = [:]
        for kind in CapacityTestKind.allCases where kind.isRetestable {
            for rule in rules where rule.group == .tests && rule.target.metric == kind.ruleMetric {
                if let cadence = CapacityCadence(count: rule.target.value, unitText: rule.target.unit) {
                    result[kind] = cadence
                    break
                }
            }
        }
        return result
    }
}
