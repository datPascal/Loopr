import Foundation
import Testing
import TrainKit

struct ExerciseSearchTests {
    private static func entry(_ key: String, _ name: String, category: String = "strength", equipment: String? = "body only") -> ExerciseDefinition {
        ExerciseDefinition(key: key, name: name, category: category, equipment: equipment, primaryMuscles: ["lats"])
    }

    private static func library() throws -> ExerciseLibrary {
        try ExerciseLibrary(definitions: [
            entry("Pullups", "Pullups"),
            entry("Pull_Through", "Pull Through", equipment: "cable"),
            entry("loopr-kipping-pull-up", "Kipping pull-up"),
            entry("Romanian_Deadlift", "Romanian Deadlift", equipment: "barbell"),
            entry("loopr-double-under", "Double-under", category: "plyometrics", equipment: "other"),
            entry("loopr-toes-to-bar", "Toes-to-bar"),
            entry("loopr-kettlebell-swing", "Kettlebell swing", equipment: "kettlebells"),
            entry("Pushups", "Pushups"),
            entry("Push-Up_Wide", "Push-Up Wide"),
            entry("Worlds_Greatest_Stretch", "World's Greatest Stretch", category: "stretching", equipment: nil),
            entry("Natural_Glute_Ham_Raise", "Natural Glute Ham Raise")
        ])
    }

    private func names(_ list: [ExerciseDefinition]) -> [String] { list.map(\.name) }

    @Test func namesFoldCaseHyphensSpacesAndATrailingS() {
        let forms = ["Pull-up", "pullup", "Pullups", "pull ups", "PULL-UPS", " Pull–Up "]
        #expect(Set(forms.map(ExerciseName.compact)) == ["pullup"])
        #expect(ExerciseName.words("World's greatest stretch") == ["world", "greatest", "stretch"])
        #expect(ExerciseName.compact("Bench press") == "benchpress", "a double s stays")
        #expect(ExerciseName.compact("Dips") == "dip")
        #expect(ExerciseName.compact("90/90 hip switch") == "9090hipswitch")
        #expect(ExerciseName.compact("Étirement") == "etirement")
        #expect(ExerciseName.compact("  ") == "")
    }

    @Test func spellingVariantsFindTheSameExerciseFirst() throws {
        let library = try Self.library()
        for query in ["pull-up", "pullup", "Pullups", "pull ups"] {
            #expect(library.search(query).first?.key == "Pullups", "\(query)")
        }
        for query in ["push-up", "Push ups", "pushup"] {
            #expect(library.search(query).first?.key == "Pushups", "\(query)")
        }
        #expect(library.search("worlds greatest").first?.key == "Worlds_Greatest_Stretch")
    }

    @Test func exactBeatsPrefixBeatsWordStartBeatsContains() throws {
        let library = try Self.library()
        // "Pushups" is the whole name, "Push-Up Wide" only starts with it.
        #expect(names(library.search("push up")) == ["Pushups", "Push-Up Wide"])
        // Two names start with "pull"; name order decides between them, and the word match comes after.
        #expect(names(library.search("pull")) == ["Pull Through", "Pullups", "Kipping pull-up"])
        // "swing" starts a word inside the name.
        #expect(names(library.search("swing")) == ["Kettlebell swing"])
        // "ullup" is only inside a word.
        #expect(names(library.search("ullup")) == ["Kipping pull-up", "Pullups"])
    }

    @Test func preferredKeysLeadInsideARank() throws {
        let library = try Self.library()
        #expect(names(library.search("pull", preferring: ["Pullups"])) == ["Pullups", "Pull Through", "Kipping pull-up"])
        // A preferred key never jumps a better rank.
        #expect(library.search("pull through", preferring: ["Pullups"]).first?.key == "Pull_Through")
    }

    @Test func aliasesFindTheLift() throws {
        let library = try Self.library()
        #expect(library.search("RDL").first?.key == "Romanian_Deadlift")
        #expect(library.search("du").first?.key == "loopr-double-under")
        #expect(library.search("T2B").first?.key == "loopr-toes-to-bar")
        #expect(library.search("ttb").first?.key == "loopr-toes-to-bar")
        #expect(library.search("KB swing").first?.key == "loopr-kettlebell-swing")
        #expect(library.search("nordic").first?.key == "Natural_Glute_Ham_Raise")
        let rdl = try #require(library.definition(forKey: "Romanian_Deadlift"))
        #expect(library.matchedAlias(of: rdl, query: "rdl") == "RDL")
        #expect(library.matchedAlias(of: rdl, query: "romanian") == nil, "the name matches, so no hint")
        #expect(library.matchedAlias(of: rdl, query: "") == nil)
        #expect(ExerciseAliases.key(forAlias: "Farmer carry") == "Farmers_Walk")
        #expect(ExerciseAliases.key(forAlias: "side plank") == "Side_Bridge")
    }

    @Test func existingNameKeepsOneKeyPerLift() throws {
        let custom = ExerciseDefinition.custom(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!, name: "Pull Through")
        let library = try Self.library().merged(withCustom: [custom])
        #expect(library.existing(named: "Pull up")?.key == "Pullups")
        #expect(library.existing(named: "rdl")?.key == "Romanian_Deadlift")
        #expect(library.existing(named: "pull through")?.origin == .library, "the library entry wins over a custom twin")
        #expect(library.existing(named: "Sled sprint") == nil)
        #expect(library.existing(named: "   ") == nil)
    }

    @Test func categoryChipsMatchTheSchema() {
        let bench = Self.entry("Bench", "Bench", equipment: "barbell")
        let plank = Self.entry("Plank", "Plank")
        let stretch = Self.entry("Hamstring_Stretch", "Hamstring Stretch", category: "stretching")
        let carry = Self.entry("Farmers_Walk", "Farmer's Walk", category: "strongman", equipment: "other")
        let clean = Self.entry("Power_Clean", "Power Clean", category: "olympic weightlifting", equipment: "barbell")
        #expect(ExercisePickerCategory.strength.matches(bench))
        #expect(ExercisePickerCategory.strength.matches(carry))
        #expect(!ExercisePickerCategory.strength.matches(plank), "body only goes under Bodyweight")
        #expect(ExercisePickerCategory.bodyweight.matches(plank))
        #expect(!ExercisePickerCategory.bodyweight.matches(stretch), "stretches have their own chip")
        #expect(ExercisePickerCategory.stretching.matches(stretch))
        #expect(ExercisePickerCategory.olympic.matches(clean))
        #expect(ExercisePickerCategory.crossFit.matches(clean))
        #expect(!ExercisePickerCategory.crossFit.matches(bench))
        #expect(ExercisePickerCategory.allCases.map(\.title) == ["Strength", "Bodyweight", "Stretching", "Cardio", "Plyometrics", "Olympic", "CrossFit"])
    }
}

/// The two files the app ships, decoded together.
struct BundledExerciseAdditionsTests {
    private static var folder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Loopr/Loopr/Resources/ExerciseLibrary")
    }

    private static func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent("\(name).json"))
    }

    @Test func additionsDecodeBesideTheDatasetWithoutRepeats() throws {
        let dataset = try ExerciseLibrary(data: Self.data(ExerciseLibrary.resourceName))
        let additions = try ExerciseLibrary(data: Self.data(ExerciseLibrary.additionsResourceName))
        let both = try ExerciseLibrary(data: Self.data(ExerciseLibrary.resourceName), additions: Self.data(ExerciseLibrary.additionsResourceName))
        #expect(additions.count >= 60)
        #expect(both.count == dataset.count + additions.count)
        let muscles = Set(dataset.muscles)
        for exercise in additions.all {
            #expect(exercise.key.hasPrefix(ExerciseLibrary.additionKeyPrefix), "\(exercise.key)")
            #expect(exercise.categoryKind != .other, "\(exercise.key) category")
            #expect(exercise.equipment.flatMap(ExerciseEquipment.init(rawValue:)) != nil, "\(exercise.key) equipment")
            #expect(exercise.levelKind != .other, "\(exercise.key) level")
            #expect(!exercise.primaryMuscles.isEmpty, "\(exercise.key) muscles")
            #expect(Set(exercise.primaryMuscles + exercise.secondaryMuscles).isSubset(of: muscles), "\(exercise.key) uses the dataset's muscle names")
            // A Loopr addition never repeats a movement the dataset has under the same name or an alias.
            #expect(dataset.existing(named: exercise.name) == nil, "\(exercise.name) is already in the dataset")
        }
    }

    @Test func namedMovementsArePresentWithPlainNames() throws {
        let both = try ExerciseLibrary(data: Self.data(ExerciseLibrary.resourceName), additions: Self.data(ExerciseLibrary.additionsResourceName))
        let wanted = ["Burpee", "Double-under", "Single-under", "Toes-to-bar", "Knees-to-elbows", "Wall ball", "Box jump over",
                      "Rope climb", "Ring dip", "Ring row", "Bar muscle-up", "Ring muscle-up", "Kipping pull-up", "Chest-to-bar pull-up",
                      "Handstand hold", "Handstand push-up", "Handstand walk", "Pistol squat", "Thruster", "Devil press",
                      "American kettlebell swing", "Sumo deadlift high pull", "Assault bike", "Rowing erg", "Ski erg", "Sled push",
                      "Pogo hops", "Broad jump", "Knee push-up", "Incline push-up", "Band-assisted pull-up", "Assisted dip", "L-sit",
                      "Hollow hold", "Plank", "Side plank", "Copenhagen plank", "Dead bug", "Bird dog", "Glute bridge", "Nordic curl",
                      "Wall sit", "Dead hang", "Cat-cow", "World's greatest stretch", "90/90 hip switch", "Couch stretch", "Pigeon pose",
                      "Child's pose", "Downward dog", "Thoracic rotation", "Hamstring stretch", "Calf stretch", "Deep squat hold",
                      "Farmer carry", "Suitcase carry", "Overhead carry"]
        for name in wanted {
            #expect(!both.search(name).isEmpty, "\(name) finds nothing")
        }
        for name in ["Cat-cow", "Couch stretch", "Pigeon pose", "Downward dog", "Deep squat hold", "90/90 hip switch"] {
            #expect(both.existing(named: name)?.categoryKind == .stretching, "\(name) is a stretch")
        }
    }

    @Test func aliasAndCollectionKeysExist() throws {
        let both = try ExerciseLibrary(data: Self.data(ExerciseLibrary.resourceName), additions: Self.data(ExerciseLibrary.additionsResourceName))
        for key in ExerciseAliases.byKey.keys.sorted() { #expect(both.definition(forKey: key) != nil, "alias key \(key)") }
        for key in ExerciseCollections.crossFit.sorted() { #expect(both.definition(forKey: key) != nil, "CrossFit key \(key)") }
        for key in ExerciseCollections.common { #expect(both.definition(forKey: key) != nil, "common key \(key)") }
        // One alias never names two exercises.
        var owners: [String: String] = [:]
        for (key, aliases) in ExerciseAliases.byKey {
            for alias in aliases {
                let compact = ExerciseName.compact(alias)
                #expect(owners[compact].map { $0 == key } ?? true, "\(alias) names \(owners[compact] ?? "") and \(key)")
                owners[compact] = key
            }
        }
    }

    @Test func anAdditionThatRepeatsADatasetIdIsRefused() {
        let dataset = #"[{"id":"Plank","name":"Plank","category":"strength","primaryMuscles":["abdominals"],"secondaryMuscles":[]}]"#
        let repeat_ = #"[{"id":"Plank","name":"Plank again","category":"strength","primaryMuscles":["abdominals"],"secondaryMuscles":[]}]"#
        #expect(throws: ExerciseLibraryError.duplicateKey("Plank")) {
            try ExerciseLibrary(data: Data(dataset.utf8), additions: Data(repeat_.utf8))
        }
        #expect(throws: ExerciseLibraryError.malformedData) {
            try ExerciseLibrary(data: Data(dataset.utf8), additions: Data("[]".utf8))
        }
    }
}

extension BundledExerciseAdditionsTests {
    /// An alias that is another exercise's name would pull that exercise's history into the wrong lift.
    @Test func noAliasIsAnotherExercisesName() throws {
        let both = try ExerciseLibrary(data: Self.data(ExerciseLibrary.resourceName), additions: Self.data(ExerciseLibrary.additionsResourceName))
        var keysByName: [String: Set<String>] = [:]
        for exercise in both.all { keysByName[ExerciseName.compact(exercise.name), default: []].insert(exercise.key) }
        for (key, aliases) in ExerciseAliases.byKey {
            for alias in aliases {
                let owners = keysByName[ExerciseName.compact(alias)] ?? []
                #expect(owners.isEmpty || owners.contains(key), "\(alias) is the name of \(owners.sorted())")
            }
        }
    }
}
