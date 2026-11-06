import Foundation

// The supplement stacks and the medication lane (DEC-12.10). Supplements live in a morning and an evening stack.
// Medication has its own lane with its own types, so no list or API in this folder returns both together.

public enum StackLane: String, Codable, CaseIterable, Sendable {
    case supplement, medication
}

public enum StackSlot: String, Codable, CaseIterable, Comparable, Sendable {
    case morning, evening
    public var title: String { self == .morning ? "Morning" : "Evening" }
    public static func < (lhs: StackSlot, rhs: StackSlot) -> Bool { lhs == .morning && rhs == .evening }
}

/// When an item is taken. `both` means one dose in each stack.
public enum StackSchedule: String, Codable, CaseIterable, Sendable {
    case morning, evening, both
    public var slots: [StackSlot] {
        switch self { case .morning: [.morning]; case .evening: [.evening]; case .both: [.morning, .evening] }
    }
    public func includes(_ slot: StackSlot) -> Bool { slots.contains(slot) }
}

public enum SupplementForm: String, Codable, CaseIterable, Sendable {
    case capsule, tablet, softgel, powder, drop, liquid, gummy, other
    public var title: String { rawValue.capitalized }
}

public enum DoseUnit: String, Codable, CaseIterable, Sendable {
    case mg, mcg, g, ml, iu, drops, capsules, tablets, scoops, servings
    public var title: String { self == .iu ? "IU" : rawValue }
}

public struct DoseAmount: Codable, Equatable, Sendable {
    public let amount: Double
    public let unit: DoseUnit
    public init(amount: Double, unit: DoseUnit) { self.amount = amount; self.unit = unit }
    var isValid: Bool { amount.isFinite && amount > 0 && amount <= 1_000_000 }
    /// "2000 IU" or "2.5 g". Plain digits, never a locale's separator, because Ask reads it.
    public var text: String {
        let number = amount.rounded() == amount && amount < 1e9 ? String(Int(amount)) : String(format: "%g", amount)
        return number + " " + unit.title
    }
}

/// The two colours of a drawn capsule, as `#RRGGBB`. The screen draws it solid once the dose is taken.
public struct CapsuleColors: Codable, Equatable, Sendable {
    public let first: String
    public let second: String
    public init(first: String, second: String) { self.first = first; self.second = second }
    var isValid: Bool { Self.isHex(first) && Self.isHex(second) }
    private static func isHex(_ value: String) -> Bool {
        value.count == 7 && value.hasPrefix("#") && value.dropFirst().allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

public enum StackError: Error, Equatable, LocalizedError, Sendable {
    case invalidItem, duplicateKey, missingItem, wrongLane, itemPaused, slotNotScheduled, invalidDay, invalidTick, corruptRecord

    public var errorDescription: String? {
        switch self {
        case .invalidItem: "Check the name, dose and start day before saving."
        case .duplicateKey: "Another item in this list already uses that name."
        case .missingItem: "This item is no longer in your stack."
        case .wrongLane: "This item belongs to the other list."
        case .itemPaused: "This item is paused. Resume it to record a dose."
        case .slotNotScheduled: "This item is not scheduled for that part of the day."
        case .invalidDay: "That day is not valid."
        case .invalidTick: "That dose record is not valid."
        case .corruptRecord: "A saved stack record could not be read."
        }
    }
}

enum StackKey {
    /// A stable, lowercase key from a name: "Vitamin D3" becomes "vitamin-d3". Used in metric names.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased().replacingOccurrences(of: "ß", with: "ss")
        let folded = lowered.folding(options: .diacriticInsensitive, locale: nil)
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else { pendingDash = true }
        }
        let clipped = String(result.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return clipped.isEmpty ? "item" : clipped
    }

    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 48 && key.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }
}

/// One supplement in the morning or evening stack.
public struct SupplementItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// Stable identity used in Protocol metric names (`supplement_taken:<key>`). It does not change when the name does.
    public let key: String
    public var name: String
    public var dose: DoseAmount
    public var form: SupplementForm
    public var brand: String?
    public var colors: CapsuleColors?
    public var schedule: StackSchedule
    /// A paused item is not due on any day and cannot be ticked.
    public var isActive: Bool
    /// `yyyy-MM-dd`. The item is not due before this day.
    public var startDay: String
    public var sortOrder: Int
    public let createdAt: Date

    public init(id: UUID = UUID(), key: String? = nil, name: String, dose: DoseAmount, form: SupplementForm,
                brand: String? = nil, colors: CapsuleColors? = nil, schedule: StackSchedule, isActive: Bool = true,
                startDay: String, sortOrder: Int = 0, createdAt: Date) throws {
        self.id = id; self.key = key ?? StackKey.slug(name); self.name = name; self.dose = dose; self.form = form
        self.brand = brand; self.colors = colors; self.schedule = schedule; self.isActive = isActive
        self.startDay = startDay; self.sortOrder = sortOrder; self.createdAt = createdAt
        try validate()
    }

    public func validate() throws {
        guard StackKey.isValid(key), Self.validName(name), dose.isValid, brand.map({ $0.count <= 120 }) != false,
              brand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true,
              colors?.isValid != false, FoodLocalDay.daysSinceEpoch(startDay) != nil,
              createdAt.timeIntervalSince1970.isFinite, (0...100_000).contains(sortOrder) else { throw StackError.invalidItem }
    }
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
    }
}

/// One medicine in the medication lane. It is its own type on purpose: a screen draws the lane apart from the stack.
public struct MedicationItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let key: String
    public var name: String
    public var dose: DoseAmount
    public var prescriber: String?
    public var schedule: StackSchedule
    public var notes: String?
    public var isActive: Bool
    public var startDay: String
    public var sortOrder: Int
    public let createdAt: Date

    public init(id: UUID = UUID(), key: String? = nil, name: String, dose: DoseAmount, prescriber: String? = nil,
                schedule: StackSchedule, notes: String? = nil, isActive: Bool = true, startDay: String,
                sortOrder: Int = 0, createdAt: Date) throws {
        self.id = id; self.key = key ?? StackKey.slug(name); self.name = name; self.dose = dose
        self.prescriber = prescriber; self.schedule = schedule; self.notes = notes; self.isActive = isActive
        self.startDay = startDay; self.sortOrder = sortOrder; self.createdAt = createdAt
        try validate()
    }

    public func validate() throws {
        guard StackKey.isValid(key), SupplementItem.validName(name), dose.isValid,
              prescriber.map({ $0.count <= 200 && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false,
              notes.map({ $0.count <= 2_000 }) != false, FoodLocalDay.daysSinceEpoch(startDay) != nil,
              createdAt.timeIntervalSince1970.isFinite, (0...100_000).contains(sortOrder) else { throw StackError.invalidItem }
    }
}

public enum StackTickState: String, Codable, CaseIterable, Sendable {
    case taken, skipped
}

/// What a person recorded for one item, one day and one slot. No tick is "not recorded", never "skipped".
public struct StackTick: Equatable, Codable, Sendable {
    public let itemID: UUID
    public let localDay: String
    public let slot: StackSlot
    public let state: StackTickState
    /// When the person ticked it.
    public let recordedAt: Date
    public let note: String?
    public init(itemID: UUID, localDay: String, slot: StackSlot, state: StackTickState, recordedAt: Date, note: String? = nil) {
        self.itemID = itemID; self.localDay = localDay; self.slot = slot; self.state = state
        self.recordedAt = recordedAt; self.note = note
    }
}
