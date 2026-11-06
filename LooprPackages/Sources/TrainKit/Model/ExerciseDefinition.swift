import Foundation

/// A library or custom exercise. Library entries come from the bundled dataset
/// and are not stored in SQLite; custom entries live in `workout_exercise_custom`.
public struct ExerciseDefinition: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable { case library, custom }

    /// Stable key. Library entries use the dataset id; custom entries use `custom-<uuid>`.
    public let key: String
    public var id: String { key }
    public var name: String
    public var category: String
    public var equipment: String?
    public var level: String?
    public var force: String?
    public var mechanic: String?
    public var primaryMuscles: [String]
    public var secondaryMuscles: [String]
    public let origin: Origin
    /// Bumped by the store on every save of a custom exercise. Library entries stay at 0.
    public var revision: Int
    public let schemaVersion: Int

    public init(key: String, name: String, category: String, equipment: String? = nil, level: String? = nil,
                force: String? = nil, mechanic: String? = nil, primaryMuscles: [String] = [], secondaryMuscles: [String] = [],
                origin: Origin = .library, revision: Int = 0, schemaVersion: Int = TrainRecordSchema.currentVersion) {
        self.key = key; self.name = name; self.category = category; self.equipment = equipment; self.level = level
        self.force = force; self.mechanic = mechanic; self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles; self.origin = origin; self.revision = revision; self.schemaVersion = schemaVersion
    }

    /// A new custom exercise with a fresh key.
    public static func custom(id: UUID = UUID(), name: String, category: String = "strength", equipment: String? = nil,
                              primaryMuscles: [String] = [], secondaryMuscles: [String] = []) -> Self {
        .init(key: customKeyPrefix + id.uuidString, name: name, category: category, equipment: equipment,
              primaryMuscles: primaryMuscles, secondaryMuscles: secondaryMuscles, origin: .custom)
    }

    public static let customKeyPrefix = "custom-"

    public var reference: ExerciseRef { .init(key: key, name: name) }

    public func validate() throws {
        guard schemaVersion >= 1 else { throw TrainError.invalidRecord }
        guard schemaVersion <= TrainLimits.currentSchemaVersion else { throw TrainError.unsupportedVersion(schemaVersion) }
        guard !key.isEmpty, key.count <= 120, TrainLimits.validText(name, limit: TrainLimits.name),
              TrainLimits.validText(category, limit: TrainLimits.name), revision >= 0,
              primaryMuscles.count <= 12, secondaryMuscles.count <= 12 else { throw TrainError.invalidRecord }
        if origin == .custom {
            guard key.hasPrefix(Self.customKeyPrefix), UUID(uuidString: String(key.dropFirst(Self.customKeyPrefix.count))) != nil else { throw TrainError.invalidRecord }
        }
    }
}

/// The exercise a template or session points at. The name is a snapshot so an old
/// session still reads correctly after a custom exercise is renamed or deleted.
public struct ExerciseRef: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public var name: String

    public init(key: String, name: String) { self.key = key; self.name = name }

    func validate() throws {
        guard !key.isEmpty, key.count <= 120, TrainLimits.validText(name, limit: TrainLimits.name) else { throw TrainError.invalidRecord }
    }
}
