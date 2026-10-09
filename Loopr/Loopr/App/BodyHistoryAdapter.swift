import BodyKit
import DomainKit
import Foundation

/// Reads the Body tab's history from the metric history: strain and recovery
/// for the week and the training load, steps and active energy for "vs usual".
///
/// Four indexed reads of 92 days each, once per day change (and again when
/// the day's numbers change), never per render.
nonisolated struct MetricHistoryBodyProvider: BodyHistoryProviding {
    let provider: any MetricHistoryProviding
    var calendar: Calendar = .current

    func bodyHistory(anchor: DayIdentity) async -> BodyHistory {
        guard let anchorDate = anchor.bodyDate(calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: anchorDate) else { return .empty(anchor: anchor) }
        // The provider includes its ending day: 90 prior days, the anchor,
        // and the following morning need 92 calendar slots.
        let count = BodyHistory.lookbackDays + 2
        async let strain = values(.strain, days: count, endingOn: end, bandOnly: false)
        async let recovery = values(.recovery, days: count, endingOn: end, bandOnly: false)
        // Steps and energy on this screen are the band's estimates, so their
        // usual comes from the band too, never from Apple Health counts.
        async let steps = values(.steps, days: count, endingOn: end, bandOnly: true)
        async let energy = values(.activeEnergy, days: count, endingOn: end, bandOnly: true)
        return Self.merge(anchor: anchor, strain: await strain, recovery: await recovery, steps: await steps, energy: await energy)
    }

    private func values(_ key: MetricKey, days: Int, endingOn end: Date, bandOnly: Bool) async -> [DayIdentity: Double] {
        let points = (try? await provider.series(for: key, days: days, endingOn: end)) ?? []
        var result: [DayIdentity: Double] = [:]
        for point in points where point.value.isFinite && (!bandOnly || point.source == .band) {
            result[DayIdentity(bodyDate: point.day, calendar: calendar)] = point.value
        }
        return result
    }

    static func merge(anchor: DayIdentity, strain: [DayIdentity: Double], recovery: [DayIdentity: Double],
                      steps: [DayIdentity: Double], energy: [DayIdentity: Double]) -> BodyHistory {
        let days = Set(strain.keys).union(recovery.keys).union(steps.keys).union(energy.keys)
        return BodyHistory(anchor: anchor, days: days.map { day in
            BodyHistoryDay(day: day, strain: strain[day], recovery: recovery[day], steps: steps[day], activeEnergy: energy[day])
        })
    }
}

/// Which history the Body screens read: the metric history for a real store,
/// the shared fixture story for fixture launches, nothing otherwise.
enum BodyHistorySource {
    static func provider(repositories: ProductRepositoryContainer?, composition: AppEnvironment.Composition,
                         metricHistory: any MetricHistoryProviding) -> (any BodyHistoryProviding)? {
        #if DEBUG
        if let fixture = DebugCaptureFixtures.siBodyHistoryProvider { return fixture }
        #endif
        if repositories?.persistent != nil {
            return MetricHistoryBodyProvider(provider: metricHistory)
        }
        guard repositories?.isFixtureComposition != false else { return nil }
        let state = ProductFixture.metricState(for: composition)
        let hasValues = BodyFixtures.snapshot(for: state).metric(.strain)?.value != nil
        return BodyFixtureHistoryProvider(hasValues: hasValues)
    }
}
