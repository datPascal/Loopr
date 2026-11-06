import Foundation
import StorageKit

extension FoodStore {
    public func confirmConfiguration(target: FoodTargetSettings, allowance: FoodTrainingAllowance?, on date: Date, timeZoneIdentifier: String) throws {
        try target.validate(); try allowance?.validate()
        let fresh = try FoodDayRecord(dayStart: date, timeZoneIdentifier: timeZoneIdentifier)
        let payload = try JSONEncoder().encode(target)
        try database.write { db in
            var day = try Self.dayRecord(fresh.localDay, in: db) ?? fresh
            day.allowance = allowance
            try db.execute(sql: "INSERT INTO food_target(id, confirmed_at, payload) VALUES (?, ?, ?)",
                arguments: [target.id.uuidString, target.confirmedAt.timeIntervalSince1970, payload])
            try Self.saveDay(day, in: db)
        }
    }
    public func drinks(localDay: String? = nil) throws -> [FoodDrink] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM food_drink" + (localDay == nil ? "" : " WHERE local_day = ?") + " ORDER BY occurred_at, id",
                arguments: localDay.map { [$0] } ?? []).map(Self.decodeDrink)
        }
    }

    public func confirmDrink(_ drink: FoodDrink) throws {
        try drink.validate()
        let payload = try JSONEncoder().encode(drink)
        try database.write { db in
            try db.execute(sql: "INSERT INTO food_drink(id, local_day, occurred_at, payload) VALUES (?, ?, ?, ?)",
                arguments: [drink.id.uuidString, drink.localDay, drink.occurredAt.timeIntervalSince1970, payload])
            try Self.clearCompletion(for: drink.localDay, in: db)
            // A logged alcohol drink answers the question the other way, so an earlier "None today" no longer stands.
            if drink.kind == .alcohol, var day = try Self.dayRecord(drink.localDay, in: db), day.noAlcoholAt != nil {
                day.noAlcoholAt = nil
                try Self.saveDay(day, in: db)
            }
        }
    }

    /// Deletes the drink. `alsoIn` runs in the same transaction with the drink's local day. Returns the day, or nil when
    /// the drink was already gone.
    @discardableResult
    public func deleteDrink(id: UUID, alsoIn: (Database, String) throws -> Void = { _, _ in }) throws -> String? {
        try database.write { db in
            guard let day = try String.fetchOne(db, sql: "SELECT local_day FROM food_drink WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            try db.execute(sql: "DELETE FROM food_drink WHERE id = ?", arguments: [id.uuidString])
            try Self.clearCompletion(for: day, in: db)
            try alsoIn(db, day)
            return day
        }
    }

    public func targetSettings(before end: Date? = nil) throws -> FoodTargetSettings? {
        try database.read { db in
            let payload = try Data.fetchOne(db,
                sql: "SELECT payload FROM food_target" + (end == nil ? "" : " WHERE confirmed_at < ?") + " ORDER BY confirmed_at DESC, id DESC LIMIT 1",
                arguments: end.map { [$0.timeIntervalSince1970] } ?? [])
            return try payload.map(Self.decodeTarget)
        }
    }

    public func confirmTarget(_ target: FoodTargetSettings) throws {
        try target.validate()
        let payload = try JSONEncoder().encode(target)
        try database.write { db in
            try db.execute(sql: "INSERT INTO food_target(id, confirmed_at, payload) VALUES (?, ?, ?)",
                arguments: [target.id.uuidString, target.confirmedAt.timeIntervalSince1970, payload])
        }
    }

    public func dayRecord(_ localDay: String) throws -> FoodDayRecord? {
        try database.read { db in try Self.dayRecord(localDay, in: db) }
    }

    public func confirmAllowance(_ allowance: FoodTrainingAllowance?, on date: Date, timeZoneIdentifier: String) throws {
        try allowance?.validate()
        let fresh = try FoodDayRecord(dayStart: date, timeZoneIdentifier: timeZoneIdentifier)
        try database.write { db in
            var day = try Self.dayRecord(fresh.localDay, in: db) ?? fresh
            day.allowance = allowance
            try Self.saveDay(day, in: db)
        }
    }

    public func confirmDayComplete(on date: Date, timeZoneIdentifier: String, at now: Date) throws {
        let fresh = try FoodDayRecord(dayStart: date, timeZoneIdentifier: timeZoneIdentifier, completedAt: now)
        try database.write { db in
            var day = try Self.dayRecord(fresh.localDay, in: db) ?? fresh
            day.completedAt = now
            try Self.saveDay(day, in: db)
        }
    }

    /// Marks the day "None today" for alcohol, or takes the mark back. The mark is the only way a day with no alcohol
    /// logged counts as alcohol-free.
    public func setNoAlcohol(_ marked: Bool, on date: Date, timeZoneIdentifier: String, at now: Date) throws {
        let fresh = try FoodDayRecord(dayStart: date, timeZoneIdentifier: timeZoneIdentifier)
        try database.write { db in
            var day = try Self.dayRecord(fresh.localDay, in: db) ?? fresh
            day.noAlcoholAt = marked ? now : nil
            try Self.saveDay(day, in: db)
        }
    }

    /// How many days from `firstDay` through `lastDay` the person finished. Reads the day records only.
    public func finishedDayCount(from firstDay: String, through lastDay: String) throws -> Int {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM food_day WHERE local_day BETWEEN ? AND ?", arguments: [firstDay, lastDay])
                .map(Self.decodeDay).filter { $0.completedAt != nil }.count
        }
    }

    public func reopenDay(_ localDay: String) throws {
        try database.write { db in try Self.clearCompletion(for: localDay, in: db) }
    }

    static func clearCompletion(for localDay: String, in db: Database) throws {
        guard var day = try dayRecord(localDay, in: db), day.completedAt != nil else { return }
        day.completedAt = nil
        try saveDay(day, in: db)
    }

    static func dayRecord(_ localDay: String, in db: Database) throws -> FoodDayRecord? {
        try Data.fetchOne(db, sql: "SELECT payload FROM food_day WHERE local_day = ?", arguments: [localDay]).map(decodeDay)
    }

    static func saveDay(_ day: FoodDayRecord, in db: Database) throws {
        try day.validate()
        try db.execute(sql: "INSERT INTO food_day(local_day, payload) VALUES (?, ?) ON CONFLICT(local_day) DO UPDATE SET payload = excluded.payload",
            arguments: [day.localDay, try JSONEncoder().encode(day)])
    }

    static func decodeDrink(_ data: Data) throws -> FoodDrink {
        let value = try JSONDecoder().decode(FoodDrink.self, from: data); try value.validate(); return value
    }
    static func decodeDay(_ data: Data) throws -> FoodDayRecord {
        let value = try JSONDecoder().decode(FoodDayRecord.self, from: data); try value.validate(); return value
    }
    // MARK: Weight

    /// Readings oldest first. `since` limits them to that time and later.
    public func weights(since: Date? = nil) throws -> [FoodWeightEntry] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM food_weight" + (since == nil ? "" : " WHERE measured_at >= ?") + " ORDER BY measured_at, id",
                arguments: since.map { [$0.timeIntervalSince1970] } ?? []).map(Self.decodeWeight)
        }
    }

    public func saveWeight(_ entry: FoodWeightEntry) throws {
        try database.write { db in try Self.saveWeight(entry, in: db) }
    }

    public func deleteWeight(id: UUID) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM food_weight WHERE id = ?", arguments: [id.uuidString]) }
    }

    static func saveWeight(_ entry: FoodWeightEntry, in db: Database) throws {
        try entry.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try db.execute(sql: "INSERT INTO food_weight(id, local_day, measured_at, payload) VALUES (?, ?, ?, ?) "
            + "ON CONFLICT(id) DO UPDATE SET local_day = excluded.local_day, measured_at = excluded.measured_at, payload = excluded.payload",
            arguments: [entry.id.uuidString, entry.localDay, entry.measuredAt.timeIntervalSince1970, try encoder.encode(entry)])
    }

    static func decodeWeight(_ data: Data) throws -> FoodWeightEntry {
        try JSONDecoder().decode(FoodWeightEntry.self, from: data)
    }

    static func decodeTarget(_ data: Data) throws -> FoodTargetSettings {
        let value = try JSONDecoder().decode(FoodTargetSettings.self, from: data); try value.validate(); return value
    }
}
