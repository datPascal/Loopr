import Foundation

/// Everything Train owns, in the shape a backup file carries. Plans and
/// sessions travel together; a day export carries that day's sessions only.
public struct TrainArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let templates: [WorkoutTemplate]
    public let programs: [Program]
    public let customExercises: [ExerciseDefinition]
    public let sessions: [TrainSession]

    public init(schemaVersion: Int = Self.currentSchemaVersion, templates: [WorkoutTemplate] = [], programs: [Program] = [],
                customExercises: [ExerciseDefinition] = [], sessions: [TrainSession] = []) {
        self.schemaVersion = schemaVersion; self.templates = templates; self.programs = programs
        self.customExercises = customExercises; self.sessions = sessions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            templates: try values.decodeIfPresent([WorkoutTemplate].self, forKey: .templates) ?? [],
            programs: try values.decodeIfPresent([Program].self, forKey: .programs) ?? [],
            customExercises: try values.decodeIfPresent([ExerciseDefinition].self, forKey: .customExercises) ?? [],
            sessions: try values.decodeIfPresent([TrainSession].self, forKey: .sessions) ?? [])
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw TrainError.unsupportedVersion(schemaVersion) }
        guard Set(templates.map(\.id)).count == templates.count, Set(programs.map(\.id)).count == programs.count,
              Set(customExercises.map(\.key)).count == customExercises.count,
              Set(sessions.map(\.id)).count == sessions.count else { throw TrainError.invalidRecord }
        for template in templates { try template.validate(); guard template.revision > 0 else { throw TrainError.invalidRecord } }
        for program in programs { try program.validate(); guard program.revision > 0 else { throw TrainError.invalidRecord } }
        for exercise in customExercises {
            try exercise.validate()
            guard exercise.origin == .custom, exercise.revision > 0 else { throw TrainError.invalidRecord }
        }
        let setIDs = sessions.flatMap { $0.exercises.flatMap(\.sets).map(\.id) }
        guard Set(setIDs).count == setIDs.count else { throw TrainError.invalidRecord }
        for session in sessions { try session.validate(); guard session.revision > 0 else { throw TrainError.invalidRecord } }
    }

    /// Keeps the sessions of the chosen days. Plans and custom exercises are not day records:
    /// they stay when `includingPlans` is true (a day deletion) and drop out otherwise (a day export).
    public func selectingDays(includingPlans: Bool = false, _ include: (String) -> Bool) -> Self {
        Self(schemaVersion: schemaVersion, templates: includingPlans ? templates : [], programs: includingPlans ? programs : [],
             customExercises: includingPlans ? customExercises : [], sessions: sessions.filter { include($0.localDay) })
    }
}
