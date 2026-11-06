import Foundation

/// Why the bundled exercise list or a custom exercise was refused.
public enum ExerciseLibraryError: Error, Equatable, Sendable, LocalizedError {
    case malformedData
    case duplicateKey(String)
    case invalidDefinition(String)
    case invalidCustomExercise(String)

    public var errorDescription: String? {
        switch self {
        case .malformedData: "The built-in exercise list is damaged. Update or reinstall Loopr to restore it."
        case .duplicateKey: "The built-in exercise list repeats an exercise. Update or reinstall Loopr to restore it."
        case .invalidDefinition: "The built-in exercise list has an entry Loopr cannot read. Update or reinstall Loopr to restore it."
        case .invalidCustomExercise: "One of your custom exercises is not valid. Open it and check the name and muscles."
        }
    }
}

/// Dataset categories. Anything the app does not know maps to `other`.
public enum ExerciseCategory: String, CaseIterable, Sendable, Hashable {
    case strength, stretching, plyometrics, powerlifting, strongman, cardio, other
    case olympicWeightlifting = "olympic weightlifting"

    public init(dataset value: String?) {
        self = value.flatMap { Self(rawValue: $0.lowercased()) } ?? .other
    }
}

/// Dataset equipment. A missing value and any unknown value map to `other`.
public enum ExerciseEquipment: String, CaseIterable, Sendable, Hashable {
    case barbell, dumbbell, cable, machine, kettlebells, bands, other
    case bodyOnly = "body only"
    case medicineBall = "medicine ball"
    case exerciseBall = "exercise ball"
    case foamRoll = "foam roll"
    case ezCurlBar = "e-z curl bar"

    public init(dataset value: String?) {
        self = value.flatMap { Self(rawValue: $0.lowercased()) } ?? .other
    }
}

/// Dataset difficulty levels. A missing value and any unknown value map to `other`.
public enum ExerciseLevel: String, CaseIterable, Sendable, Hashable {
    case beginner, intermediate, expert, other

    public init(dataset value: String?) {
        self = value.flatMap { Self(rawValue: $0.lowercased()) } ?? .other
    }
}

extension ExerciseDefinition {
    public var categoryKind: ExerciseCategory { ExerciseCategory(dataset: category) }
    public var equipmentKind: ExerciseEquipment { ExerciseEquipment(dataset: equipment) }
    public var levelKind: ExerciseLevel { ExerciseLevel(dataset: level) }
}

/// Filters for the exercise picker. An empty set puts no limit on that field.
/// Different fields combine with AND, values inside one field combine with OR.
public struct ExerciseFilter: Equatable, Sendable {
    public var equipment: Set<ExerciseEquipment>
    /// Dataset muscle names such as `chest` or `lower back`. Compared without case.
    public var muscles: Set<String>
    public var categories: Set<ExerciseCategory>
    /// When false, only primary muscles count toward the muscle filter.
    public var includeSecondaryMuscles: Bool

    public init(equipment: Set<ExerciseEquipment> = [], muscles: Set<String> = [],
                categories: Set<ExerciseCategory> = [], includeSecondaryMuscles: Bool = false) {
        self.equipment = equipment
        self.muscles = muscles
        self.categories = categories
        self.includeSecondaryMuscles = includeSecondaryMuscles
    }

    public var isEmpty: Bool { equipment.isEmpty && muscles.isEmpty && categories.isEmpty }

    func matches(_ exercise: ExerciseDefinition) -> Bool {
        if !equipment.isEmpty, !equipment.contains(exercise.equipmentKind) { return false }
        if !categories.isEmpty, !categories.contains(exercise.categoryKind) { return false }
        if !muscles.isEmpty {
            let wanted = Set(muscles.map { $0.lowercased() })
            var have = Set(exercise.primaryMuscles.map { $0.lowercased() })
            if includeSecondaryMuscles { have.formUnion(exercise.secondaryMuscles.map { $0.lowercased() }) }
            if have.isDisjoint(with: wanted) { return false }
        }
        return true
    }
}

/// The bundled exercise library, plus any custom exercises merged in.
///
/// The app passes the bytes of `exercises.v1.json` (Free Exercise DB) and of `exercises.loopr.v1.json`
/// (movements Loopr added) from the main bundle. Tests pass fixtures. Unknown category, equipment or
/// level strings never fail a load. The raw string stays on the definition and the typed accessors
/// report `other`.
public struct ExerciseLibrary: Sendable {
    /// Resource name of the trimmed dataset in the app bundle.
    public static let resourceName = "exercises.v1"
    /// Resource name of the movements Loopr added on top of the dataset. Same shape, keys start with `loopr-`.
    public static let additionsResourceName = "exercises.loopr.v1"
    public static let resourceExtension = "json"
    /// Every key in the additions file starts with this, so a key alone says where an entry came from.
    public static let additionKeyPrefix = "loopr-"

    private struct Entry: Sendable {
        let definition: ExerciseDefinition
        let foldedName: String
        /// `ExerciseName.compact` of the name.
        let compactName: String
        let words: [String]
        let compactAliases: [String]

        init(_ definition: ExerciseDefinition) {
            self.definition = definition
            foldedName = ExerciseLibrary.fold(definition.name)
            compactName = ExerciseName.compact(definition.name)
            words = ExerciseName.words(definition.name)
            compactAliases = (ExerciseAliases.byKey[definition.key] ?? []).map(ExerciseName.compact)
        }
    }

    private struct Row: Decodable {
        let id: String
        let name: String
        let category: String
        let equipment: String?
        let level: String?
        let force: String?
        let mechanic: String?
        let primaryMuscles: [String]
        let secondaryMuscles: [String]
    }

    private let entries: [Entry]
    private let index: [String: Int]

    /// Decodes the trimmed dataset, and the Loopr additions when given. Throws `ExerciseLibraryError`
    /// for malformed JSON, wrong field types, an empty list, a blank id or name, or a repeated id,
    /// including an addition that repeats a dataset id.
    ///
    /// Common lifts take the name plans use (`ExerciseDisplayNames`), and an entry that is the same lift as
    /// another (`ExerciseAliases.mergedKeys`) is left out, so the picker offers one key per lift.
    public init(data: Data, additions: Data? = nil) throws {
        var rows = try Self.rows(data)
        if let additions { rows += try Self.rows(additions) }
        rows.removeAll { ExerciseAliases.mergedKeys[$0.id] != nil }
        try self.init(definitions: rows.map {
            ExerciseDefinition(key: $0.id, name: ExerciseDisplayNames.name(forKey: $0.id, dataset: $0.name), category: $0.category,
                               equipment: $0.equipment, level: $0.level,
                               force: $0.force, mechanic: $0.mechanic, primaryMuscles: $0.primaryMuscles,
                               secondaryMuscles: $0.secondaryMuscles)
        })
    }

    private static func rows(_ data: Data) throws -> [Row] {
        let rows: [Row]
        do { rows = try JSONDecoder().decode([Row].self, from: data) } catch { throw ExerciseLibraryError.malformedData }
        guard !rows.isEmpty else { throw ExerciseLibraryError.malformedData }
        return rows
    }

    /// Reads both files from a bundle. Resources in a synchronized folder land at the bundle root, so the
    /// plain lookup comes first; the subdirectory lookups cover a build that keeps the folder. A missing
    /// additions file loads the dataset alone.
    public static func bundled(in bundle: Bundle) throws -> ExerciseLibrary {
        func url(_ name: String) -> URL? {
            bundle.url(forResource: name, withExtension: resourceExtension)
                ?? bundle.url(forResource: name, withExtension: resourceExtension, subdirectory: "ExerciseLibrary")
                ?? bundle.url(forResource: name, withExtension: resourceExtension, subdirectory: "Resources/ExerciseLibrary")
        }
        guard let main = url(resourceName) else { throw ExerciseLibraryError.malformedData }
        let additions = try url(additionsResourceName).map { try Data(contentsOf: $0) }
        return try ExerciseLibrary(data: Data(contentsOf: main), additions: additions)
    }

    /// Builds a library from definitions that are already decoded. Throws on an invalid definition
    /// or a repeated key. An empty list is allowed.
    public init(definitions: [ExerciseDefinition]) throws {
        var seen = Set<String>()
        var built: [Entry] = []
        built.reserveCapacity(definitions.count)
        for definition in definitions {
            do { try definition.validate() } catch { throw ExerciseLibraryError.invalidDefinition(definition.key) }
            guard seen.insert(definition.key).inserted else { throw ExerciseLibraryError.duplicateKey(definition.key) }
            built.append(Entry(definition))
        }
        self.init(sorted: built)
    }

    private init(sorted unsorted: [Entry]) {
        let ordered = unsorted.sorted {
            $0.foldedName == $1.foldedName ? $0.definition.key < $1.definition.key : $0.foldedName < $1.foldedName
        }
        entries = ordered
        index = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.definition.key, $0) })
    }

    public var count: Int { entries.count }

    /// Every exercise, ordered by name.
    public var all: [ExerciseDefinition] { entries.map(\.definition) }

    /// The exercise behind a key. A key merged into another (`ExerciseAliases.mergedKeys`) finds the one it joined.
    public func definition(forKey key: String) -> ExerciseDefinition? {
        (index[key] ?? index[ExerciseAliases.canonicalKey(key)]).map { entries[$0].definition }
    }

    /// Muscle names used by any exercise, sorted. Use them to build the muscle filter.
    public var muscles: [String] {
        var names = Set<String>()
        for entry in entries {
            names.formUnion(entry.definition.primaryMuscles)
            names.formUnion(entry.definition.secondaryMuscles)
        }
        return names.sorted()
    }

    /// Returns a library with the custom exercises added. A custom exercise replaces a library
    /// exercise with the same key. When two custom exercises share a key, the later one wins.
    /// Throws if an entry is not a valid custom exercise (`custom-<uuid>` key and `.custom` origin).
    public func merged(withCustom custom: [ExerciseDefinition]) throws -> ExerciseLibrary {
        var byKey: [String: Entry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.definition.key, $0) })
        for definition in custom {
            guard definition.origin == .custom, (try? definition.validate()) != nil else {
                throw ExerciseLibraryError.invalidCustomExercise(definition.key)
            }
            byKey[definition.key] = Entry(definition)
        }
        return ExerciseLibrary(sorted: Array(byKey.values))
    }

    /// Exercises that pass the filter, ordered by name.
    public func filtered(_ filter: ExerciseFilter) -> [ExerciseDefinition] {
        entries.map(\.definition).filter { filter.matches($0) }
    }

    /// Searches names and aliases. Case, diacritics, hyphens, spaces and a trailing "s" do not matter,
    /// so "pullup" finds "Pull-up" and "Pullups".
    ///
    /// Ranks, best first: the whole name or an alias equals the query; the name or an alias starts with
    /// it; each word of the query starts a word of the name; the name contains every word. Inside a rank,
    /// keys in `preferring` (the person's recent and custom exercises) come first, then names in order.
    /// A blank query returns the filtered list.
    public func search(_ query: String, filter: ExerciseFilter = ExerciseFilter(), limit: Int? = nil,
                       preferring: Set<String> = []) -> [ExerciseDefinition] {
        let tokens = ExerciseName.words(query)
        var results: [ExerciseDefinition]
        if tokens.isEmpty {
            results = filtered(filter)
        } else {
            let compactQuery = tokens.joined()
            var ranked: [(rank: Int, preferred: Bool, offset: Int, entry: Entry)] = []
            for (offset, entry) in entries.enumerated() where filter.matches(entry.definition) {
                guard let rank = Self.rank(entry, tokens: tokens, compactQuery: compactQuery) else { continue }
                ranked.append((rank, preferring.contains(entry.definition.key), offset, entry))
            }
            // `entries` is already ordered by name, so the offset tie-break keeps name order.
            ranked.sort { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.preferred != rhs.preferred { return lhs.preferred }
                return lhs.offset < rhs.offset
            }
            results = ranked.map(\.entry.definition)
        }
        if let limit, limit >= 0, results.count > limit { results = Array(results.prefix(limit)) }
        return results
    }

    private static func rank(_ entry: Entry, tokens: [String], compactQuery: String) -> Int? {
        if entry.compactName == compactQuery || entry.compactAliases.contains(compactQuery) { return 0 }
        if entry.compactName.hasPrefix(compactQuery) || entry.compactAliases.contains(where: { $0.hasPrefix(compactQuery) }) { return 1 }
        if tokens.allSatisfy({ token in entry.words.contains { $0.hasPrefix(token) } }) { return 2 }
        if entry.compactName.contains(compactQuery) || tokens.allSatisfy({ entry.compactName.contains($0) }) { return 3 }
        return nil
    }

    /// The alias a search matched when the name itself does not contain the query, for a hint such as
    /// "Also called Nordic curl". Nil when the name matches or the query is blank.
    public func matchedAlias(of definition: ExerciseDefinition, query: String) -> String? {
        let compactQuery = ExerciseName.compact(query)
        guard !compactQuery.isEmpty, !ExerciseName.compact(definition.name).contains(compactQuery) else { return nil }
        return ExerciseAliases.byKey[definition.key]?.first { ExerciseName.compact($0).hasPrefix(compactQuery) }
    }

    /// The exercise this name already means, matched on the folded name, then on an alias, or nil. A
    /// library entry wins over a custom one. Use it before adding a custom exercise so one lift keeps one key.
    public func existing(named name: String) -> ExerciseDefinition? {
        let compact = ExerciseName.compact(name)
        guard !compact.isEmpty else { return nil }
        let matches = entries.filter { $0.compactName == compact }.map(\.definition)
        if let match = matches.first(where: { $0.origin == .library }) ?? matches.first { return match }
        return ExerciseAliases.keyByCompactAlias[compact].flatMap(definition(forKey:))
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
