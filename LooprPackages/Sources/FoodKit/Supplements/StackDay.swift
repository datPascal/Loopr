import Foundation

/// What happened to one scheduled dose. `notRecorded` is the absence of a tick. It is never "skipped".
public enum StackDoseState: Equatable, Sendable {
    case taken(at: Date, note: String?)
    case skipped(at: Date, note: String?)
    case notRecorded

    public var isTaken: Bool { if case .taken = self { true } else { false } }
    public var isSkipped: Bool { if case .skipped = self { true } else { false } }
    public var isNotRecorded: Bool { if case .notRecorded = self { true } else { false } }
}

/// One dose that is due on a day: an item in one slot.
public struct StackDoseEntry: Equatable, Identifiable, Sendable {
    public let itemID: UUID
    public let itemKey: String
    public let name: String
    public let dose: DoseAmount
    public let slot: StackSlot
    public let state: StackDoseState
    public var id: String { "\(itemID.uuidString).\(slot.rawValue)" }
}

/// One lane's doses on one local day. Only items that are due appear: active, started on or before the day, and
/// scheduled for the slot. A paused item is not due, so it is neither taken nor missed.
public struct StackDay: Equatable, Sendable {
    public let lane: StackLane
    public let localDay: String
    /// In the order of the stack, morning before evening.
    public let doses: [StackDoseEntry]

    public init(localDay: String, supplements: [SupplementItem], ticks: [StackTick]) {
        self.init(lane: .supplement, localDay: localDay,
            entries: supplements.map { Entry(id: $0.id, key: $0.key, name: $0.name, dose: $0.dose, schedule: $0.schedule,
                isActive: $0.isActive, startDay: $0.startDay, sortOrder: $0.sortOrder, createdAt: $0.createdAt) }, ticks: ticks)
    }

    public init(localDay: String, medication: [MedicationItem], ticks: [StackTick]) {
        self.init(lane: .medication, localDay: localDay,
            entries: medication.map { Entry(id: $0.id, key: $0.key, name: $0.name, dose: $0.dose, schedule: $0.schedule,
                isActive: $0.isActive, startDay: $0.startDay, sortOrder: $0.sortOrder, createdAt: $0.createdAt) }, ticks: ticks)
    }

    struct Entry {
        let id: UUID, key: String, name: String, dose: DoseAmount, schedule: StackSchedule
        let isActive: Bool, startDay: String, sortOrder: Int, createdAt: Date
    }

    private init(lane: StackLane, localDay: String, entries: [Entry], ticks: [StackTick]) {
        self.lane = lane; self.localDay = localDay
        let today = FoodLocalDay.daysSinceEpoch(localDay)
        let byDose = Dictionary(ticks.filter { $0.localDay == localDay }.map { ("\($0.itemID.uuidString).\($0.slot.rawValue)", $0) },
                                uniquingKeysWith: { first, _ in first })
        var result: [StackDoseEntry] = []
        for entry in entries.sorted(by: { ($0.sortOrder, $0.createdAt, $0.key) < ($1.sortOrder, $1.createdAt, $1.key) }) {
            guard entry.isActive, let today, let start = FoodLocalDay.daysSinceEpoch(entry.startDay), start <= today else { continue }
            for slot in entry.schedule.slots {
                let tick = byDose["\(entry.id.uuidString).\(slot.rawValue)"]
                let state: StackDoseState = switch tick?.state {
                case .taken?: .taken(at: tick!.recordedAt, note: tick!.note)
                case .skipped?: .skipped(at: tick!.recordedAt, note: tick!.note)
                case nil: .notRecorded
                }
                result.append(.init(itemID: entry.id, itemKey: entry.key, name: entry.name, dose: entry.dose, slot: slot, state: state))
            }
        }
        // Morning doses first, each slot keeping the stack's order.
        doses = StackSlot.allCases.flatMap { slot in result.filter { $0.slot == slot } }
    }

    public func doses(in slot: StackSlot) -> [StackDoseEntry] { doses.filter { $0.slot == slot } }
    public var dueDoses: Int { doses.count }
    public var takenDoses: Int { doses.filter { $0.state.isTaken }.count }
    public var skippedDoses: Int { doses.filter { $0.state.isSkipped }.count }
    public var notRecordedDoses: Int { doses.filter { $0.state.isNotRecorded }.count }
    /// Every due dose has a record, taken or skipped. False when nothing is due.
    public var isFullyRecorded: Bool { !doses.isEmpty && notRecordedDoses == 0 }

    /// Items with a dose due, and how many of them have every due dose taken. "Stack 6 of 7 taken" reads these.
    public var itemsDue: Int { Set(doses.map(\.itemID)).count }
    public var itemsAllTaken: Int {
        Dictionary(grouping: doses, by: \.itemID).values.filter { $0.allSatisfy { $0.state.isTaken } }.count
    }
}
