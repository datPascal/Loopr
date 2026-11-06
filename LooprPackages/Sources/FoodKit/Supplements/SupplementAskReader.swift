import Foundation
import StorageKit

public enum StackAskStatus: String, Equatable, Sendable {
    case taken, skipped, notRecorded
}

/// One dose as Ask reads it. `notRecorded` means the person has not said, which is not the same as skipped.
public struct SupplementAskRecord: Equatable, Sendable {
    public let localDay: String
    public let name: String
    public let dose: String
    public let slot: StackSlot
    public let status: StackAskStatus
    public let recordedAt: Date?
    public let note: String?
}

/// The same for the medication lane. A separate type, so a caller cannot fold the lanes together by accident.
public struct MedicationAskRecord: Equatable, Sendable {
    public let localDay: String
    public let name: String
    public let dose: String
    public let slot: StackSlot
    public let status: StackAskStatus
    public let recordedAt: Date?
    public let note: String?
}

public struct SupplementAskSnapshot: Equatable, Sendable {
    public let firstDay: String
    public let lastDay: String
    public let supplements: [SupplementAskRecord]
    public let medication: [MedicationAskRecord]
}

extension SupplementStore {
    /// What the "Supplements and medication" Ask switch may read: every dose due from `first` through `last`, with its
    /// state. Active items only, from their start day. Paused items and days before an item started give no rows.
    /// Prescriber and item notes are not included. LV-09 owns the switch and calls this only when it is on.
    public func askSnapshot(from first: String, through last: String) throws -> SupplementAskSnapshot {
        let supplementDays = try supplementDays(from: first, through: last)
        let medicationDays = try medicationDays(from: first, through: last)
        func status(_ state: StackDoseState) -> (StackAskStatus, Date?, String?) {
            switch state {
            case .taken(let at, let note): (.taken, at, note)
            case .skipped(let at, let note): (.skipped, at, note)
            case .notRecorded: (.notRecorded, nil, nil)
            }
        }
        let supplements = supplementDays.flatMap { day in
            day.doses.map { dose -> SupplementAskRecord in
                let (state, at, note) = status(dose.state)
                return SupplementAskRecord(localDay: day.localDay, name: dose.name, dose: dose.dose.text, slot: dose.slot,
                                           status: state, recordedAt: at, note: note)
            }
        }
        let medication = medicationDays.flatMap { day in
            day.doses.map { dose -> MedicationAskRecord in
                let (state, at, note) = status(dose.state)
                return MedicationAskRecord(localDay: day.localDay, name: dose.name, dose: dose.dose.text, slot: dose.slot,
                                           status: state, recordedAt: at, note: note)
            }
        }
        return SupplementAskSnapshot(firstDay: first, lastDay: last, supplements: supplements, medication: medication)
    }
}
