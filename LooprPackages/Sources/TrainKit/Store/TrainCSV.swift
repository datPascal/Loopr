import DomainKit
import Foundation

/// One row per logged set, for a spreadsheet or another app.
///
/// `measure` names what the set records (weight, bodyweight, time, distance). `seconds`, `metres` and
/// `assist_kg` stay empty when they do not apply, and `tag` is empty for a working set. The estimated
/// one-rep max is filled for working weight sets only.
public enum TrainCSV {
    public static let header = ["date", "time", "workout", "exercise", "set", "weight_kg", "reps", "rpe", "estimated_1rm_kg",
                                "skipped", "session_id", "exercise_key", "measure", "seconds", "metres", "assist_kg", "tag"]

    public static func sets(_ sessions: [TrainSession]) -> String {
        var rows = [header]
        for session in sessions.filter({ $0.status == .completed }).sorted(by: { $0.startedAt < $1.startedAt }) {
            for line in session.exercises {
                let measure = line.planned.measure
                for (index, set) in line.sets.enumerated() {
                    let e1rm = measure == .weight ? PersonalBestEvaluator.values(of: set)?.estimatedOneRepMax : nil
                    rows.append([session.localDay, CSV.time(set.loggedAt, zone: session.timeZoneIdentifier), session.name, line.exercise.name,
                                 String(index + 1), CSV.number(set.loadKg), set.skipped ? "" : String(set.reps), CSV.number(set.rpe),
                                 CSV.number(e1rm.map { ($0 * 10).rounded() / 10 }), set.skipped ? "yes" : "no",
                                 session.id.uuidString, line.exercise.key, measure.rawValue,
                                 set.seconds.map(String.init) ?? "", CSV.number(set.metres), CSV.number(set.assistKg),
                                 set.tag.map(tagText) ?? ""])
                }
            }
        }
        return CSV.text(rows)
    }

    private static func tagText(_ tag: LoggedSet.Tag) -> String {
        switch tag {
        case .warmUp: "warm_up"
        case .drop: "drop"
        case .failure: "failure"
        }
    }
}
