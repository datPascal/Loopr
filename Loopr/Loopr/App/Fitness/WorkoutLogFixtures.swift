#if DEBUG
import Foundation
import WorkoutKit

/// Sessions Alex logged by hand in the Train fixture's week (Perth, Tue 2023-11-14), for the quick log, the WOD log
/// and the typed detail: a Pilates class, a 10 minute mobility session after this morning's Fran, two earlier Frans
/// (the October one a PR) and a five-a-side game on Sunday. Seeded beside `AppTrainFixtures.workoutRecords`.
nonisolated enum WorkoutLogFixtures {
    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "7A0460FE-0000-4000-9000-%012d", suffix)) ?? UUID()
    }

    static let pilatesID = id(1)
    static let mobilityID = id(2)
    static let franID = id(3)
    static let octoberFranID = id(4)
    static let septemberFranID = id(5)
    static let footballID = id(6)

    private static func perth(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int = 0) -> Date {
        AppTrainFixtures.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
            ?? .distantPast
    }

    private static let franMovements = ["21-15-9", "Thrusters 43/29 kg", "Pull-ups"]

    private static func logged(_ id: UUID, _ activity: ActivityType, start: Date, minutes: Int, title: String? = nil,
                               effort: Int? = nil, notes: String? = nil, wod: WODResult? = nil) -> WorkoutRecord {
        let end = start.addingTimeInterval(Double(minutes) * 60)
        return WorkoutRecord(
            id: id, identity: WorkoutIdentity.make(activity: activity, sourceKey: nil, startedAt: start, endedAt: end),
            activity: activity, source: .manual, state: .completed, createdAt: end, startedAt: start, endedAt: end,
            finalizationStage: .activeStateCleared, title: title, effort: effort, notes: notes, wod: wod)
    }

    private static func fran(_ id: UUID, start: Date, seconds: Int, notes: String? = nil) -> WorkoutRecord {
        logged(id, .crossfit, start: start, minutes: 30, notes: notes,
               wod: WODResult(format: .forTime, name: "Fran", movements: franMovements, timeCapSeconds: 10 * 60,
                              score: .time(seconds: seconds), scaling: .rx))
    }

    static var records: [WorkoutRecord] {
        [
            fran(septemberFranID, start: perth(2023, 9, 26, hour: 6), seconds: 5 * 60 + 41),
            fran(octoberFranID, start: perth(2023, 10, 24, hour: 6), seconds: 4 * 60 + 58, notes: "Unbroken thrusters on the 21."),
            logged(footballID, .sport, start: perth(2023, 11, 12, hour: 9), minutes: 60, title: "Five-a-side football", effort: 7),
            logged(pilatesID, .pilates, start: perth(2023, 11, 13, hour: 7), minutes: 50, title: "Reformer class", effort: 5,
                   notes: "Felt it in the hips."),
            fran(franID, start: perth(2023, 11, 14, hour: 6), seconds: 5 * 60 + 6, notes: "Pull-ups broke in the 15s."),
            logged(mobilityID, .mobility, start: perth(2023, 11, 14, hour: 6, minute: 35), minutes: 10, effort: 2)
        ]
    }
}
#endif
