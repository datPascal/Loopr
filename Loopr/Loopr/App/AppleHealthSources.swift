import Foundation
import HealthKitBridge

/// Answers whether the person left a source read on. The Apple Health runtime
/// is the live gate; tests pass a fixed one.
nonisolated protocol AppleHealthSourceGating: Sendable {
    func allowsSource(_ kind: AppleHealthSourceKind) async -> Bool
}

/// The app's way to read the eight Apple Health kinds (DEC-12.16) with their
/// source. Today, Fitness and Data ask this service. It reads only, and a read
/// the person switched off comes back absent without touching Apple Health.
nonisolated struct AppleHealthSources: Sendable {
    /// Cardio Age uses the median of VO₂ max samples over this many days
    /// (LOOPR_AGE.md, Cardio Age).
    static let cardioWindowDays = 42

    let makeReader: @Sendable () -> any AppleHealthSourceReading
    let gate: any AppleHealthSourceGating

    init(gate: any AppleHealthSourceGating,
         makeReader: @escaping @Sendable () -> any AppleHealthSourceReading = AppleHealthSources.liveReader) {
        self.gate = gate
        self.makeReader = makeReader
    }

    /// Reads one kind over a window.
    func read(_ kind: AppleHealthSourceKind, from start: Date, to end: Date) async -> AppleHealthReadResult {
        guard await gate.allowsSource(kind) else { return .absent(.switchedOff) }
        return await makeReader().read(kind, from: start, to: end)
    }

    /// Reads one kind over the last `days` days up to `now`.
    func read(_ kind: AppleHealthSourceKind, lastDays days: Int, endingAt now: Date,
              calendar: Calendar = .current) async -> AppleHealthReadResult {
        guard days > 0, let start = calendar.date(byAdding: .day, value: -days, to: now) else { return .absent(.noSamples) }
        return await read(kind, from: start, to: now)
    }

    /// The VO₂ max samples Cardio Age uses: the last 42 days, each with its source.
    func cardioVO2Max(endingAt now: Date) async -> AppleHealthReadResult {
        await read(.vo2Max, lastDays: Self.cardioWindowDays, endingAt: now)
    }

    /// Data's Sources section: every kind's latest sample or absent reason, and
    /// one line per source. Daily kinds read the last `dailyDays` days, which
    /// is enough to find the latest day; the rest read `lastDays`.
    func sourceSummary(endingAt now: Date, lastDays: Int = 365, dailyDays: Int = 14,
                       calendar: Calendar = .current) async -> AppleHealthSourceSummary {
        var results: [AppleHealthSourceKind: AppleHealthReadResult] = [:]
        for kind in AppleHealthSourceKind.allCases {
            results[kind] = await read(kind, lastDays: kind.isDailyAggregate ? dailyDays : lastDays,
                                       endingAt: now, calendar: calendar)
        }
        return AppleHealthSourceSummaryBuilder.build(results: results)
    }

    /// A reader on the device's current calendar and clock. It is built per
    /// read, so a change of time zone shows in the next read's days. Samples
    /// Loopr wrote itself are left out.
    @Sendable static func liveReader() -> any AppleHealthSourceReading {
        #if canImport(HealthKit)
        let store: any AppleHealthSourceStore = LiveAppleHealthSourceStore()
        #else
        let store: any AppleHealthSourceStore = UnavailableAppleHealthSourceStore()
        #endif
        return AppleHealthSourceReader(store: store, calendar: .current, clock: { Date() },
                                       excludingBundlePrefixes: MetricHistoryHealth.ownBundlePrefixes)
    }
}
