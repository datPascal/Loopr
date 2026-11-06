import Foundation

/// How a dose is drawn on the shelf.
public enum FoodCapsuleShape: String, Sendable {
    /// A two-colour capsule, the contract's `.cap2`.
    case capsule
    /// One glossy colour: softgels and gummies.
    case softgel
    /// A round tablet with a score line. Medication is always drawn this way.
    case tablet
    /// A drop, for drops and liquids.
    case drop

    public init(_ form: SupplementForm?) {
        switch form {
        case .softgel?, .gummy?: self = .softgel
        case .tablet?: self = .tablet
        case .drop?, .liquid?: self = .drop
        case .capsule?, .powder?, .other?, nil: self = .capsule
        }
    }
}

/// One due dose on today's shelf.
public struct FoodCapsule: Equatable, Sendable, Identifiable {
    public let dose: StackDoseEntry
    public let lane: StackLane
    public let colors: CapsuleColors
    public let shape: FoodCapsuleShape
    /// "supplement-mg-evening" or "medication-metformin-morning": stable across renames, used in identifiers.
    public var key: String { "\(lane.rawValue)-\(dose.itemKey)-\(dose.slot.rawValue)" }
    public var id: String { key }
    public var identifier: String { "food-stack-item-\(key)" }
    public var name: String { dose.name }
    public var isTaken: Bool { dose.state.isTaken }

    /// What VoiceOver reads.
    public var accessibilityLabel: String {
        let state: String = switch dose.state {
        case .taken: "taken"
        case .skipped: "skipped"
        case .notRecorded: "not taken yet"
        }
        return "\(dose.name), \(dose.dose.text), \(dose.slot.title.lowercased()), \(state)"
    }
}

/// Today's stack as the Food tab draws it (contract p-food): the morning and evening supplement stacks, then the
/// medication lane on its own (DEC-12.10). Only due doses appear. A capsule is solid once taken and an outline while
/// due.
public struct FoodStackShelf: Equatable, Sendable {
    public let localDay: String
    public let morning: [FoodCapsule]
    public let evening: [FoodCapsule]
    public let medication: [FoodCapsule]

    /// The contract's seven colour pairs. An item without its own colours takes one, picked by its key.
    public static let palette: [CapsuleColors] = [
        .init(first: "#E8C196", second: "#C2843A"), .init(first: "#F6B3C5", second: "#D6456C"),
        .init(first: "#EDE6DA", second: "#B3A898"), .init(first: "#A6E4D6", second: "#12927F"),
        .init(first: "#D9C49A", second: "#9A6526"), .init(first: "#CFA2EE", second: "#8E45B8"),
        .init(first: "#B7BDF6", second: "#5B63D6"),
    ]
    /// Medication is drawn as white tablets, so it never reads as part of the stack.
    public static let medicationColors = CapsuleColors(first: "#F4F1EC", second: "#C9C2B6")

    public init(supplements: StackDay, medication: StackDay, items: [SupplementItem]) {
        localDay = supplements.localDay
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func capsule(_ dose: StackDoseEntry) -> FoodCapsule {
            let item = byID[dose.itemID]
            return FoodCapsule(dose: dose, lane: .supplement, colors: item?.colors ?? Self.colors(forKey: dose.itemKey),
                               shape: FoodCapsuleShape(item?.form))
        }
        morning = supplements.doses(in: .morning).map(capsule)
        evening = supplements.doses(in: .evening).map(capsule)
        self.medication = medication.doses.map { FoodCapsule(dose: $0, lane: .medication, colors: Self.medicationColors, shape: .tablet) }
    }

    public var supplements: [FoodCapsule] { morning + evening }
    public var isEmpty: Bool { supplements.isEmpty && medication.isEmpty }
    public var supplementsDue: Int { supplements.count }
    public var supplementsTaken: Int { supplements.filter(\.isTaken).count }
    public var medicationDue: Int { medication.count }
    public var medicationTaken: Int { medication.filter(\.isTaken).count }

    /// "6 of 7 taken", counting the doses drawn. Nil with nothing due.
    public var supplementsHeadline: String? { supplementsDue == 0 ? nil : "\(supplementsTaken) of \(supplementsDue) taken" }
    public var medicationHeadline: String? { medicationDue == 0 ? nil : "\(medicationTaken) of \(medicationDue) taken" }

    public static func colors(forKey key: String) -> CapsuleColors {
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return palette[Int(hash % UInt32(palette.count))]
    }

    /// The same shelf with one dose marked taken or cleared, for drawing a tap before the store answers.
    public func toggling(_ capsule: FoodCapsule, at date: Date) -> FoodStackShelf {
        func flip(_ list: [FoodCapsule]) -> [FoodCapsule] {
            list.map { entry in
                guard entry.key == capsule.key else { return entry }
                let state: StackDoseState = FoodStackTap.action(for: entry.dose.state) == .take ? .taken(at: date, note: nil) : .notRecorded
                let dose = StackDoseEntry(itemID: entry.dose.itemID, itemKey: entry.dose.itemKey, name: entry.dose.name,
                                          dose: entry.dose.dose, slot: entry.dose.slot, state: state)
                return FoodCapsule(dose: dose, lane: entry.lane, colors: entry.colors, shape: entry.shape)
            }
        }
        return FoodStackShelf(localDay: localDay, morning: flip(morning), evening: flip(evening), medication: flip(medication))
    }

    private init(localDay: String, morning: [FoodCapsule], evening: [FoodCapsule], medication: [FoodCapsule]) {
        self.localDay = localDay; self.morning = morning; self.evening = evening; self.medication = medication
    }
}

/// What a tap on a capsule does: a due or skipped dose becomes taken, a taken dose goes back to not recorded.
public enum FoodStackTap: Equatable, Sendable {
    case take, clear

    public static func action(for state: StackDoseState) -> FoodStackTap {
        state.isTaken ? .clear : .take
    }
}
