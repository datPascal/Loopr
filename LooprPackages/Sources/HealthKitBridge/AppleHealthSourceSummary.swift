import Foundation

// The source summary for Data's Sources section (DEC-12.16, LV-11.2).
//
// Pure: it folds the results of `AppleHealthSourceReading.read` into one value.
// The summary reads and writes nothing, and it has no view.

/// One kind's row: whether it is on, and its latest sample or why there is none.
public struct AppleHealthKindSummary: Equatable, Sendable {
    public let kind: AppleHealthSourceKind
    /// False when the person switched this read off in Loopr.
    public let isEnabled: Bool
    /// The most recent sample, with its value, date and source.
    public let latest: AppleHealthSample?
    /// Why there is no sample. Nil exactly when `latest` is set.
    public let absence: AppleHealthAbsence?

    public init(kind: AppleHealthSourceKind, isEnabled: Bool, latest: AppleHealthSample?, absence: AppleHealthAbsence?) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.latest = latest
        self.absence = absence
    }

    /// The date of the latest sample: its end.
    public var date: Date? { latest?.end }
    /// The name of the app or device that wrote the latest sample.
    public var sourceLabel: String? { latest?.provenance.label }
}

/// One line per distinct source app or device, with what it supplied.
public struct AppleHealthSourceLine: Equatable, Sendable {
    /// The label shown to the person, for example "Apple Watch" or "Withings".
    public let label: String
    /// The kinds this source supplied in the read window, in `allCases` order.
    public let kinds: [AppleHealthSourceKind]
    /// The end of the newest sample this source supplied.
    public let lastSeen: Date

    public init(label: String, kinds: [AppleHealthSourceKind], lastSeen: Date) {
        self.label = label
        self.kinds = kinds
        self.lastSeen = lastSeen
    }
}

public struct AppleHealthSourceSummary: Equatable, Sendable {
    /// One row per kind, always all eight, in `allCases` order.
    public let kinds: [AppleHealthKindSummary]
    /// Sources that supplied at least one sample, most kinds first, then by label.
    public let sources: [AppleHealthSourceLine]

    public init(kinds: [AppleHealthKindSummary], sources: [AppleHealthSourceLine]) {
        self.kinds = kinds
        self.sources = sources
    }

    public func summary(for kind: AppleHealthSourceKind) -> AppleHealthKindSummary? {
        kinds.first { $0.kind == kind }
    }

    /// The kinds that have a sample.
    public var suppliedKinds: [AppleHealthSourceKind] {
        kinds.filter { $0.latest != nil }.map(\.kind)
    }
}

public enum AppleHealthSourceSummaryBuilder {
    /// A kind with no entry in `results` was not read, and reads as no samples.
    public static func build(results: [AppleHealthSourceKind: AppleHealthReadResult]) -> AppleHealthSourceSummary {
        var rows: [AppleHealthKindSummary] = []
        var perSource: [String: (kinds: Set<AppleHealthSourceKind>, lastSeen: Date)] = [:]

        func note(_ label: String?, kind: AppleHealthSourceKind, seen: Date) {
            guard let label, !label.isEmpty else { return }
            var entry = perSource[label] ?? (kinds: [], lastSeen: seen)
            entry.kinds.insert(kind)
            entry.lastSeen = max(entry.lastSeen, seen)
            perSource[label] = entry
        }

        for kind in AppleHealthSourceKind.allCases {
            let result = results[kind] ?? .absent(.noSamples)
            let latest = result.latest
            let absence = latest == nil ? (result.absence ?? .noSamples) : nil
            rows.append(AppleHealthKindSummary(kind: kind, isEnabled: absence != .switchedOff,
                                               latest: latest, absence: absence))
            for sample in result.samples {
                note(sample.provenance.label, kind: kind, seen: sample.end)
                for name in sample.additionalSourceNames { note(name, kind: kind, seen: sample.end) }
            }
        }

        let lines = perSource.map { label, entry in
            AppleHealthSourceLine(label: label, kinds: AppleHealthSourceKind.allCases.filter(entry.kinds.contains),
                                  lastSeen: entry.lastSeen)
        }
        .sorted { ($1.kinds.count, $0.label) < ($0.kinds.count, $1.label) }
        return AppleHealthSourceSummary(kinds: rows, sources: lines)
    }
}
