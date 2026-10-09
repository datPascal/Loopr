import Foundation

public enum AnalyticsMetricFamily: String, Codable, CaseIterable, Sendable {
    case heart
    case hrv
    case sleep
    case recovery
    case activity
    case workout
    case age
    case battery

    /// ANA-08's pruning edge depends on every upstream canonical generation
    /// (ANA-02 through ANA-07A). Battery is tracked independently by ANA-09;
    /// when present it is still included by the aggregate state provider.
    public static let pruningFamilies: Set<AnalyticsMetricFamily> = [
        .heart, .hrv, .sleep, .recovery, .activity, .workout, .age
    ]
}

public struct DerivationKey: Hashable, Codable, Sendable {
    public let day: Date
    public let family: AnalyticsMetricFamily
    public let inputRevision: String

    public init(day: Date, family: AnalyticsMetricFamily, inputRevision: String = "default") {
        self.day = day
        self.family = family
        self.inputRevision = inputRevision
    }
}

public struct DerivationPayload: Equatable, Sendable {
    public let bytes: Data

    public init(bytes: Data = Data()) {
        self.bytes = bytes
    }
}

public struct PersistedDerivationGeneration: Codable, Equatable, Sendable {
    public let generationID: UUID
    public let day: Date
    public let family: AnalyticsMetricFamily
    public let inputRevision: String
    public let algorithmVersion: Int
    public let referenceVersion: Int?
    public let payload: Data
    public let isComplete: Bool
    public let isDurable: Bool
    public let generatedAt: Date

    public init(
        generationID: UUID = UUID(),
        day: Date,
        family: AnalyticsMetricFamily,
        inputRevision: String = "default",
        algorithmVersion: Int,
        referenceVersion: Int? = nil,
        payload: Data,
        isComplete: Bool = true,
        isDurable: Bool = true,
        generatedAt: Date = Date()
    ) {
        self.generationID = generationID
        self.day = day
        self.family = family
        self.inputRevision = inputRevision
        self.algorithmVersion = algorithmVersion
        self.referenceVersion = referenceVersion
        self.payload = payload
        self.isComplete = isComplete
        self.isDurable = isDurable
        self.generatedAt = generatedAt
    }
}

public enum DerivationSchedulerError: Error, Equatable, Sendable {
    case noRetentionState
    case invalidAlgorithmVersion
    case failedDerivation
}

public protocol AnalyticsDerivationPipeline: Sendable {
    func derive(
        day: Date,
        family: AnalyticsMetricFamily,
        inputRevision: String
    ) async throws -> DerivationPayload
}

public protocol DerivationStore: Sendable {
    func persist(_ generation: PersistedDerivationGeneration) async throws
    func generations(day: Date, family: AnalyticsMetricFamily) async throws -> [PersistedDerivationGeneration]
}

public extension DerivationStore {
    func latestCompatible(
        day: Date,
        family: AnalyticsMetricFamily,
        algorithmVersion: Int,
        inputRevision: String = "default"
    ) async throws -> PersistedDerivationGeneration? {
        let values = try await generations(day: day, family: family)
        return values
            .filter {
                $0.algorithmVersion == algorithmVersion &&
                $0.inputRevision == inputRevision &&
                $0.isComplete && $0.isDurable
            }
            .max { lhs, rhs in lhs.generatedAt < rhs.generatedAt }
    }
}

public struct DerivationFamilyState: Codable, Equatable, Sendable {
    public let isComplete: Bool
    public let isDurable: Bool
    public let isVersioned: Bool
    public let isDecodable: Bool
    public let hasFailed: Bool
    public let isPartial: Bool

    public init(
        isComplete: Bool,
        isDurable: Bool,
        isVersioned: Bool,
        isDecodable: Bool = true,
        hasFailed: Bool = false,
        isPartial: Bool = false
    ) {
        self.isComplete = isComplete
        self.isDurable = isDurable
        self.isVersioned = isVersioned
        self.isDecodable = isDecodable
        self.hasFailed = hasFailed
        self.isPartial = isPartial
    }

    public static let complete = DerivationFamilyState(
        isComplete: true,
        isDurable: true,
        isVersioned: true
    )
}

public struct DerivationDayState: Codable, Equatable, Sendable {
    public let day: Date
    public let isCurrentDay: Bool
    public let isComplete: Bool
    public let isDurable: Bool
    public let isVersioned: Bool
    public let isDecodable: Bool
    public let hasFailed: Bool
    public let isPartial: Bool
    /// Raw-keyed so the state can be persisted without making the enum a
    /// CodingKey; values are still produced only from AnalyticsMetricFamily.
    public let familyStates: [String: DerivationFamilyState]
    public let requiredFamilyNames: Set<String>

    public init(
        day: Date,
        isCurrentDay: Bool,
        isComplete: Bool,
        isDurable: Bool,
        isVersioned: Bool,
        isDecodable: Bool = true,
        hasFailed: Bool = false,
        isPartial: Bool = false,
        familyStates: [String: DerivationFamilyState] = [:],
        requiredFamilyNames: Set<String> = []
    ) {
        self.day = day
        self.isCurrentDay = isCurrentDay
        self.isComplete = isComplete
        self.isDurable = isDurable
        self.isVersioned = isVersioned
        self.isDecodable = isDecodable
        self.hasFailed = hasFailed
        self.isPartial = isPartial
        self.familyStates = familyStates
        self.requiredFamilyNames = requiredFamilyNames
    }

    public var allRequiredFamiliesComplete: Bool {
        requiredFamilyNames.allSatisfy { name in
            guard let state = familyStates[name] else { return false }
            return state.isComplete && state.isDurable && state.isVersioned && state.isDecodable && !state.hasFailed && !state.isPartial
        }
    }

    public static func complete(
        day: Date,
        isCurrentDay: Bool = false,
        isVersioned: Bool = true,
        isDecodable: Bool = true
    ) -> DerivationDayState {
        DerivationDayState(
            day: day,
            isCurrentDay: isCurrentDay,
            isComplete: true,
            isDurable: true,
            isVersioned: isVersioned,
            isDecodable: isDecodable
        )
    }

    public static func aggregate(
        day: Date,
        familyStates: [AnalyticsMetricFamily: DerivationFamilyState],
        rawSubstrateComplete: Bool,
        rawSubstrateDurable: Bool = true,
        rawSubstrateVersioned: Bool = true,
        rawSubstrateDecodable: Bool = true,
        isCurrentDay: Bool = false
    ) -> DerivationDayState {
        let required = AnalyticsMetricFamily.pruningFamilies
        let allFamiliesComplete = required.allSatisfy { family in
            guard let state = familyStates[family] else { return false }
            return state.isComplete && state.isDurable && state.isVersioned && state.isDecodable && !state.hasFailed && !state.isPartial
        }
        let allDurable = required.allSatisfy { familyStates[$0]?.isDurable == true }
        let allVersioned = required.allSatisfy { familyStates[$0]?.isVersioned == true }
        let allDecodable = required.allSatisfy { familyStates[$0]?.isDecodable == true }
        let hasFailed = familyStates.values.contains { $0.hasFailed }
        let isPartial = familyStates.values.contains { $0.isPartial } || !allFamiliesComplete
        return DerivationDayState(
            day: day,
            isCurrentDay: isCurrentDay,
            isComplete: rawSubstrateComplete && allFamiliesComplete,
            isDurable: rawSubstrateDurable && allDurable,
            isVersioned: rawSubstrateVersioned && allVersioned,
            isDecodable: rawSubstrateDecodable && allDecodable,
            hasFailed: hasFailed,
            isPartial: isPartial,
            familyStates: Dictionary(uniqueKeysWithValues: familyStates.map { ($0.key.rawValue, $0.value) }),
            requiredFamilyNames: Set(required.map(\.rawValue))
        )
    }
}

public protocol DerivationDayStateProvider: Sendable {
    func state(for day: Date) async throws -> DerivationDayState?
}

/// Concrete ANA-02…ANA-07A generation state registry. It intentionally keeps
/// raw substrate completion separate from family generations, so one finished
/// metric can never authorize pruning for a partial day.
public actor DerivationCompletenessRegistry: DerivationDayStateProvider {
    private struct RawState: Sendable {
        let complete: Bool
        let durable: Bool
        let versioned: Bool
        let decodable: Bool
        let current: Bool
    }

    private var rawStates: [Date: RawState] = [:]
    private var families: [Date: [AnalyticsMetricFamily: DerivationFamilyState]] = [:]

    public init() {}

    public func setRawSubstrate(
        day: Date,
        isComplete: Bool,
        isDurable: Bool,
        isVersioned: Bool,
        isDecodable: Bool = true,
        isCurrentDay: Bool = false
    ) {
        rawStates[day] = RawState(
            complete: isComplete,
            durable: isDurable,
            versioned: isVersioned,
            decodable: isDecodable,
            current: isCurrentDay
        )
    }

    public func record(day: Date, family: AnalyticsMetricFamily, state: DerivationFamilyState) {
        families[day, default: [:]][family] = state
    }

    public func state(for day: Date) -> DerivationDayState? {
        guard let raw = rawStates[day] else { return nil }
        return .aggregate(
            day: day,
            familyStates: families[day, default: [:]],
            rawSubstrateComplete: raw.complete,
            rawSubstrateDurable: raw.durable,
            rawSubstrateVersioned: raw.versioned,
            rawSubstrateDecodable: raw.decodable,
            isCurrentDay: raw.current
        )
    }
}

/// Owns scheduling and persistence coordination. Metric calculators receive
/// immutable inputs and never receive a store, so this actor is the only write
/// path for derived generations.
public actor DerivationScheduler {
    private struct RequestKey: Hashable, Sendable {
        let derivation: DerivationKey
        let algorithmVersion: Int
    }

    private let pipeline: any AnalyticsDerivationPipeline
    private let store: any DerivationStore
    private let stateProvider: (any DerivationDayStateProvider)?
    private let algorithmVersion: Int
    private let timeZone: TimeZone
    private var inFlight: [RequestKey: Task<PersistedDerivationGeneration, Error>] = [:]

    public init(
        pipeline: any AnalyticsDerivationPipeline,
        store: any DerivationStore,
        stateProvider: (any DerivationDayStateProvider)? = nil,
        algorithmVersion: Int = 1,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.pipeline = pipeline
        self.store = store
        self.stateProvider = stateProvider
        self.algorithmVersion = algorithmVersion
        self.timeZone = timeZone
    }

    /// Requests one derivation for a local-day/family/revision key. Duplicate
    /// requests await the same task and therefore produce one persisted row.
    public func request(
        day: Date,
        family: AnalyticsMetricFamily,
        inputRevision: String = "default",
        algorithmVersion requestedVersion: Int? = nil
    ) async throws -> PersistedDerivationGeneration {
        try Task.checkCancellation()
        let version = requestedVersion ?? algorithmVersion
        guard version > 0 else { throw DerivationSchedulerError.invalidAlgorithmVersion }
        let derivationKey = DerivationKey(day: day, family: family, inputRevision: inputRevision)
        let key = RequestKey(derivation: derivationKey, algorithmVersion: version)

        if let existingTask = inFlight[key] {
            return try await waitForSharedTask(existingTask, key: key)
        }

        let pipeline = self.pipeline
        let store = self.store
        let task = Task<PersistedDerivationGeneration, Error> {
            try Task.checkCancellation()
            if let existing = try await store.latestCompatible(
                day: day,
                family: family,
                algorithmVersion: version,
                inputRevision: inputRevision
            ) {
                return existing
            }
            try Task.checkCancellation()
            let payload = try await pipeline.derive(
                day: day,
                family: family,
                inputRevision: inputRevision
            )
            try Task.checkCancellation()
            let generation = PersistedDerivationGeneration(
                day: day,
                family: family,
                inputRevision: inputRevision,
                algorithmVersion: version,
                payload: payload.bytes
            )
            // Persist is one atomic operation. No partial output is handed to
            // the store, and cancellation is checked before entering it.
            try await store.persist(generation)
            return generation
        }
        inFlight[key] = task

        do {
            let result = try await waitForSharedTask(task, key: key)
            inFlight.removeValue(forKey: key)
            return result
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }

    public func cancel(day: Date, family: AnalyticsMetricFamily, inputRevision: String = "default") {
        let derivation = DerivationKey(day: day, family: family, inputRevision: inputRevision)
        for (key, task) in inFlight where key.derivation == derivation {
            task.cancel()
        }
    }

    public func currentProjection(
        day: Date,
        family: AnalyticsMetricFamily,
        algorithmVersion requestedVersion: Int? = nil,
        inputRevision: String = "default"
    ) async throws -> PersistedDerivationGeneration? {
        try await store.latestCompatible(
            day: day,
            family: family,
            algorithmVersion: requestedVersion ?? algorithmVersion,
            inputRevision: inputRevision
        )
    }

    public func historicalGenerations(
        day: Date,
        family: AnalyticsMetricFamily
    ) async throws -> [PersistedDerivationGeneration] {
        try await store.generations(day: day, family: family)
    }

    /// Raw substrate is prunable only after three complete local days have
    /// passed and every durability/version/decodability condition is true.
    public func isDayPrunable(day: Date, now: Date = Date()) async -> Bool {
        guard let stateProvider,
              let state = try? await stateProvider.state(for: day) else { return false }
        guard !state.isCurrentDay,
              state.isComplete,
              state.isDurable,
              state.isVersioned,
              state.isDecodable,
              !state.hasFailed,
              !state.isPartial,
              state.allRequiredFamiliesComplete else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentDay = calendar.startOfDay(for: now)
        let candidateDay = calendar.startOfDay(for: day)
        guard let cutoff = calendar.date(byAdding: .day, value: -3, to: currentDay) else { return false }
        return candidateDay < cutoff
    }

    private func waitForSharedTask(
        _ task: Task<PersistedDerivationGeneration, Error>,
        key: RequestKey
    ) async throws -> PersistedDerivationGeneration {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // A cancelled request cancels the coalesced work. The pipeline must
            // reach its cancellation check before persistence, leaving no row.
            task.cancel()
        }
    }
}

/// A deterministic actor-backed store used by offline tests and previews. It
/// also models the production rule that identical generations are idempotent.
public actor InMemoryDerivationStore: DerivationStore, DerivationDayStateProvider {
    private var stored: [PersistedDerivationGeneration] = []
    private var states: [Date: DerivationDayState] = [:]

    public init() {}

    public func persist(_ generation: PersistedDerivationGeneration) {
        if stored.contains(where: {
            $0.day == generation.day &&
            $0.family == generation.family &&
            $0.inputRevision == generation.inputRevision &&
            $0.algorithmVersion == generation.algorithmVersion &&
            $0.payload == generation.payload
        }) {
            return
        }
        stored.append(generation)
    }

    public func generations(day: Date, family: AnalyticsMetricFamily) -> [PersistedDerivationGeneration] {
        stored.filter { $0.day == day && $0.family == family }
    }

    public func allGenerations() -> [PersistedDerivationGeneration] { stored }

    public func setState(_ state: DerivationDayState) { states[state.day] = state }

    public func state(for day: Date) -> DerivationDayState? { states[day] }
}

public struct EmptyDerivationPipeline: AnalyticsDerivationPipeline {
    public init() {}
    public func derive(
        day: Date,
        family: AnalyticsMetricFamily,
        inputRevision: String
    ) async throws -> DerivationPayload {
        try Task.checkCancellation()
        return DerivationPayload()
    }
}
