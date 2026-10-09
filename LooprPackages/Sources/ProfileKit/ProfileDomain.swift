import DesignSystem
import DomainKit
import Foundation

/// The unit system is an explicit profile choice.  No screen is allowed to
/// infer a unit system from a locale or silently fall back to a default.
public enum UnitSystem: String, Codable, CaseIterable, Hashable, Sendable {
    case metric
    case imperial

    /// What the screens format against.
    public var looprMeasurementSystem: LooprMeasurementSystem {
        self == .imperial ? .imperial : .metric
    }
}

public enum BiologicalSex: String, Codable, CaseIterable, Hashable, Sendable {
    case female
    case male
    case intersex
    case undisclosed
}

public enum ProfileField: String, CaseIterable, Hashable, Sendable {
    case displayName
    case birthYear
    case biologicalSex
    case heightCentimeters
    case weightKilograms
    case timezoneIdentifier
}

public struct ProfileDraft: Codable, Equatable, Sendable {
    public var displayName: String?
    public var birthYear: Int?
    public var biologicalSex: BiologicalSex?
    public var heightCentimeters: Double?
    public var weightKilograms: Double?
    public var timezoneIdentifier: String?
    public var unitSystem: UnitSystem?

    public init(
        displayName: String? = nil,
        birthYear: Int? = nil,
        biologicalSex: BiologicalSex? = nil,
        heightCentimeters: Double? = nil,
        weightKilograms: Double? = nil,
        timezoneIdentifier: String? = nil,
        unitSystem: UnitSystem? = nil
    ) {
        self.displayName = displayName
        self.birthYear = birthYear
        self.biologicalSex = biologicalSex
        self.heightCentimeters = heightCentimeters
        self.weightKilograms = weightKilograms
        self.timezoneIdentifier = timezoneIdentifier
        self.unitSystem = unitSystem
    }
}

public struct Profile: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String
    public let birthYear: Int?
    public let biologicalSex: BiologicalSex?
    public let heightCentimeters: Double?
    public let weightKilograms: Double?
    public let timezoneIdentifier: String?
    public let unitSystem: UnitSystem
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        displayName: String,
        birthYear: Int? = nil,
        biologicalSex: BiologicalSex? = nil,
        heightCentimeters: Double? = nil,
        weightKilograms: Double? = nil,
        timezoneIdentifier: String? = nil,
        unitSystem: UnitSystem,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.birthYear = birthYear
        self.biologicalSex = biologicalSex
        self.heightCentimeters = heightCentimeters
        self.weightKilograms = weightKilograms
        self.timezoneIdentifier = timezoneIdentifier
        self.unitSystem = unitSystem
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func draft() -> ProfileDraft {
        ProfileDraft(
            displayName: displayName,
            birthYear: birthYear,
            biologicalSex: biologicalSex,
            heightCentimeters: heightCentimeters,
            weightKilograms: weightKilograms,
            timezoneIdentifier: timezoneIdentifier,
            unitSystem: unitSystem
        )
    }
}

/// A typed optional value used by consumers that must preserve the
/// difference between a field that is absent and a field that was measured.
/// In particular, consumers must not turn an absent height/weight into zero.
public enum ProfileOptionalValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case absent
    case measured(Value)
}

public extension Profile {
    var birthYearValue: ProfileOptionalValue<Int> {
        birthYear.map(ProfileOptionalValue.measured) ?? .absent
    }

    var biologicalSexValue: ProfileOptionalValue<BiologicalSex> {
        biologicalSex.map(ProfileOptionalValue.measured) ?? .absent
    }

    var heightValue: ProfileOptionalValue<Double> {
        heightCentimeters.map(ProfileOptionalValue.measured) ?? .absent
    }

    var weightValue: ProfileOptionalValue<Double> {
        weightKilograms.map(ProfileOptionalValue.measured) ?? .absent
    }

    var timezoneValue: ProfileOptionalValue<String> {
        timezoneIdentifier.map(ProfileOptionalValue.measured) ?? .absent
    }
}

public enum ProfileValidationError: Error, Equatable, Sendable, LocalizedError {
    case missingDisplayName
    case missingUnitSystem
    case invalidBirthYear(Int)
    case invalidHeight(Double)
    case invalidWeight(Double)
    case invalidTimezone(String)

    public var errorDescription: String? {
        switch self {
        case .missingDisplayName: "A display name is required."
        case .missingUnitSystem: "Choose a unit system before saving the profile."
        case .invalidBirthYear(let year): "Birth year is outside the supported range: \(year)."
        case .invalidHeight(let value): "Height is outside the supported range: \(value)."
        case .invalidWeight(let value): "Weight is outside the supported range: \(value)."
        case .invalidTimezone(let value): "Unknown timezone identifier: \(value)."
        }
    }
}

public enum ProfileRepositoryError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case migrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Your profile is unavailable right now."
        case .migrationFailed(let message): "Profile migration failed: \(message)"
        }
    }
}

public enum ProfileValidator {
    public static func validate(_ draft: ProfileDraft, currentYear: Int? = nil) throws {
        let yearNow = currentYear ?? Calendar(identifier: .gregorian).component(.year, from: Date())
        // The display name is optional. Nothing in Loopr derives a value from
        // it, and asking for one before someone can use the app was a wall.
        // An absent name is stored as an empty string; `missingDisplayName`
        // stays in the error enum for source compatibility only.
        guard draft.unitSystem != nil else { throw ProfileValidationError.missingUnitSystem }

        if let year = draft.birthYear, !(yearNow - 120 ... yearNow - 13).contains(year) {
            throw ProfileValidationError.invalidBirthYear(year)
        }
        if let height = draft.heightCentimeters, !(80 ... 250).contains(height) {
            throw ProfileValidationError.invalidHeight(height)
        }
        if let weight = draft.weightKilograms, !(20 ... 400).contains(weight) {
            throw ProfileValidationError.invalidWeight(weight)
        }
        if let timezone = draft.timezoneIdentifier {
            let trimmed = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, TimeZone(identifier: trimmed) == nil {
                throw ProfileValidationError.invalidTimezone(timezone)
            }
        }
    }

    public static func makeProfile(
        from draft: ProfileDraft,
        id: UUID,
        now: Date,
        currentYear: Int? = nil
    ) throws -> Profile {
        try validate(draft, currentYear: currentYear)
        let displayName = draft.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let unitSystem = draft.unitSystem else {
            throw ProfileValidationError.missingUnitSystem
        }
        return Profile(
            id: id,
            displayName: displayName,
            birthYear: draft.birthYear,
            biologicalSex: draft.biologicalSex,
            heightCentimeters: draft.heightCentimeters,
            weightKilograms: draft.weightKilograms,
            timezoneIdentifier: draft.timezoneIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            unitSystem: unitSystem,
            createdAt: now,
            updatedAt: now
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum GoalType: String, Codable, CaseIterable, Hashable, Sendable {
    case recovery
    case sleep
    case strain
    case steps
    case workouts
}

public struct Goal: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let type: GoalType
    public let target: Double
    public let unit: String
    public let isEnabled: Bool
    public let updatedAt: Date

    public init(id: UUID, type: GoalType, target: Double, unit: String, isEnabled: Bool = true, updatedAt: Date) {
        self.id = id
        self.type = type
        self.target = target
        self.unit = unit
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

public enum GoalValidationError: Error, Equatable, Sendable, LocalizedError {
    case nonPositiveTarget
    case emptyUnit

    public var errorDescription: String? {
        switch self {
        case .nonPositiveTarget: "A goal target must be greater than zero."
        case .emptyUnit: "A goal unit is required."
        }
    }
}

public enum GoalValidator {
    public static func validate(target: Double, unit: String) throws {
        guard target.isFinite, target > 0 else { throw GoalValidationError.nonPositiveTarget }
        guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoalValidationError.emptyUnit
        }
    }
}

public enum ProfileRepositoryState: Equatable, Sendable {
    case noRecordsYet
    case present(Profile)
    case validationError(ProfileValidationError)
    case recoverableError(String)
}

public enum GoalsRepositoryState: Equatable, Sendable {
    case noRecordsYet
    case present([Goal])
    case validationError(GoalValidationError)
    case recoverableError(String)
}

public enum ProfileValidationState: Equatable, Sendable {
    case valid
    case invalid(ProfileValidationError)
    case recoverableError(String)
}

public enum GoalValidationState: Equatable, Sendable {
    case valid
    case invalid(GoalValidationError)
    case recoverableError(String)
}

public protocol ProfileRepository: Sendable {
    func readProfile() async throws -> Profile?
    func saveProfile(_ draft: ProfileDraft) async throws -> Profile
    func resetProfile() async throws
    func deleteAllData() async throws
    func exportSnapshot() async throws -> ProfileStoreSnapshot
    func restoreSnapshot(_ snapshot: ProfileStoreSnapshot) async throws
}

public protocol GoalsRepository: Sendable {
    func readGoals() async throws -> [Goal]
    func saveGoal(type: GoalType, target: Double, unit: String, isEnabled: Bool) async throws -> Goal
    func deleteGoals() async throws
}

public extension ProfileRepository {
    /// A typed read seam for UI/view models. Implementations remain free to
    /// throw, while consumers can render a recoverable repository failure
    /// without substituting a value for an absent record.
    func readProfileState() async -> ProfileRepositoryState {
        do {
            guard let profile = try await readProfile() else { return .noRecordsYet }
            return .present(profile)
        } catch {
            return .recoverableError(error.localizedDescription)
        }
    }

    func validateDraft(_ draft: ProfileDraft, currentYear: Int? = nil) -> ProfileValidationState {
        do {
            try ProfileValidator.validate(draft, currentYear: currentYear)
            return .valid
        } catch let error as ProfileValidationError {
            return .invalid(error)
        } catch {
            return .recoverableError(error.localizedDescription)
        }
    }
}

public extension GoalsRepository {
    func readGoalsState() async -> GoalsRepositoryState {
        do {
            let goals = try await readGoals()
            return goals.isEmpty ? .noRecordsYet : .present(goals)
        } catch {
            return .recoverableError(error.localizedDescription)
        }
    }

    func validateGoal(target: Double, unit: String) -> GoalValidationState {
        do {
            try GoalValidator.validate(target: target, unit: unit)
            return .valid
        } catch let error as GoalValidationError {
            return .invalid(error)
        } catch {
            return .recoverableError(error.localizedDescription)
        }
    }
}

public struct ProfileStoreSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let profile: Profile?
    public let goals: [Goal]

    public init(schemaVersion: Int, profile: Profile?, goals: [Goal]) {
        self.schemaVersion = schemaVersion
        self.profile = profile
        self.goals = goals
    }
}

public enum ProfileSchemaMigration {
    public static let currentVersion = 1

    public static func migrate(_ snapshot: ProfileStoreSnapshot) throws -> ProfileStoreSnapshot {
        guard (0...currentVersion).contains(snapshot.schemaVersion) else {
            throw ProfileRepositoryError.migrationFailed("Unsupported schema version \(snapshot.schemaVersion).")
        }
        return ProfileStoreSnapshot(schemaVersion: currentVersion, profile: snapshot.profile, goals: snapshot.goals)
    }
}

/// Deterministic repository used by the app composition and package tests.
/// It deliberately stores optional profile fields as `nil`; no field is
/// materialized as zero, an empty string, or a locale-derived placeholder.
public actor InMemoryProfileRepository: ProfileRepository, GoalsRepository {
    private let dateProvider: any DateProviding
    private let uuidProvider: any UUIDProviding
    private var profile: Profile?
    private var goals: [Goal]

    public init(
        profile: Profile? = nil,
        goals: [Goal] = [],
        dateProvider: any DateProviding = SystemDateProvider(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider()
    ) {
        self.profile = profile
        self.goals = goals
        self.dateProvider = dateProvider
        self.uuidProvider = uuidProvider
    }

    public func readProfile() async throws -> Profile? { profile }

    public func saveProfile(_ draft: ProfileDraft) async throws -> Profile {
        let now = dateProvider.now()
        let id: UUID
        if let existingID = profile?.id {
            id = existingID
        } else {
            id = await uuidProvider.nextUUID()
        }
        let createdAt = profile?.createdAt ?? now
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: now)
        try ProfileValidator.validate(draft, currentYear: currentYear)
        let displayName = draft.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let unitSystem = draft.unitSystem else {
            throw ProfileValidationError.missingUnitSystem
        }
        let value = Profile(
            id: id,
            displayName: displayName,
            birthYear: draft.birthYear,
            biologicalSex: draft.biologicalSex,
            heightCentimeters: draft.heightCentimeters,
            weightKilograms: draft.weightKilograms,
            timezoneIdentifier: draft.timezoneIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            unitSystem: unitSystem,
            createdAt: createdAt,
            updatedAt: now
        )
        profile = value
        return value
    }

    public func resetProfile() async throws {
        profile = nil
        goals.removeAll(keepingCapacity: false)
    }

    public func deleteAllData() async throws {
        profile = nil
        goals.removeAll(keepingCapacity: false)
    }

    public func readGoals() async throws -> [Goal] { goals.sorted { $0.type.rawValue < $1.type.rawValue } }

    public func saveGoal(type: GoalType, target: Double, unit: String, isEnabled: Bool = true) async throws -> Goal {
        try GoalValidator.validate(target: target, unit: unit)
        let value = Goal(
            id: await uuidProvider.nextUUID(),
            type: type,
            target: target,
            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: isEnabled,
            updatedAt: dateProvider.now()
        )
        goals.removeAll { $0.type == type }
        goals.append(value)
        return value
    }

    public func deleteGoals() async throws { goals.removeAll(keepingCapacity: false) }

    public func exportSnapshot() async throws -> ProfileStoreSnapshot {
        ProfileStoreSnapshot(
            schemaVersion: ProfileSchemaMigration.currentVersion,
            profile: profile,
            goals: goals.sorted { $0.type.rawValue < $1.type.rawValue }
        )
    }

    public func restoreSnapshot(_ snapshot: ProfileStoreSnapshot) async throws {
        let migrated = try ProfileSchemaMigration.migrate(snapshot)
        profile = migrated.profile
        goals = migrated.goals
    }

    /// Backward-compatible concrete aliases for callers that already used the
    /// repository's deterministic fixture API.
    public func snapshot() async throws -> ProfileStoreSnapshot {
        try await exportSnapshot()
    }

    public func restore(snapshot: ProfileStoreSnapshot) async throws {
        try await restoreSnapshot(snapshot)
    }
}

public enum UnitConverter {
    public static func centimetersToInches(_ centimeters: Double) -> Double { centimeters / 2.54 }
    public static func inchesToCentimeters(_ inches: Double) -> Double { inches * 2.54 }
    public static func kilogramsToPounds(_ kilograms: Double) -> Double { kilograms * 2.2046226218 }
    public static func poundsToKilograms(_ pounds: Double) -> Double { pounds / 2.2046226218 }
}
