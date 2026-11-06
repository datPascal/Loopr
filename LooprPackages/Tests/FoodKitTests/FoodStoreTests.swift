import Foundation
import FoodKit
import StorageKit
import Testing

private final class FoodTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodKitTests-\(UUID().uuidString)")
    let database: StorageDatabase
    var store: FoodStore { FoodStore(database: database) }
    init() throws { database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"), applicationVersion: "food-tests") }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

private let date = Date(timeIntervalSince1970: 1_700_000_000)
private func item(source: FoodCaptureSource = .typed) -> FoodItem {
    .init(name: "Rice", amount: 180, unit: .grams, nutrients: .init([.energy: 234, .protein: 4, .caffeine: 0]),
          provenance: [.init(source: source, recordedAt: date,
            provider: source == .photoAI ? "anthropic" : nil, model: source == .photoAI ? "recorded-model" : nil,
            barcode: source == .barcode ? "1234567890123" : nil, confidence: source == .photoAI ? .check : nil)])
}
private func photo(id: UUID = UUID()) throws -> FoodPhoto {
    let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9mQAAAAASUVORK5CYII="))
    return try FoodPhoto(id: id, type: .png, capturedAt: date.addingTimeInterval(-3_600), bytes: bytes)
}
private func draft(id: UUID = UUID(), photos: [FoodPhoto] = []) -> FoodMealDraft {
    .init(id: id, slot: .lunch, occurredAt: date, timeZoneIdentifier: "Australia/Perth", items: [item()], photos: photos)
}

struct FoodStoreTests {
    @Test func draftDoesNotSaveAndConfirmationSurvivesRestartWithPhotoAndProvenance() throws {
        let context = try FoodTestDatabase()
        var value = draft(photos: [try photo()]); value.items = [item(source: .photoAI), item(source: .barcode)]
        #expect(try context.store.meals().isEmpty)
        #expect(try context.database.tableRowCounts()["food_photo"] == 0)
        let saved = try context.store.confirm(value, at: date)
        try context.database.databasePool.close()
        let reopened = try StorageDatabase(path: context.database.path, applicationVersion: "food-tests")
        defer { try? reopened.databasePool.close() }
        let store = FoodStore(database: reopened)
        #expect(try store.meal(id: saved.id) == saved)
        #expect(try store.editDraft(id: saved.id).photos == value.photos)
        #expect(saved.photos.first?.capturedAt == date.addingTimeInterval(-3_600))
        #expect(saved.localDay == "2023-11-15")
        #expect(saved.items[0].confidence == .check)
        #expect(saved.items[1].provenance[0].barcode == "1234567890123")
    }

    @Test func allSourcesAndAllNutrientsRoundTripWithoutTurningMissingIntoZero() throws {
        let context = try FoodTestDatabase()
        var value = draft()
        value.items = [FoodCaptureSource.photoAI, .barcode, .label, .typed, .voice, .manualEdit].map { item(source: $0) }
        value.items[0].nutrients = .init(Dictionary(uniqueKeysWithValues: FoodNutrient.allCases.enumerated().map { ($0.element, Double($0.offset)) }))
        let saved = try context.store.confirm(value, at: date)
        #expect(try context.store.meals().first?.items == value.items)
        let caffeine = FoodNutrientTotal(.caffeine, items: saved.items)
        #expect(caffeine.isComplete)
        let fibre = FoodNutrientTotal(.fibre, items: saved.items)
        #expect(fibre.knownItems == 1 && fibre.totalItems == 6 && !fibre.isComplete)
        #expect(FoodNutrientTotal(.fat, items: [item()]).knownValue == nil)
        #expect(FoodNutrientTotal(.caffeine, items: [item()]).knownValue == 0)
        #expect(!FoodNutrientTotal(.caffeine, items: []).isComplete)
        var overflowing = item(); overflowing.nutrients[.energy] = .greatestFiniteMagnitude
        #expect(!FoodNutrientTotal(.energy, items: [overflowing, overflowing]).isComplete)
    }

    @Test func editsKeepOriginalEvidenceAndRejectStaleOrReplacedProvenance() throws {
        let context = try FoodTestDatabase()
        var value = draft(); value.items = [item(source: .photoAI)]
        let first = try context.store.confirm(value, at: date)
        var edit = try context.store.editDraft(id: first.id)
        let stale = edit
        try edit.items[0].changeAmount(to: 90, at: date.addingTimeInterval(60))
        let second = try context.store.confirm(edit, at: date.addingTimeInterval(60))
        #expect(second.items[0].nutrients[.energy] == 117)
        #expect(second.items[0].provenance.map(\.source) == [.photoAI, .manualEdit])
        #expect(second.items[0].isEstimated)
        #expect(throws: FoodError.staleRevision) { try context.store.confirm(stale, at: date) }
        #expect(throws: FoodError.staleRevision) { try context.store.deleteMeal(id: first.id, expectedRevision: 1) }
        var replacement = try context.store.editDraft(id: first.id)
        replacement.items[0] = .init(id: first.items[0].id, name: "Rice", amount: 90, unit: .grams,
            provenance: [.init(source: .manualEdit, recordedAt: date)])
        #expect(throws: FoodError.invalidRecord) { try context.store.confirm(replacement, at: date) }
        #expect(try context.store.meal(id: first.id) == second)
    }

    @Test func validationAndPhotoWriteFailureRollBackWholeConfirmation() throws {
        let context = try FoodTestDatabase()
        let existing = try context.store.confirm(draft(photos: [try photo()]), at: date)
        try context.database.write { db in
            try db.execute(sql: "CREATE TRIGGER food_photo_fail BEFORE INSERT ON food_photo BEGIN SELECT RAISE(ABORT, 'injected photo failure'); END")
        }
        var edit = try context.store.editDraft(id: existing.id)
        edit.items[0].name = "Brown rice"
        #expect(throws: (any Error).self) { try context.store.confirm(edit, at: date) }
        #expect(try context.store.meal(id: existing.id) == existing)
        #expect(try context.store.photo(id: existing.photos[0].id) != nil)
        #expect(throws: (any Error).self) { try context.store.confirm(draft(photos: [try photo()]), at: date) }
        #expect(try context.store.meals().count == 1)
        var invalid = draft(); invalid.items[0].nutrients[.energy] = -1
        #expect(throws: FoodError.invalidRecord) { try context.store.confirm(invalid, at: date) }
        invalid.items[0].nutrients[.energy] = .nan
        #expect(throws: FoodError.invalidRecord) { try context.store.confirm(invalid, at: date) }
        #expect(try context.database.tableRowCounts()["food_photo"] == 1)
    }

    @Test func migrationFromPreFoodBuildPreservesExistingDocumentsAndLedger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodMigration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("old.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        let migrator = StorageMigrations.makeMigrator(applicationVersion: "previous-build")
        try migrator.migrate(queue, upTo: "storage-009-v24-skin-temperature")
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE loopr_product_document(namespace TEXT, document_key TEXT, payload BLOB, updated_at REAL, PRIMARY KEY(namespace, document_key))")
            try db.execute(sql: "INSERT INTO loopr_product_document VALUES ('journal', 'entry.old', ?, 1)", arguments: [Data("old journal".utf8)])
            try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, value, updated_at, source) VALUES ('2023-11-14', 'hrv', 57, 1, 'band')")
        }
        try queue.close()
        let upgraded = try StorageDatabase(url: url, applicationVersion: "food-build")
        defer { try? upgraded.databasePool.close() }
        #expect(try StorageDocumentStore(database: upgraded, namespace: "journal").readData(key: "entry.old") == Data("old journal".utf8))
        #expect(try upgraded.tableRowCounts()["metric_series"] == 1)
        #expect(try FoodStore(database: upgraded).meals().isEmpty)
        #expect(try upgraded.schemaMetadata().last?.migrationIdentifier == StorageMigrationIdentifier.routineCheckAnsweredFrom)
        #expect(try StorageMigrationHarness.verifyAllRegisteredVersions(directory: root.appendingPathComponent("harness")).allSatisfy(\.schemaMatchesCurrent))
    }

    @Test func databaseExportRestoreIncludesPhotosAndEveryItem() throws {
        let context = try FoodTestDatabase()
        let saved = try context.store.confirm(draft(photos: [try photo()]), at: date)
        let backup = try context.database.export(to: context.root.appendingPathComponent("backup.sqlite"))
        try context.store.deleteAll()
        #expect(try context.database.tableRowCounts()["food_photo"] == 0)
        let restored = try context.database.restore(from: backup)
        defer { try? restored.databasePool.close() }
        let store = FoodStore(database: restored)
        #expect(try store.meals() == [saved])
        #expect(try store.editDraft(id: saved.id).photos[0].reference == saved.photos[0])
    }

    @Test func dayAndAccountDeletionCascadePhotosAndPreserveOtherDays() throws {
        let context = try FoodTestDatabase()
        let first = try context.store.confirm(draft(photos: [try photo()]), at: date)
        var other = draft(photos: [try photo()]); other.occurredAt = date.addingTimeInterval(86_400)
        let second = try context.store.confirm(other, at: date)
        try context.database.delete(localDay: first.localDay)
        #expect(try context.store.meals() == [second])
        #expect(try context.store.photo(id: first.photos[0].id) == nil)
        #expect(try context.store.photo(id: second.photos[0].id) != nil)
        try context.database.deleteAllAccountData()
        #expect(try context.store.meals().isEmpty)
        #expect(try context.database.tableRowCounts()["food_photo"] == 0)
    }

    @Test func photoCannotBeSharedAcrossMealsAndInvalidBytesNeverPersist() throws {
        let context = try FoodTestDatabase()
        let image = try photo()
        let saved = try context.store.confirm(draft(photos: [image]), at: date)
        #expect(throws: (any Error).self) { try context.store.confirm(draft(photos: [image]), at: date) }
        #expect(try context.store.meals() == [saved])
        #expect(throws: FoodError.invalidPhoto) { try FoodPhoto(type: .jpeg, capturedAt: date, bytes: image.bytes) }
        #expect(throws: FoodError.invalidPhoto) { try FoodPhoto(type: .png, capturedAt: date, bytes: Data("not a photo".utf8)) }
        try context.database.write { db in try db.execute(sql: "UPDATE food_photo SET sha256 = 'changed'") }
        #expect(throws: FoodError.invalidPhoto) { try context.store.photo(id: image.reference.id) }
    }

    @Test func missingAIAndBarcodeProvenanceIsRejectedAndUnknownSchemaIsNotEmpty() throws {
        let context = try FoodTestDatabase()
        for source in [FoodCaptureSource.photoAI, .barcode] {
            var value = draft()
            value.items = [.init(name: "Rice", amount: 1, unit: .serving, provenance: [.init(source: source, recordedAt: date)])]
            #expect(throws: FoodError.invalidRecord) { try context.store.confirm(value, at: date) }
        }
        let saved = try context.store.confirm(draft(), at: date)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["schemaVersion"] = 99
        let payload = try JSONSerialization.data(withJSONObject: object)
        try context.database.write { db in try db.execute(sql: "UPDATE food_meal SET payload = ?, schema_version = 99", arguments: [payload]) }
        #expect(throws: FoodError.unsupportedVersion(99)) { try context.store.meals() }
        #expect(throws: FoodError.unsupportedVersion(99)) { try context.store.confirm(draft(id: saved.id), at: date) }
    }

    @Test func localDayUsesStoredZoneAndRejectsUnknownZone() throws {
        #expect(try FoodMeal.day(at: date, timeZoneIdentifier: "Australia/Perth") == "2023-11-15")
        #expect(try FoodMeal.day(at: date, timeZoneIdentifier: "UTC") == "2023-11-14")
        #expect(throws: FoodError.invalidRecord) { try FoodMeal.day(at: date, timeZoneIdentifier: "not-a-zone") }
        #expect(throws: FoodError.invalidRecord) { try FoodMeal.day(at: Date(timeIntervalSince1970: .infinity), timeZoneIdentifier: "UTC") }
    }
}

struct FoodWeightStoreTests {
    @Test func weightsSaveExportRestoreAndLeaveWithTheirDay() throws {
        let context = try FoodTestDatabase()
        let first = try FoodWeightEntry(measuredAt: date, timeZoneIdentifier: "UTC", kilograms: 82.4)
        let second = try FoodWeightEntry(measuredAt: date.addingTimeInterval(86_400), timeZoneIdentifier: "UTC", kilograms: 82.0)
        try context.store.saveWeight(second)
        try context.store.saveWeight(first)
        #expect(try context.store.weights().map(\.kilograms) == [82.4, 82.0], "oldest first")
        #expect(try context.store.weights(since: date.addingTimeInterval(3_600)).map(\.id) == [second.id])

        let plan = FoodGoalPlan(startWeightKg: 82.4, goalWeightKg: 78, paceKgPerWeek: 0.5, activity: .light)
        try context.store.confirmTarget(.init(goal: .lose, baseEnergy: 1_900, protein: 160, confirmedAt: date, plan: plan))
        let archive = try context.store.exportArchive()
        #expect(archive.weights.count == 2)
        #expect(archive.targets.first?.plan == plan)
        let decoded = try JSONDecoder().decode(FoodArchive.self, from: JSONEncoder().encode(archive))
        #expect(decoded == archive)

        let other = try FoodTestDatabase()
        try other.store.restore(archive)
        #expect(try other.store.weights().map(\.id) == [first.id, second.id])
        #expect(try other.store.targetSettings()?.plan == plan)

        try context.store.deleteDay(first.localDay)
        #expect(try context.store.weights().map(\.id) == [second.id])
        try context.store.deleteWeight(id: second.id)
        #expect(try context.store.weights().isEmpty)
    }

    @Test func targetsSavedBeforeThePlannerStillDecode() throws {
        let old = #"{"id":"6E0C7A62-6C8B-4B0B-9A7E-5C1F3D2B1A00","goal":"maintain","baseEnergy":2200,"adjustsForActiveEnergy":false,"confirmedAt":720000000}"#
        let decoded = try JSONDecoder().decode(FoodTargetSettings.self, from: Data(old.utf8))
        #expect(decoded.plan == nil && decoded.baseEnergy == 2_200)
    }

    @Test func csvWritesOneRowPerItemAndReading() throws {
        let context = try FoodTestDatabase()
        let meal = try context.store.confirm(draft(), at: date)
        let items = FoodCSV.items([meal]).split(separator: "\r\n").map(String.init)
        #expect(items.count == 2)
        #expect(items[1].hasPrefix("2023-11-15,06:13,lunch,Rice,180,grams,234,4,,,,,,0,,"))
        let weights = FoodCSV.weights([try FoodWeightEntry(measuredAt: date, timeZoneIdentifier: "UTC", kilograms: 80.25)])
        #expect(weights == "date,time,weight_kg\r\n2023-11-14,22:13,80.25\r\n")
    }
}
