import Foundation
import StorageKit

/// Supplement stacks, the medication lane and their taken ticks, stored by `storage-019-food-longevity`.
///
/// The two lanes share tables but never an API: `supplements()` and `medication()` return different types, and a tick
/// call reads its lane from the item. Deleting an item deletes its ticks. Deleting one local day of food data deletes
/// that day's ticks and keeps the items.
public final class SupplementStore: Sendable {
    let database: StorageDatabase
    public init(database: StorageDatabase) { self.database = database }

    // MARK: Items

    public func supplements() throws -> [SupplementItem] {
        try database.read { db in try Self.items(.supplement, SupplementItem.self, in: db) }
    }

    public func medication() throws -> [MedicationItem] {
        try database.read { db in try Self.items(.medication, MedicationItem.self, in: db) }
    }

    /// A key no other item in the lane uses: the name's slug, then `-2`, `-3`.
    public func uniqueKey(forName name: String, lane: StackLane) throws -> String {
        let base = StackKey.slug(name)
        return try database.read { db in
            let taken = Set(try String.fetchAll(db, sql: "SELECT item_key FROM supplement_item WHERE lane = ?", arguments: [lane.rawValue]))
            var candidate = base, number = 2
            while taken.contains(candidate) { candidate = "\(base)-\(number)"; number += 1 }
            return candidate
        }
    }

    /// Inserts the item or replaces the one with its id. The key never changes after the first save.
    public func save(_ item: SupplementItem) throws {
        try item.validate()
        try write(lane: .supplement, id: item.id, key: item.key, sortOrder: item.sortOrder, isActive: item.isActive,
                  startDay: item.startDay, createdAt: item.createdAt, payload: Self.encode(item))
    }

    public func save(_ item: MedicationItem) throws {
        try item.validate()
        try write(lane: .medication, id: item.id, key: item.key, sortOrder: item.sortOrder, isActive: item.isActive,
                  startDay: item.startDay, createdAt: item.createdAt, payload: Self.encode(item))
    }

    private func write(lane: StackLane, id: UUID, key: String, sortOrder: Int, isActive: Bool, startDay: String,
                       createdAt: Date, payload: Data) throws {
        try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT lane, item_key FROM supplement_item WHERE id = ?", arguments: [id.uuidString]) {
                guard (row["lane"] as String) == lane.rawValue else { throw StackError.wrongLane }
                guard (row["item_key"] as String) == key else { throw StackError.invalidItem }
            }
            let clash = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM supplement_item WHERE lane = ? AND item_key = ? AND id <> ?",
                arguments: [lane.rawValue, key, id.uuidString]) ?? 0
            guard clash == 0 else { throw StackError.duplicateKey }
            try db.execute(sql: """
                INSERT INTO supplement_item(id, lane, item_key, sort_order, is_active, start_day, created_at, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET sort_order = excluded.sort_order, is_active = excluded.is_active,
                    start_day = excluded.start_day, payload = excluded.payload
                """, arguments: [id.uuidString, lane.rawValue, key, sortOrder, isActive ? 1 : 0, startDay,
                                 createdAt.timeIntervalSince1970, payload])
        }
    }

    /// Pauses or resumes an item of either lane. A paused item is not due and cannot be ticked; its history stays.
    public func setActive(_ active: Bool, itemID: UUID) throws {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT lane, payload FROM supplement_item WHERE id = ?", arguments: [itemID.uuidString]),
                  let lane = StackLane(rawValue: row["lane"]) else { throw StackError.missingItem }
            let data: Data = row["payload"]
            let payload: Data
            switch lane {
            case .supplement:
                var item = try Self.decode(SupplementItem.self, data); item.isActive = active; payload = try Self.encode(item)
            case .medication:
                var item = try Self.decode(MedicationItem.self, data); item.isActive = active; payload = try Self.encode(item)
            }
            try db.execute(sql: "UPDATE supplement_item SET is_active = ?, payload = ? WHERE id = ?",
                arguments: [active ? 1 : 0, payload, itemID.uuidString])
        }
    }

    /// Deletes the item and its ticks. Returns false when there was no such item.
    @discardableResult
    public func deleteItem(id: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM supplement_item WHERE id = ?", arguments: [id.uuidString])
            return db.changesCount > 0
        }
    }

    // MARK: Ticks

    /// Records a dose as taken or skipped. Ticking the same state again changes nothing: the first time and note stay.
    /// Ticking the other state replaces the record. Throws for a paused item, a slot the item is not scheduled for, or
    /// a day that does not exist.
    @discardableResult
    public func record(_ state: StackTickState, itemID: UUID, day: String, slot: StackSlot, at date: Date,
                       note: String? = nil) throws -> StackTick {
        guard FoodLocalDay.daysSinceEpoch(day) != nil else { throw StackError.invalidDay }
        guard date.timeIntervalSince1970.isFinite else { throw StackError.invalidTick }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = trimmed?.isEmpty == false ? trimmed : nil
        guard cleanNote.map({ $0.count <= 500 }) != false else { throw StackError.invalidTick }
        return try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT lane, is_active, payload FROM supplement_item WHERE id = ?", arguments: [itemID.uuidString]),
                  let lane = StackLane(rawValue: row["lane"]) else { throw StackError.missingItem }
            let data: Data = row["payload"]
            let schedule: StackSchedule
            switch lane {
            case .supplement: schedule = try Self.decode(SupplementItem.self, data).schedule
            case .medication: schedule = try Self.decode(MedicationItem.self, data).schedule
            }
            guard (row["is_active"] as Int) == 1 else { throw StackError.itemPaused }
            guard schedule.includes(slot) else { throw StackError.slotNotScheduled }
            if let existing = try Self.tick(itemID: itemID, day: day, slot: slot, in: db), existing.state == state { return existing }
            try db.execute(sql: """
                INSERT INTO supplement_tick(item_id, local_day, slot, state, recorded_at, note) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(item_id, local_day, slot) DO UPDATE SET state = excluded.state,
                    recorded_at = excluded.recorded_at, note = excluded.note
                """, arguments: [itemID.uuidString, day, slot.rawValue, state.rawValue, date.timeIntervalSince1970, cleanNote])
            return StackTick(itemID: itemID, localDay: day, slot: slot, state: state, recordedAt: date, note: cleanNote)
        }
    }

    /// Takes a record away, so the dose reads "not recorded" again. Returns false when there was none.
    @discardableResult
    public func clearTick(itemID: UUID, day: String, slot: StackSlot) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM supplement_tick WHERE item_id = ? AND local_day = ? AND slot = ?",
                arguments: [itemID.uuidString, day, slot.rawValue])
            return db.changesCount > 0
        }
    }

    public func tick(itemID: UUID, day: String, slot: StackSlot) throws -> StackTick? {
        try database.read { db in try Self.tick(itemID: itemID, day: day, slot: slot, in: db) }
    }

    /// Ticks of one lane on one day.
    public func ticks(lane: StackLane, localDay: String) throws -> [StackTick] {
        try database.read { db in try Self.ticks(lane: lane, from: localDay, through: localDay, in: db) }
    }

    // MARK: Days

    public func supplementDay(_ localDay: String) throws -> StackDay {
        try database.read { db in
            StackDay(localDay: localDay, supplements: try Self.items(.supplement, SupplementItem.self, in: db),
                     ticks: try Self.ticks(lane: .supplement, from: localDay, through: localDay, in: db))
        }
    }

    public func medicationDay(_ localDay: String) throws -> StackDay {
        try database.read { db in
            StackDay(localDay: localDay, medication: try Self.items(.medication, MedicationItem.self, in: db),
                     ticks: try Self.ticks(lane: .medication, from: localDay, through: localDay, in: db))
        }
    }

    /// One `StackDay` per local day from `first` through `last`, oldest first, read in one snapshot. At most 400 days.
    public func supplementDays(from first: String, through last: String) throws -> [StackDay] {
        let days = try Self.days(from: first, through: last)
        return try database.read { db in
            let items = try Self.items(.supplement, SupplementItem.self, in: db)
            let ticks = try Self.ticks(lane: .supplement, from: first, through: last, in: db)
            return days.map { StackDay(localDay: $0, supplements: items, ticks: ticks) }
        }
    }

    public func medicationDays(from first: String, through last: String) throws -> [StackDay] {
        let days = try Self.days(from: first, through: last)
        return try database.read { db in
            let items = try Self.items(.medication, MedicationItem.self, in: db)
            let ticks = try Self.ticks(lane: .medication, from: first, through: last, in: db)
            return days.map { StackDay(localDay: $0, medication: items, ticks: ticks) }
        }
    }

    // MARK: Plumbing

    static func days(from first: String, through last: String) throws -> [String] {
        guard let start = FoodLocalDay.daysSinceEpoch(first), let end = FoodLocalDay.daysSinceEpoch(last),
              start <= end, end - start < 400 else { throw StackError.invalidDay }
        return (start...end).map { FoodLocalDay.string(daysSinceEpoch: $0) }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw StackError.corruptRecord }
    }

    private static func items<T: Decodable>(_ lane: StackLane, _ type: T.Type, in db: Database) throws -> [T] {
        try Data.fetchAll(db, sql: "SELECT payload FROM supplement_item WHERE lane = ? ORDER BY sort_order, created_at, item_key",
                          arguments: [lane.rawValue]).map { data in
            let value = try decode(type, data)
            if let item = value as? SupplementItem { try item.validate() }
            if let item = value as? MedicationItem { try item.validate() }
            return value
        }
    }

    private static func tick(itemID: UUID, day: String, slot: StackSlot, in db: Database) throws -> StackTick? {
        try Row.fetchOne(db, sql: "SELECT item_id, local_day, slot, state, recorded_at, note FROM supplement_tick WHERE item_id = ? AND local_day = ? AND slot = ?",
                         arguments: [itemID.uuidString, day, slot.rawValue]).map(Self.tick(from:))
    }

    private static func ticks(lane: StackLane, from first: String, through last: String, in db: Database) throws -> [StackTick] {
        try Row.fetchAll(db, sql: """
            SELECT t.item_id, t.local_day, t.slot, t.state, t.recorded_at, t.note
            FROM supplement_tick t JOIN supplement_item i ON i.id = t.item_id
            WHERE i.lane = ? AND t.local_day BETWEEN ? AND ? ORDER BY t.local_day, t.slot, t.item_id
            """, arguments: [lane.rawValue, first, last]).map(Self.tick(from:))
    }

    private static func tick(from row: Row) throws -> StackTick {
        guard let id = UUID(uuidString: row["item_id"]), let slot = StackSlot(rawValue: row["slot"]),
              let state = StackTickState(rawValue: row["state"]) else { throw StackError.corruptRecord }
        return StackTick(itemID: id, localDay: row["local_day"], slot: slot, state: state,
                         recordedAt: Date(timeIntervalSince1970: row["recorded_at"]), note: row["note"])
    }
}
