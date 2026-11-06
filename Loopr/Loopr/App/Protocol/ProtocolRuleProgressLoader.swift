import DomainKit
import Foundation
import RoutineKit

/// Reads how far each rule with a longer period has come, for the Rules list (ICP R1-VET-08, R1-VET-23): the week's
/// ticks of a weekly or "N times a week" rule, the week's amount of a weekly rule a source checks, and when a rule every
/// few weeks or months was last done. `RuleProgressReader` decides; this only fetches what it needs. A source that
/// cannot be read leaves its days out, so nothing unmeasured reads as zero.
nonisolated enum ProtocolRuleProgressLoader {
    static func progress(store: RoutineStore, protocolID: ProtocolID, rules: [ProtocolRule], week: [DayIdentity],
                         today: DayIdentity, timeZone: TimeZone, now: Date,
                         snapshots: @Sendable (DayIdentity, TimeZone, Date) async throws -> RoutineSourceSnapshots) async
        -> [RuleKey: RuleProgress] {
        let longer = rules.filter(RuleProgressReader.hasProgress)
        guard !longer.isEmpty else { return [:] }
        let todayKey = today.routineDayKey ?? ""
        let soFar = week.filter { ($0.routineDayKey ?? "") <= todayKey }
        var readings: [DayIdentity: RoutineSourceSnapshots] = [:]
        if longer.contains(where: RuleProgressReader.needsReadings) {
            for day in soFar {
                if Task.isCancelled { break }
                if let snapshot = try? await snapshots(day, timeZone, now) { readings[day] = snapshot }
            }
        }
        var result: [RuleKey: RuleProgress] = [:]
        for rule in longer {
            let history = (try? store.history(protocolID: protocolID, ruleKey: rule.key, through: today)) ?? []
            if let progress = RuleProgressReader.progress(for: rule, week: soFar, history: history, readings: readings) {
                result[rule.key] = progress
            }
        }
        return result
    }
}
