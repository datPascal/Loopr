import Foundation
import StorageKit

/// Confirmed meals and their photo bytes share one SQLite transaction in the
/// app container. Backups cannot capture a meal without its photo, and a crash
/// cannot leave a loose photo behind. Screens load photo bytes only on demand.
public final class FoodStore: Sendable {
    let database: StorageDatabase
    public init(database: StorageDatabase) { self.database = database }

    public func meals(localDay: String? = nil) throws -> [FoodMeal] {
        try database.read { db in
            let payloads: [Data]
            if let localDay {
                payloads = try Data.fetchAll(db, sql: "SELECT payload FROM food_meal WHERE local_day = ? ORDER BY occurred_at, id", arguments: [localDay])
            } else {
                payloads = try Data.fetchAll(db, sql: "SELECT payload FROM food_meal ORDER BY occurred_at, id")
            }
            return try payloads.map(Self.decode)
        }
    }

    public func meal(id: UUID) throws -> FoodMeal? {
        try database.read { db in try Self.meal(id: id, in: db) }
    }

    public func photo(id: UUID) throws -> FoodPhoto? {
        try database.read { db in try Self.photo(id: id, in: db) }
    }

    public func editDraft(id: UUID) throws -> FoodMealDraft {
        try database.read { db in
            guard let meal = try Self.meal(id: id, in: db) else { throw FoodError.missingMeal }
            let photos = try meal.photos.map { reference in
                guard let photo = try Self.photo(id: reference.id, in: db), photo.reference == reference else { throw FoodError.invalidPhoto }
                return photo
            }
            return .init(id: meal.id, slot: meal.slot, occurredAt: meal.occurredAt,
                timeZoneIdentifier: meal.timeZoneIdentifier, items: meal.items, photos: photos,
                note: meal.note, expectedRevision: meal.revision, photoTime: meal.photoTime)
        }
    }

    @discardableResult
    public func confirm(_ draft: FoodMealDraft, at date: Date) throws -> FoodMeal {
        try database.write { db in
            let previous = try Self.meal(id: draft.id, in: db)
            guard previous?.revision == draft.expectedRevision,
                  (previous?.revision ?? 0) < Int.max else { throw FoodError.staleRevision }
            var reviewed = draft
            for index in reviewed.items.indices {
                guard let old = previous?.items.first(where: { $0.id == reviewed.items[index].id }) else { continue }
                guard reviewed.items[index].provenance.starts(with: old.provenance) else { throw FoodError.invalidRecord }
                if old != reviewed.items[index], reviewed.items[index].provenance == old.provenance {
                    try reviewed.items[index].recordEdit(at: date)
                }
            }
            let meal = try FoodMeal(draft: reviewed, revision: (previous?.revision ?? 0) + 1, confirmedAt: date)
            try Self.clearCompletion(for: meal.localDay, in: db)
            if let previous, previous.localDay != meal.localDay { try Self.clearCompletion(for: previous.localDay, in: db) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(meal)
            try db.execute(sql: """
                INSERT INTO food_meal(id, local_day, occurred_at, revision, schema_version, payload)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET local_day = excluded.local_day,
                    occurred_at = excluded.occurred_at, revision = excluded.revision,
                    schema_version = excluded.schema_version, payload = excluded.payload
                """, arguments: [meal.id.uuidString, meal.localDay, meal.occurredAt.timeIntervalSince1970,
                    meal.revision, meal.schemaVersion, payload])
            try db.execute(sql: "DELETE FROM food_photo WHERE meal_id = ?", arguments: [meal.id.uuidString])
            for photo in reviewed.photos {
                try db.execute(sql: """
                    INSERT INTO food_photo(id, meal_id, media_type, captured_at, sha256, bytes)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [photo.reference.id.uuidString, meal.id.uuidString, photo.reference.type.rawValue,
                        photo.reference.capturedAt.timeIntervalSince1970, photo.reference.sha256, photo.bytes])
            }
            return meal
        }
    }

    /// Deletes the meal and its photos. `alsoIn` runs in the same transaction with the meal's local day, so the app can
    /// update what was derived from that day in one save. Returns the day.
    @discardableResult
    public func deleteMeal(id: UUID, expectedRevision: Int, alsoIn: (Database, String) throws -> Void = { _, _ in }) throws -> String {
        try database.write { db in
            guard let meal = try Self.meal(id: id, in: db) else { throw FoodError.missingMeal }
            guard meal.revision == expectedRevision else { throw FoodError.staleRevision }
            try Self.clearCompletion(for: meal.localDay, in: db)
            try db.execute(sql: "DELETE FROM food_meal WHERE id = ?", arguments: [id.uuidString])
            try alsoIn(db, meal.localDay)
            return meal.localDay
        }
    }

    public func deleteDay(_ localDay: String) throws {
        try database.write { db in try Self.deleteDay(localDay, in: db) }
    }

    public func deleteAll() throws {
        try database.write { db in try Self.deleteAll(in: db) }
    }

    public static func deleteDay(_ localDay: String, in db: Database) throws {
        for table in ["food_meal", "food_drink", "food_day", "food_weight"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE local_day = ?", arguments: [localDay])
        }
    }

    public static func deleteAll(in db: Database) throws {
        for table in ["food_meal", "food_drink", "food_day", "food_target", "food_product_cache", "food_product_cache_epoch", "food_favorite", "food_weight"] { try db.execute(sql: "DELETE FROM \(table)") }
    }

    public func exportArchive(localDay: String? = nil) throws -> FoodArchive {
        try database.read { db in
            let payloads = try Data.fetchAll(db,
                sql: "SELECT payload FROM food_meal" + (localDay == nil ? "" : " WHERE local_day = ?") + " ORDER BY occurred_at, id",
                arguments: localDay.map { [$0] } ?? [])
            let meals = try payloads.map(Self.decode)
            let photos = try meals.flatMap(\.photos).map { reference in
                guard let photo = try Self.photo(id: reference.id, in: db), photo.reference == reference else { throw FoodError.invalidPhoto }
                return photo
            }
            let condition = localDay == nil ? "" : " WHERE local_day = ?"
            let arguments: StatementArguments = localDay.map { [$0] } ?? []
            let drinks = try Data.fetchAll(db, sql: "SELECT payload FROM food_drink" + condition + " ORDER BY occurred_at, id", arguments: arguments).map(Self.decodeDrink)
            let days = try Data.fetchAll(db, sql: "SELECT payload FROM food_day" + condition + " ORDER BY local_day", arguments: arguments).map(Self.decodeDay)
            let targets = try Data.fetchAll(db, sql: "SELECT payload FROM food_target ORDER BY confirmed_at, id").map(Self.decodeTarget)
            let favorites = localDay == nil ? try Data.fetchAll(db, sql: "SELECT payload FROM food_favorite ORDER BY confirmed_at DESC, id").map(Self.decodeFavorite) : []
            let weights = try Data.fetchAll(db, sql: "SELECT payload FROM food_weight" + condition + " ORDER BY measured_at, id", arguments: arguments).map(Self.decodeWeight)
            return FoodArchive(meals: meals, photos: photos, drinks: drinks, days: days, targets: targets, favorites: favorites, weights: weights)
        }
    }

    public func restore(_ archive: FoodArchive) throws {
        try archive.validate()
        try database.write { db in try Self.restore(archive, in: db) }
    }

    /// The caller owns the transaction when restoring several product domains.
    /// Validation finishes before deletion; any insert failure rolls back both.
    public static func restore(_ archive: FoodArchive, in db: Database) throws {
        try archive.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try archive.meals.map { ($0, try encoder.encode($0)) }
        try Self.deleteAll(in: db)
        for (meal, payload) in encoded {
            try db.execute(sql: "INSERT INTO food_meal VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [meal.id.uuidString, meal.localDay, meal.occurredAt.timeIntervalSince1970,
                    meal.revision, meal.schemaVersion, payload])
        }
        let owners = Dictionary(uniqueKeysWithValues: archive.meals.flatMap { meal in meal.photos.map { ($0.id, meal.id) } })
        for photo in archive.photos {
            guard let owner = owners[photo.reference.id] else { throw FoodError.invalidPhoto }
            try db.execute(sql: "INSERT INTO food_photo VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [photo.reference.id.uuidString, owner.uuidString, photo.reference.type.rawValue,
                    photo.reference.capturedAt.timeIntervalSince1970, photo.reference.sha256, photo.bytes])
        }
        for drink in archive.drinks {
            try db.execute(sql: "INSERT INTO food_drink VALUES (?, ?, ?, ?)", arguments: [drink.id.uuidString,
                drink.localDay, drink.occurredAt.timeIntervalSince1970, try encoder.encode(drink)])
        }
        for day in archive.days { try Self.saveDay(day, in: db) }
        for favorite in archive.favorites {
            try db.execute(sql: "INSERT INTO food_favorite VALUES (?, ?, ?)", arguments: [favorite.id.uuidString,
                favorite.confirmedAt.timeIntervalSince1970, try encoder.encode(favorite)])
        }
        for target in archive.targets {
            try db.execute(sql: "INSERT INTO food_target VALUES (?, ?, ?)",
                arguments: [target.id.uuidString, target.confirmedAt.timeIntervalSince1970, try encoder.encode(target)])
        }
        for weight in archive.weights { try Self.saveWeight(weight, in: db) }
    }

    private static func decode(_ data: Data) throws -> FoodMeal {
        let result = try JSONDecoder().decode(FoodMeal.self, from: data)
        try result.validate()
        return result
    }

    private static func meal(id: UUID, in db: Database) throws -> FoodMeal? {
        try Data.fetchOne(db, sql: "SELECT payload FROM food_meal WHERE id = ?", arguments: [id.uuidString]).map(decode)
    }

    private static func photo(id: UUID, in db: Database) throws -> FoodPhoto? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM food_photo WHERE id = ?", arguments: [id.uuidString]) else { return nil }
        guard let type = FoodPhotoType(rawValue: row["media_type"]) else { throw FoodError.invalidPhoto }
        let result = try FoodPhoto(id: id, type: type, capturedAt: Date(timeIntervalSince1970: row["captured_at"]), bytes: row["bytes"])
        guard result.reference.sha256 == row["sha256"] as String else { throw FoodError.invalidPhoto }
        return result
    }
}
