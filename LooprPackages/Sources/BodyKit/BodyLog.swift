import Foundation
import DesignSystem

// The weight and body composition log (LV-08b step 5). Everything here is plain data and rules, so tests pin them
// without drawing: how typed entries and Apple Health samples line up, what a draft must satisfy, how a value shows
// in kilograms or pounds, and which reading is the latest. BodyKit never imports HealthKit or the stores; the app
// maps its stored entries and Apple Health reads into these types.

// MARK: Quantities and sources

public enum BodyLogQuantity: String, CaseIterable, Sendable, Identifiable {
    case weight
    case bodyFat
    case leanMass

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .weight: "Weight"
        case .bodyFat: "Body fat"
        case .leanMass: "Lean mass"
        }
    }
}

/// Where one logged value came from.
public enum BodyLogOrigin: Equatable, Hashable, Sendable {
    /// Typed into Loopr.
    case typed
    /// Read from Apple Health. `sourceName` is the app or device that wrote it, empty when Health gave none.
    /// `typedIntoHealth` is true when the person typed it into Health themselves.
    case appleHealth(sourceName: String, typedIntoHealth: Bool)

    public var isTyped: Bool { self == .typed }

    /// The chip's provenance. Apple Health values keep the writing app's name.
    public var provenance: LooprProvenance {
        switch self {
        case .typed: .typedIn
        case let .appleHealth(sourceName, typedIntoHealth): .appleHealth(source: sourceName, typedIn: typedIntoHealth)
        }
    }
}

/// The ranges an entry may hold. The weight range is the Food weight store's own (`FoodWeightEntry.validRange`);
/// an app test pins that they stay equal, because BodyKit does not depend on FoodKit.
public enum BodyLogLimits {
    public static let weightKilograms: ClosedRange<Double> = 20...400
    public static let bodyFatPercent: ClosedRange<Double> = 2...75
    public static let leanMassKilograms: ClosedRange<Double> = 10...200
}

// MARK: Inputs from the app

/// One typed entry as the app stores it: a weight, and the body fat and lean mass typed with it, when there were any.
public struct BodyLogTypedRecord: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let measuredAt: Date
    public let timeZoneIdentifier: String
    public let weightKilograms: Double
    public let bodyFatPercent: Double?
    public let leanMassKilograms: Double?

    public init(id: UUID = UUID(), measuredAt: Date, timeZoneIdentifier: String, weightKilograms: Double,
                bodyFatPercent: Double? = nil, leanMassKilograms: Double? = nil) {
        self.id = id
        self.measuredAt = measuredAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.weightKilograms = weightKilograms
        self.bodyFatPercent = bodyFatPercent
        self.leanMassKilograms = leanMassKilograms
    }
}

/// One Apple Health sample of one quantity, in kilograms or percent, with who wrote it.
public struct BodyLogHealthSample: Equatable, Sendable {
    public let quantity: BodyLogQuantity
    /// Kilograms for weight and lean mass, percent (0 to 100) for body fat.
    public let value: Double
    public let measuredAt: Date
    public let sourceName: String
    public let typedIntoHealth: Bool

    public init(quantity: BodyLogQuantity, value: Double, measuredAt: Date, sourceName: String, typedIntoHealth: Bool = false) {
        self.quantity = quantity
        self.value = value
        self.measuredAt = measuredAt
        self.sourceName = sourceName
        self.typedIntoHealth = typedIntoHealth
    }
}

/// Whether Apple Health gave anything. The reasons stay apart because the empty screen words each one differently.
public enum BodyLogHealthStatus: Equatable, Sendable {
    /// At least one sample came back.
    case reading
    /// Loopr may read Apple Health and found no weight, body fat or lean mass. Apple Health does not say whether
    /// the person denied access or has no samples, so both land here.
    case noSamples
    /// Loopr has not asked Apple Health for these yet.
    case notShared
    /// The person switched the read off in Loopr.
    case switchedOff
    /// No Apple Health on this device.
    case unavailable
    /// Apple Health failed the query. Try again later.
    case failed

    /// One status for the three reads: `.reading` when any returned samples, otherwise the most telling reason.
    public static func combine(_ statuses: [BodyLogHealthStatus]) -> BodyLogHealthStatus {
        if statuses.contains(.reading) { return .reading }
        for reason in [BodyLogHealthStatus.switchedOff, .notShared, .unavailable, .failed] where statuses.contains(reason) {
            return reason
        }
        return .noSamples
    }
}

/// What the app hands the log: the typed entries, the Apple Health samples and how the Apple Health read went.
public struct BodyLogSnapshot: Equatable, Sendable {
    public var typed: [BodyLogTypedRecord]
    public var health: [BodyLogHealthSample]
    public var healthStatus: BodyLogHealthStatus

    public init(typed: [BodyLogTypedRecord] = [], health: [BodyLogHealthSample] = [], healthStatus: BodyLogHealthStatus = .noSamples) {
        self.typed = typed
        self.health = health
        self.healthStatus = healthStatus
    }

    public static let empty = BodyLogSnapshot()
}

// MARK: Entries

/// One row of the log. A typed entry is what the person typed together. An Apple Health entry is the samples one
/// source wrote at the same time, which is how a smart scale writes weight, body fat and lean mass. Each value keeps
/// its own number: a typed entry and an Apple Health entry at the same time stay two entries.
public struct BodyLogEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let measuredAt: Date
    public let origin: BodyLogOrigin
    public let weightKilograms: Double?
    public let bodyFatPercent: Double?
    public let leanMassKilograms: Double?
    /// The typed entry's id, for deleting it. Nil for Apple Health entries, which Loopr cannot change.
    public let typedID: UUID?

    public init(id: String, measuredAt: Date, origin: BodyLogOrigin, weightKilograms: Double? = nil,
                bodyFatPercent: Double? = nil, leanMassKilograms: Double? = nil, typedID: UUID? = nil) {
        self.id = id
        self.measuredAt = measuredAt
        self.origin = origin
        self.weightKilograms = weightKilograms
        self.bodyFatPercent = bodyFatPercent
        self.leanMassKilograms = leanMassKilograms
        self.typedID = typedID
    }

    public var isTyped: Bool { origin.isTyped }

    public func value(_ quantity: BodyLogQuantity) -> Double? {
        switch quantity {
        case .weight: weightKilograms
        case .bodyFat: bodyFatPercent
        case .leanMass: leanMassKilograms
        }
    }
}

public enum BodyLogMerge {
    /// Samples a source wrote within this many seconds of each other count as one measurement.
    static let sameMeasurementSeconds: TimeInterval = 60

    /// Typed entries and Apple Health entries, newest first. Never combines a typed entry with a Health sample, and
    /// never fills a missing quantity: an entry without body fat has no body fat.
    public static func entries(typed: [BodyLogTypedRecord], health: [BodyLogHealthSample]) -> [BodyLogEntry] {
        var result = typed.map { record in
            BodyLogEntry(id: record.id.uuidString, measuredAt: record.measuredAt, origin: .typed,
                         weightKilograms: record.weightKilograms, bodyFatPercent: record.bodyFatPercent,
                         leanMassKilograms: record.leanMassKilograms, typedID: record.id)
        }
        result.append(contentsOf: healthEntries(health))
        return result.sorted { lhs, rhs in
            if lhs.measuredAt != rhs.measuredAt { return lhs.measuredAt > rhs.measuredAt }
            // The person's own entry first at the same time, then by id so the order never flickers.
            if lhs.isTyped != rhs.isTyped { return lhs.isTyped }
            return lhs.id < rhs.id
        }
    }

    private struct GroupKey: Hashable {
        let sourceName: String
        let typedIntoHealth: Bool
    }

    private static func healthEntries(_ samples: [BodyLogHealthSample]) -> [BodyLogEntry] {
        guard !samples.isEmpty else { return [] }
        var byKey: [GroupKey: [BodyLogHealthSample]] = [:]
        for sample in samples where sample.value.isFinite {
            byKey[GroupKey(sourceName: sample.sourceName.trimmingCharacters(in: .whitespaces),
                           typedIntoHealth: sample.typedIntoHealth), default: []].append(sample)
        }
        var entries: [BodyLogEntry] = []
        for (key, group) in byKey {
            let sorted = group.sorted { $0.measuredAt < $1.measuredAt }
            var cluster: [BodyLogHealthSample] = []
            func flush() {
                guard let newest = cluster.last else { return }
                func latest(_ quantity: BodyLogQuantity) -> Double? { cluster.last { $0.quantity == quantity }?.value }
                let stamp = Int(newest.measuredAt.timeIntervalSince1970.rounded())
                entries.append(BodyLogEntry(
                    id: "health-\(stamp)-\(key.sourceName)-\(key.typedIntoHealth ? "typed" : "device")",
                    measuredAt: newest.measuredAt,
                    origin: .appleHealth(sourceName: key.sourceName, typedIntoHealth: key.typedIntoHealth),
                    weightKilograms: latest(.weight), bodyFatPercent: latest(.bodyFat), leanMassKilograms: latest(.leanMass)))
                cluster = []
            }
            for sample in sorted {
                if let first = cluster.first, sample.measuredAt.timeIntervalSince(first.measuredAt) > sameMeasurementSeconds { flush() }
                cluster.append(sample)
            }
            flush()
        }
        return entries
    }
}

// MARK: Latest readings and trend

/// One quantity's value with where it came from and when.
public struct BodyLogReading: Equatable, Sendable {
    public let quantity: BodyLogQuantity
    /// Kilograms for weight and lean mass, percent for body fat.
    public let value: Double
    public let measuredAt: Date
    public let origin: BodyLogOrigin

    public init(quantity: BodyLogQuantity, value: Double, measuredAt: Date, origin: BodyLogOrigin) {
        self.quantity = quantity
        self.value = value
        self.measuredAt = measuredAt
        self.origin = origin
    }

    public var provenance: LooprProvenance { origin.provenance }
}

/// The newest value of each quantity across typed and Apple Health entries. A quantity with no value is nil, so a
/// screen shows it as absent and never as zero. The three may come from different sources and times.
public struct BodyLogSummary: Equatable, Sendable {
    public let weight: BodyLogReading?
    public let bodyFat: BodyLogReading?
    public let leanMass: BodyLogReading?

    public init(weight: BodyLogReading?, bodyFat: BodyLogReading?, leanMass: BodyLogReading?) {
        self.weight = weight
        self.bodyFat = bodyFat
        self.leanMass = leanMass
    }

    public static let empty = BodyLogSummary(weight: nil, bodyFat: nil, leanMass: nil)

    public var isEmpty: Bool { weight == nil && bodyFat == nil && leanMass == nil }

    public func reading(_ quantity: BodyLogQuantity) -> BodyLogReading? {
        switch quantity {
        case .weight: weight
        case .bodyFat: bodyFat
        case .leanMass: leanMass
        }
    }

    /// `entries` can be in any order. At the same time, the person's typed value wins.
    public static func make(_ entries: [BodyLogEntry]) -> BodyLogSummary {
        func latest(_ quantity: BodyLogQuantity) -> BodyLogReading? {
            let candidates = entries.filter { $0.value(quantity) != nil }
            guard let best = candidates.max(by: { lhs, rhs in
                if lhs.measuredAt != rhs.measuredAt { return lhs.measuredAt < rhs.measuredAt }
                if lhs.isTyped != rhs.isTyped { return !lhs.isTyped }
                return lhs.id > rhs.id
            }), let value = best.value(quantity) else { return nil }
            return BodyLogReading(quantity: quantity, value: value, measuredAt: best.measuredAt, origin: best.origin)
        }
        return BodyLogSummary(weight: latest(.weight), bodyFat: latest(.bodyFat), leanMass: latest(.leanMass))
    }
}

/// One quantity's trend: the day's newest reading for each day, in the unit the person reads, oldest first.
/// A line, not a number: a day with a typed and an Apple Health reading plots the later one, and both stay in the list.
public struct BodyLogSeries: Equatable, Sendable, Identifiable {
    public let quantity: BodyLogQuantity
    public let points: [LooprChartPoint]
    public let latest: BodyLogReading?
    /// The days the chart covers, ending on `endingOn`.
    public let days: Int
    public let endingOn: Date

    public var id: String { quantity.rawValue }

    /// A line needs two readings in the window.
    public var hasTrend: Bool { points.count >= 2 }

    public static func make(entries: [BodyLogEntry], quantity: BodyLogQuantity, system: LooprMeasurementSystem,
                            now: Date, calendar: Calendar, days: Int = 90) -> BodyLogSeries {
        let earliest = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        let readings = entries.compactMap { entry -> (Date, Double)? in
            guard let value = entry.value(quantity), entry.measuredAt >= earliest, entry.measuredAt <= now else { return nil }
            return (entry.measuredAt, value)
        }
        var newestOfDay: [Date: (Date, Double)] = [:]
        for reading in readings {
            let day = calendar.startOfDay(for: reading.0)
            if let kept = newestOfDay[day], kept.0 >= reading.0 { continue }
            newestOfDay[day] = reading
        }
        let points = newestOfDay.keys.sorted().compactMap { day -> LooprChartPoint? in
            guard let reading = newestOfDay[day] else { return nil }
            let shown = quantity == .bodyFat ? reading.1 : BodyLogFormat.displayValue(kilograms: reading.1, system: system)
            return LooprChartPoint(date: day, value: shown)
        }
        return BodyLogSeries(quantity: quantity, points: points, latest: BodyLogSummary.make(entries).reading(quantity),
                             days: days, endingOn: now)
    }
}

// MARK: Formatting

public enum BodyLogFormat {
    static let poundsPerKilogram = 2.204_622_621_848_78

    public static func unitLabel(_ system: LooprMeasurementSystem) -> String { system == .imperial ? "lb" : "kg" }

    /// The word VoiceOver says for the unit.
    public static func spokenUnit(_ system: LooprMeasurementSystem) -> String { system == .imperial ? "pounds" : "kilograms" }

    public static func displayValue(kilograms: Double, system: LooprMeasurementSystem) -> Double {
        system == .imperial ? kilograms * poundsPerKilogram : kilograms
    }

    public static func kilograms(fromDisplay value: Double, system: LooprMeasurementSystem) -> Double {
        system == .imperial ? value / poundsPerKilogram : value
    }

    /// One decimal in the person's unit. The digits use a fixed locale, like every number on the Body tab.
    public static func weight(kilograms: Double, system: LooprMeasurementSystem) -> LooprMeasurement {
        LooprMeasurement(value: LooprUnitFormatter.number(displayValue(kilograms: kilograms, system: system), digits: 1) ?? "",
                         unit: unitLabel(system))
    }

    public static func bodyFat(percent: Double) -> LooprMeasurement {
        LooprMeasurement(value: LooprUnitFormatter.number(percent, digits: 1) ?? "", unit: "%")
    }

    /// A reading of any quantity as the person reads it.
    public static func measurement(_ quantity: BodyLogQuantity, value: Double, system: LooprMeasurementSystem) -> LooprMeasurement {
        quantity == .bodyFat ? bodyFat(percent: value) : weight(kilograms: value, system: system)
    }

    /// "78.4 kg", "172.8 lb", "21.5 %".
    public static func text(_ quantity: BodyLogQuantity, value: Double, system: LooprMeasurementSystem) -> String {
        measurement(quantity, value: value, system: system).combined
    }

    /// The value as VoiceOver reads it: "78.4 kilograms", "21.5 percent".
    public static func spoken(_ quantity: BodyLogQuantity, value: Double, system: LooprMeasurementSystem) -> String {
        let measurement = measurement(quantity, value: value, system: system)
        return "\(measurement.value) \(quantity == .bodyFat ? "percent" : spokenUnit(system))"
    }

    /// Text for an entry field: one decimal, no unit, no grouping.
    public static func inputText(_ value: Double) -> String {
        LooprUnitFormatter.number(value, digits: 1)?.replacingOccurrences(of: ",", with: "") ?? ""
    }

    /// A number typed into a field. Accepts a comma as the decimal mark. Nil for anything else, and for an empty field.
    public static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}

// MARK: Entry and validation

/// A checked entry, ready to store. Weight in kilograms whatever the person's unit.
public struct BodyLogInput: Equatable, Sendable {
    public let weightKilograms: Double
    public let bodyFatPercent: Double?
    public let leanMassKilograms: Double?
    public let measuredAt: Date

    public init(weightKilograms: Double, bodyFatPercent: Double?, leanMassKilograms: Double?, measuredAt: Date) {
        self.weightKilograms = weightKilograms
        self.bodyFatPercent = bodyFatPercent
        self.leanMassKilograms = leanMassKilograms
        self.measuredAt = measuredAt
    }
}

public enum BodyLogField: String, Sendable {
    case weight, bodyFat, leanMass, date
}

public enum BodyLogValidationError: Error, Equatable, Sendable {
    case weightMissing
    case weightNotANumber
    case weightOutOfRange
    case bodyFatNotANumber
    case bodyFatOutOfRange
    case leanMassNotANumber
    case leanMassOutOfRange
    case leanMassNotBelowWeight
    case timeInFuture

    public var field: BodyLogField {
        switch self {
        case .weightMissing, .weightNotANumber, .weightOutOfRange: .weight
        case .bodyFatNotANumber, .bodyFatOutOfRange: .bodyFat
        case .leanMassNotANumber, .leanMassOutOfRange, .leanMassNotBelowWeight: .leanMass
        case .timeInFuture: .date
        }
    }

    /// What the sheet says. The ranges read in the person's unit, rounded inward so every number named is allowed.
    public func message(system: LooprMeasurementSystem) -> String {
        let unit = BodyLogFormat.unitLabel(system)
        switch self {
        case .weightMissing: return "Enter a weight to save this entry."
        case .weightNotANumber: return "Weight needs to be a number, like \(system == .imperial ? "172.8" : "78.4")."
        case .weightOutOfRange:
            return "Weight needs to be between \(Self.bound(BodyLogLimits.weightKilograms, system)) \(unit)."
        case .bodyFatNotANumber: return "Body fat needs to be a number, like 18.5."
        case .bodyFatOutOfRange: return "Body fat needs to be between 2 and 75 percent."
        case .leanMassNotANumber: return "Lean mass needs to be a number, like \(system == .imperial ? "135.0" : "61.2")."
        case .leanMassOutOfRange:
            return "Lean mass needs to be between \(Self.bound(BodyLogLimits.leanMassKilograms, system)) \(unit)."
        case .leanMassNotBelowWeight: return "Lean mass needs to be below your weight."
        case .timeInFuture: return "The time cannot be later than now."
        }
    }

    private static func bound(_ range: ClosedRange<Double>, _ system: LooprMeasurementSystem) -> String {
        let low = BodyLogFormat.displayValue(kilograms: range.lowerBound, system: system).rounded(.up)
        let high = BodyLogFormat.displayValue(kilograms: range.upperBound, system: system).rounded(.down)
        return "\(Int(low)) and \(Int(high))"
    }
}

public enum BodyLogDraft {
    /// Checks what the sheet holds. Weight is required. Body fat and lean mass are optional, and an empty field is
    /// absent, never zero. The first problem found comes back, in field order.
    public static func validate(weightText: String, bodyFatText: String, leanMassText: String, measuredAt: Date, now: Date,
                                system: LooprMeasurementSystem) -> Result<BodyLogInput, BodyLogValidationError> {
        func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if isBlank(weightText) { return .failure(.weightMissing) }
        guard let shownWeight = BodyLogFormat.parse(weightText) else { return .failure(.weightNotANumber) }
        let weight = BodyLogFormat.kilograms(fromDisplay: shownWeight, system: system)
        guard BodyLogLimits.weightKilograms.contains(weight) else { return .failure(.weightOutOfRange) }

        var bodyFat: Double?
        if !isBlank(bodyFatText) {
            guard let value = BodyLogFormat.parse(bodyFatText) else { return .failure(.bodyFatNotANumber) }
            guard BodyLogLimits.bodyFatPercent.contains(value) else { return .failure(.bodyFatOutOfRange) }
            bodyFat = value
        }

        var leanMass: Double?
        if !isBlank(leanMassText) {
            guard let shown = BodyLogFormat.parse(leanMassText) else { return .failure(.leanMassNotANumber) }
            let value = BodyLogFormat.kilograms(fromDisplay: shown, system: system)
            guard BodyLogLimits.leanMassKilograms.contains(value) else { return .failure(.leanMassOutOfRange) }
            guard value < weight else { return .failure(.leanMassNotBelowWeight) }
            leanMass = value
        }

        guard measuredAt <= now else { return .failure(.timeInFuture) }
        return .success(BodyLogInput(weightKilograms: weight, bodyFatPercent: bodyFat, leanMassKilograms: leanMass,
                                     measuredAt: measuredAt))
    }
}

// MARK: Words

public enum BodyLogCopy {
    public static let title = "Weight and body composition"

    /// The sentence on the empty log: where values come from, then what is missing.
    public static func emptyText(_ status: BodyLogHealthStatus) -> String {
        let sources = "Weight, body fat and lean mass come from what you type in and from Apple Health."
        switch status {
        case .reading, .noSamples: return "\(sources) Nothing is logged yet."
        case .notShared: return "\(sources) Apple Health is not shared with Loopr yet, so only typed entries show."
        case .switchedOff: return "\(sources) You switched the Apple Health reads off, so only typed entries show."
        case .unavailable: return "\(sources) This device has no Apple Health, so only typed entries show."
        case .failed: return "\(sources) Apple Health did not answer, so only typed entries show for now."
        }
    }

    /// A line under the list when Apple Health is not adding anything while typed entries exist. Nil when there is
    /// nothing to say.
    public static func healthNote(_ status: BodyLogHealthStatus) -> String? {
        switch status {
        case .reading, .noSamples: nil
        case .notShared: "Apple Health is not shared with Loopr, so only typed entries show."
        case .switchedOff: "The Apple Health reads are switched off, so only typed entries show."
        case .unavailable: "This device has no Apple Health, so only typed entries show."
        case .failed: "Apple Health did not answer, so only typed entries show for now."
        }
    }

    public static let readOnlyHealthNote = "Read from Apple Health. It cannot be edited here."
    public static let absent = "Not recorded"
    public static let healthFootnote = "Loopr reads these from Apple Health and never writes to it."
}
