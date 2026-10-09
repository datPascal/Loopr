import Foundation
import WorkoutKit
import JournalKit

public enum WHOOPImportResolution {
    /// A native session suppresses the import of the same session. The
    /// shorter interval must overlap by at least 80%, so adjacent sessions
    /// with a small overlap remain separate. This is a Loopr merge policy,
    /// not a device protocol rule.
    public static func workouts(native: [WorkoutRecord], imported: [WorkoutRecord]) -> [WorkoutRecord] {
        native + imported.filter { candidate in
            !native.contains { existing in
                if existing.id == candidate.id || existing.identity == candidate.identity { return true }
                guard let a = existing.startedAt, let b = existing.endedAt,
                      let c = candidate.startedAt, let d = candidate.endedAt,
                      min(b.timeIntervalSince(a), d.timeIntervalSince(c)) > 0 else { return false }
                return min(b, d).timeIntervalSince(max(a, c)) / min(b.timeIntervalSince(a), d.timeIntervalSince(c)) >= 0.8
            }
        }
    }
    public static func journals(native: [JournalEntry], imported: [JournalEntry]) -> [JournalEntry] {
        let days = Set(native.map(\.day))
        return native + imported.filter { !days.contains($0.day) }
    }
}
