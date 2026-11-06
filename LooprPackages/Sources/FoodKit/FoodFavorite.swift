import Foundation
import StorageKit

public struct FoodFavorite: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let items: [FoodItem]
    public let note: String
    public let confirmedAt: Date
    public init(id: UUID = UUID(), name: String, items: [FoodItem], note: String, confirmedAt: Date) {
        self.id = id; self.name = name; self.items = items; self.note = note; self.confirmedAt = confirmedAt
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 500,
              !items.isEmpty, items.count <= 100, Set(items.map(\.id)).count == items.count,
              note.count <= 10_000, confirmedAt.timeIntervalSince1970.isFinite else { throw FoodError.invalidRecord }
        for item in items { try item.validate() }
    }
    public func draft(slot: FoodMealSlot, at date: Date, timeZoneIdentifier: String) throws -> FoodMealDraft {
        try validate()
        let copied = items.map { $0.duplicated() }
        return .init(slot: slot, occurredAt: date, timeZoneIdentifier: timeZoneIdentifier, items: copied, note: note)
    }
}

public extension FoodStore {
    func favorites() throws -> [FoodFavorite] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM food_favorite ORDER BY confirmed_at DESC, id").map(Self.decodeFavorite)
        }
    }
    func confirmFavorite(_ favorite: FoodFavorite) throws {
        try favorite.validate()
        try database.write { db in
            try db.execute(sql: "INSERT INTO food_favorite VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET confirmed_at = excluded.confirmed_at, payload = excluded.payload",
                arguments: [favorite.id.uuidString, favorite.confirmedAt.timeIntervalSince1970, try JSONEncoder().encode(favorite)])
        }
    }
    func deleteFavorite(id: UUID) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM food_favorite WHERE id = ?", arguments: [id.uuidString]) }
    }
    internal static func decodeFavorite(_ bytes: Data) throws -> FoodFavorite {
        let value = try JSONDecoder().decode(FoodFavorite.self, from: bytes)
        try value.validate(); return value
    }
}
