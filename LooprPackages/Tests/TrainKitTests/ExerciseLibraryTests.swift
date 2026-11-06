import CryptoKit
import Foundation
import Testing
import TrainKit

struct ExerciseLibraryTests {
    private static let customID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    /// Small fixture in the trimmed dataset shape. Includes unknown values, nulls and an accented name.
    private static let fixture = """
    [
      {"id":"Barbell_Bench_Press","name":"Barbell Bench Press","category":"strength","equipment":"barbell","level":"intermediate","force":"push","mechanic":"compound","primaryMuscles":["chest"],"secondaryMuscles":["triceps","shoulders"]},
      {"id":"Dumbbell_Bench_Press","name":"Dumbbell Bench Press","category":"strength","equipment":"dumbbell","level":"beginner","force":"push","mechanic":"compound","primaryMuscles":["chest"],"secondaryMuscles":["triceps"]},
      {"id":"Incline_Bench_Press","name":"Incline Bench Press","category":"strength","equipment":"barbell","level":"intermediate","primaryMuscles":["shoulders"],"secondaryMuscles":["chest"]},
      {"id":"Bench_Dips","name":"Bench Dips","category":"strength","equipment":"body only","level":"beginner","primaryMuscles":["triceps"],"secondaryMuscles":[]},
      {"id":"Etirement_Ischio","name":"\u{00C9}tirement des ischio-jambiers","category":"stretching","equipment":null,"level":"beginner","primaryMuscles":["hamstrings"],"secondaryMuscles":["calves"]},
      {"id":"Mystery_Move","name":"Mystery Move","category":"mystery","equipment":"space hopper","level":"godlike","primaryMuscles":["neck"],"secondaryMuscles":[]},
      {"id":"Olympic_Clean","name":"Power Clean","category":"olympic weightlifting","equipment":"barbell","level":"expert","primaryMuscles":["quadriceps"],"secondaryMuscles":["lower back"]}
    ]
    """

    private func library(_ json: String = fixture) throws -> ExerciseLibrary {
        try ExerciseLibrary(data: Data(json.utf8))
    }

    private func names(_ list: [ExerciseDefinition]) -> [String] { list.map(\.name) }

    @Test func loadsEveryEntryOrderedByName() throws {
        let library = try library()
        #expect(library.count == 7)
        #expect(library.all.first?.name == "Barbell Bench Press")
        #expect(library.definition(forKey: "Bench_Dips")?.equipment == "body only")
        #expect(library.definition(forKey: "Bench_Dips")?.origin == .library)
        #expect(library.definition(forKey: "missing") == nil)
        #expect(library.definition(forKey: "Barbell_Bench_Press")?.secondaryMuscles == ["triceps", "shoulders"])
        #expect(library.muscles.contains("lower back"))
    }

    @Test func searchRanksPrefixThenWordStartThenContains() throws {
        let library = try library()
        #expect(names(library.search("bench")) == ["Bench Dips", "Barbell Bench Press", "Dumbbell Bench Press", "Incline Bench Press"])
        // Words in any order still match, ranked after a name prefix.
        #expect(names(library.search("press bench")) == ["Barbell Bench Press", "Dumbbell Bench Press", "Incline Bench Press"])
        // "ench" is inside a word, so it ranks last.
        #expect(names(library.search("ench")) == ["Barbell Bench Press", "Bench Dips", "Dumbbell Bench Press", "Incline Bench Press"])
        #expect(names(library.search("zzz")).isEmpty)
        #expect(names(library.search("bench", limit: 2)) == ["Bench Dips", "Barbell Bench Press"])
    }

    @Test func searchIgnoresCaseAndDiacritics() throws {
        let library = try library()
        #expect(names(library.search("etirement")) == ["\u{00C9}tirement des ischio-jambiers"])
        #expect(names(library.search("\u{00C9}TIR")) == ["\u{00C9}tirement des ischio-jambiers"])
        #expect(names(library.search("  BENCH DIPS  ")) == ["Bench Dips"])
    }

    @Test func blankSearchReturnsFilteredList() throws {
        let library = try library()
        #expect(library.search("   ").count == 7)
        #expect(names(library.search("", filter: .init(equipment: [.barbell]))) == ["Barbell Bench Press", "Incline Bench Press", "Power Clean"])
    }

    @Test func filtersByEquipmentMuscleAndCategory() throws {
        let library = try library()
        #expect(names(library.filtered(.init(equipment: [.dumbbell, .bodyOnly]))) == ["Bench Dips", "Dumbbell Bench Press"])
        // Primary muscles only by default.
        #expect(names(library.filtered(.init(muscles: ["Chest"]))) == ["Barbell Bench Press", "Dumbbell Bench Press"])
        #expect(names(library.filtered(.init(muscles: ["chest"], includeSecondaryMuscles: true)))
            == ["Barbell Bench Press", "Dumbbell Bench Press", "Incline Bench Press"])
        #expect(names(library.filtered(.init(categories: [.stretching]))) == ["\u{00C9}tirement des ischio-jambiers"])
        #expect(names(library.filtered(.init(equipment: [.barbell], muscles: ["shoulders"]))) == ["Incline Bench Press"])
        #expect(library.filtered(ExerciseFilter()).count == 7)
        #expect(ExerciseFilter().isEmpty)
        #expect(names(library.search("bench", filter: .init(equipment: [.barbell]))) == ["Barbell Bench Press", "Incline Bench Press"])
    }

    @Test func unknownValuesFallBackToOther() throws {
        let library = try library()
        let mystery = try #require(library.definition(forKey: "Mystery_Move"))
        #expect(mystery.category == "mystery")
        #expect(mystery.categoryKind == .other)
        #expect(mystery.equipmentKind == .other)
        #expect(mystery.levelKind == .other)
        // A missing equipment value also reads as other, so the "other" filter finds it.
        #expect(try #require(library.definition(forKey: "Etirement_Ischio")).equipmentKind == .other)
        #expect(names(library.filtered(.init(equipment: [.other]))) == ["\u{00C9}tirement des ischio-jambiers", "Mystery Move"])
        #expect(try #require(library.definition(forKey: "Olympic_Clean")).categoryKind == .olympicWeightlifting)
        #expect(ExerciseLevel(dataset: nil) == .other)
    }

    @Test func customExercisesMergeAndWinOnCollision() throws {
        let library = try library()
        let curl = ExerciseDefinition.custom(id: Self.customID, name: "Aardvark curl", equipment: "dumbbell", primaryMuscles: ["biceps"])
        let merged = try library.merged(withCustom: [curl])
        #expect(merged.count == 8)
        #expect(merged.all.first?.name == "Aardvark curl")
        #expect(merged.definition(forKey: curl.key)?.origin == .custom)
        #expect(curl.key.hasPrefix(ExerciseDefinition.customKeyPrefix))
        #expect(names(merged.search("aardvark")) == ["Aardvark curl"])
        #expect(library.count == 7)

        // Same key in the library and in custom data: the custom entry replaces it.
        let clash = "custom-\(Self.customID.uuidString)"
        let withClash = try ExerciseLibrary(definitions: [ExerciseDefinition(key: clash, name: "Library twin", category: "strength")])
        let replaced = try withClash.merged(withCustom: [curl])
        #expect(replaced.count == 1)
        #expect(replaced.definition(forKey: clash)?.name == "Aardvark curl")
        #expect(replaced.definition(forKey: clash)?.origin == .custom)

        // A later custom entry with the same key wins over an earlier one.
        var renamed = curl
        renamed.name = "Zebra curl"
        #expect(try library.merged(withCustom: [curl, renamed]).definition(forKey: curl.key)?.name == "Zebra curl")
    }

    @Test func mergeRejectsEntriesThatAreNotValidCustomExercises() throws {
        let library = try library()
        let notCustom = ExerciseDefinition(key: "Sneaky", name: "Sneaky", category: "strength")
        #expect(throws: ExerciseLibraryError.invalidCustomExercise("Sneaky")) { try library.merged(withCustom: [notCustom]) }
        var blank = ExerciseDefinition.custom(id: Self.customID, name: "Fine")
        blank.name = "   "
        #expect(throws: ExerciseLibraryError.invalidCustomExercise(blank.key)) { try library.merged(withCustom: [blank]) }
    }

    @Test func malformedDataThrowsTypedErrors() {
        let cases: [(String, ExerciseLibraryError)] = [
            ("not json", .malformedData),
            ("{}", .malformedData),
            ("[]", .malformedData),
            (#"[{"id":"A","name":"A","category":"strength","primaryMuscles":"chest","secondaryMuscles":[]}]"#, .malformedData),
            (#"[{"name":"A","category":"strength","primaryMuscles":[],"secondaryMuscles":[]}]"#, .malformedData),
            (#"[{"id":"A","name":"A","category":7,"primaryMuscles":[],"secondaryMuscles":[]}]"#, .malformedData),
            (#"[{"id":"","name":"A","category":"strength","primaryMuscles":[],"secondaryMuscles":[]}]"#, .invalidDefinition("")),
            (#"[{"id":"A","name":"  ","category":"strength","primaryMuscles":[],"secondaryMuscles":[]}]"#, .invalidDefinition("A")),
            (#"[{"id":"A","name":"One","category":"strength","primaryMuscles":[],"secondaryMuscles":[]},{"id":"A","name":"Two","category":"strength","primaryMuscles":[],"secondaryMuscles":[]}]"#, .duplicateKey("A"))
        ]
        for (json, expected) in cases {
            #expect(throws: expected, "\(json)") { try ExerciseLibrary(data: Data(json.utf8)) }
        }
        #expect(ExerciseLibraryError.malformedData.errorDescription?.isEmpty == false)
    }

    /// Reads the file that ships in the app and checks it against its provenance record.
    @Test func bundledDatasetDecodesCompletelyAndMatchesProvenance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Loopr/Loopr/Resources/ExerciseLibrary")
        let data = try Data(contentsOf: folder.appendingPathComponent("exercises.v1.json"))
        let provenanceData = try Data(contentsOf: folder.appendingPathComponent("exercises.v1.provenance.json"))
        let provenance = try #require(try JSONSerialization.jsonObject(with: provenanceData) as? [String: Any])
        let expectedCount = try #require(provenance["count"] as? Int)
        let expectedHash = try #require(provenance["outputSha256"] as? String)

        let library = try ExerciseLibrary(data: data)
        // Entries merged into another lift (`ExerciseAliases.mergedKeys`) are decoded but not listed.
        #expect(library.count == expectedCount - ExerciseAliases.mergedKeys.count)
        #expect(expectedCount > 800)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expectedHash)
        #expect(library.all.allSatisfy { $0.categoryKind != .other })
        #expect(library.all.allSatisfy { !$0.primaryMuscles.isEmpty })
        #expect(library.search("bench press").isEmpty == false)
    }
}
