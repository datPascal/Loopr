import DesignSystem
import Foundation
import Testing
import WorkoutKit
@testable import TrainKit

/// The Fitness tab's small decisions: the week strip's dots, the start rail's order, the sheet's groups, and the
/// words of the pending and This week rows. Alex trains in Perth; the day is Tuesday 2023-11-14.
struct TrainTabRowsTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        return calendar
    }()

    private func at(_ day: Int, hour: Int = 7) -> Date {
        Self.calendar.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour)) ?? .distantPast
    }

    private func workout(_ activity: ActivityType, day: Int, hour: Int = 7, state: WorkoutLifecycleState = .completed,
                         id: UUID = UUID()) -> WorkoutRecord {
        let start = at(day, hour: hour)
        let end = start.addingTimeInterval(30 * 60)
        return WorkoutRecord(id: id, identity: WorkoutIdentity.make(activity: activity, sourceKey: id.uuidString, startedAt: start, endedAt: end),
                             activity: activity, source: .manual, state: state, createdAt: start, startedAt: start, endedAt: end,
                             finalizationStage: .activeStateCleared)
    }

    private func day(_ number: Int, done: [String] = [], planned: [String] = [], zone2: [String] = [],
                     skipped: Bool = false) -> TrainWeekDay {
        var day = TrainWeekDay(localDay: String(format: "2023-11-%02ld", number), weekday: .tuesday, letter: "T",
                               numeral: "\(number)", caption: "", isDone: !done.isEmpty, isToday: false, templateID: nil,
                               spokenLabel: "", doneNames: done, plannedNames: planned, isSkipped: skipped)
        day.zone2PlannedNames = zone2
        return day
    }

    // MARK: Week strip

    @Test func aDayDrawsADotPerSessionDoneFirst() {
        let monday = TrainWeekMarks.day(day(13, done: ["Lower A"], planned: ["Zone 2, 45 min"]), workouts: [],
                                        gymWorkoutIDs: [], calendar: Self.calendar)
        #expect(monday.marks == [.done, .planned])
        #expect(monday.caption == "Lower A, done. Zone 2, 45 min still planned.")
        let tuesday = TrainWeekMarks.day(day(14, planned: ["Upper A", "Zone 2, 45 min"]), workouts: [], gymWorkoutIDs: [],
                                         calendar: Self.calendar)
        #expect(tuesday.marks == [.planned, .planned] && tuesday.caption == "Upper A and Zone 2, 45 min")
        #expect(TrainWeekMarks.day(day(17), workouts: [], gymWorkoutIDs: [], calendar: Self.calendar).caption == "Rest")
        #expect(TrainWeekMarks.day(day(17, skipped: true), workouts: [], gymWorkoutIDs: [], calendar: Self.calendar).caption == "Skipped")
    }

    /// A run on a Zone 2 day fills that day's dot; the gym session's own record is not counted twice.
    @Test func otherWorkoutsFillTheirDayAndGymRecordsCountOnce() {
        let gymID = UUID()
        let workouts = [workout(.run, day: 13), workout(.strength, day: 13, hour: 17, id: gymID),
                        workout(.yoga, day: 12), workout(.cycle, day: 13, state: .interruptedAndRecoverable)]
        let monday = TrainWeekMarks.day(day(13, done: ["Lower A"], planned: ["Zone 2, 45 min"], zone2: ["Zone 2, 45 min"]),
                                        workouts: workouts, gymWorkoutIDs: [gymID], calendar: Self.calendar)
        // The run is the day's Zone 2, so the plan is done.
        #expect(monday.marks == [.done, .done])
        #expect(monday.line(day: "today") == "Done today: Lower A, running.")
    }

    @Test func aWODLeavesAPlannedZone2Open() {
        // Only an endurance session takes a planned Zone 2 off the day (R2-DES-06).
        let workouts = [workout(.crossfit, day: 13), workout(.mobility, day: 13, hour: 18)]
        let monday = TrainWeekMarks.day(day(13, planned: ["Zone 2, 45 min"], zone2: ["Zone 2, 45 min"]), workouts: workouts,
                                        gymWorkoutIDs: [], calendar: Self.calendar)
        #expect(monday.marks == [.done, .done, .planned])
        #expect(monday.line(day: "today") == "Done today: CrossFit, stretching. Still planned: Zone 2, 45 min.")
    }

    @Test func aLocalDayFollowsTheCalendarsTimeZone() {
        // 23:30 UTC on the 13th is 07:30 on the 14th in Perth.
        let late = Date(timeIntervalSince1970: 1_699_918_200)
        #expect(TrainWeekMarks.localDay(late, calendar: Self.calendar) == "2023-11-14")
    }

    // MARK: Start rail

    @Test func gymLeadsTheRailInEveryState() {
        let empty = TrainStartRail.items(recent: [])
        #expect(empty == [.gym, .activity(.walk), .log, .activity(.run), .activity(.cycle), .activity(.crossfit),
                          .activity(.mobility), .more])
        #expect(empty.map(\.identifier) == ["train-rail-gym", "train-rail-walk", "train-rail-log", "train-rail-run",
                                            "train-rail-cycle", "train-rail-crossfit", "train-rail-mobility", "train-rail-more"])
    }

    @Test func recentActivitiesComeRightAfterThePinnedChips() {
        let recent = [workout(.run, day: 12), workout(.yoga, day: 13), workout(.strength, day: 14), workout(.walk, day: 14),
                      workout(.pilates, day: 11), workout(.swim, day: 10), workout(.other, day: 14)]
        let items = TrainStartRail.items(recent: recent)
        // Gym, Walk and Log stay pinned (R2-NEW-01). The four newest activities follow, newest first, and Ride fills
        // the fifth slot.
        #expect(items == [.gym, .activity(.walk), .log, .activity(.yoga), .activity(.run), .activity(.pilates),
                          .activity(.swim), .activity(.cycle), .more])
        #expect(!items.contains(.activity(.strength)) && !items.contains(.activity(.other)))
    }

    @Test func railChipsKeepTheTilesOldIdentifiers() {
        #expect(TrainRailItem.gym.legacyIdentifier == "train-start-gym")
        #expect(TrainRailItem.activity(.run).legacyIdentifier == "workouts-start")
        #expect(TrainRailItem.activity(.cycle).legacyIdentifier == "train-start-cycle")
        #expect(TrainRailItem.log.legacyIdentifier == "workouts-manual-entry")
        #expect(TrainRailItem.more.legacyIdentifier == "train-start-more")
        #expect(TrainRailItem.activity(.crossfit).legacyIdentifier == nil)
        #expect(TrainRailItem.activity(.crossfit).title == "WOD" && TrainRailItem.activity(.crossfit).spokenLabel == "Start a WOD")
    }

    // MARK: Start sheet

    @Test func everyRecordableActivityIsInExactlyOneGroup() {
        let activities = TrainStartSheet.groups.flatMap(\.chips).compactMap { chip -> ActivityType? in
            if case .activity(let activity) = chip { return activity }
            return nil
        }
        #expect(activities.count == Set(activities).count)
        #expect(Set(activities) == Set(ActivityType.recordable))
        #expect(TrainStartSheet.groups.map(\.title) == ["Endurance", "Classes and mobility", "CrossFit", "Timers", "Other"])
        #expect(TrainStartSheet.groups.flatMap(\.chips).contains(.intervals))
        #expect(TrainStartSheet.groups.first { $0.title == "Timers" }?.chips == [.wodClock, .intervals])
        #expect(TrainStartSheet.groups.flatMap(\.chips).contains(.logPast))
    }

    @Test func chipsWrapOntoTheNextLineInsteadOfRunningOffTheEdge() {
        let sizes = Array(repeating: CGSize(width: 100, height: 56), count: 7)
        let rows = TrainChipFlow.rows(sizes: sizes, width: 358, spacing: 8)
        #expect(rows.map(\.indices) == [[0, 1, 2], [3, 4, 5], [6]])
        // A chip wider than the line still gets a line of its own.
        #expect(TrainChipFlow.rows(sizes: [CGSize(width: 500, height: 56)], width: 358, spacing: 8).count == 1)
    }

    // MARK: Rows

    @Test func thePendingRowSaysWhatTheBandSaw() {
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        let run = DetectedWorkout(detectionID: "run", activity: .run, startedAt: start, endedAt: start.addingTimeInterval(600))
        #expect(TrainRowText.pendingTitle(run) == "Band saw a 10 min run")
        let ride = DetectedWorkout(detectionID: "ride", activity: .cycle, startedAt: start, endedAt: start)
        #expect(TrainRowText.pendingTitle(ride) == "Band saw a ride")
        let yoga = DetectedWorkout(detectionID: "yoga", activity: .yoga, startedAt: start, endedAt: start.addingTimeInterval(1_200))
        #expect(TrainRowText.pendingTitle(yoga) == "Band saw a 20 min yoga session")
        // One line under the title, the time and the state (R2-DES-02).
        #expect(TrainScreen.pendingCaption(run).hasSuffix(", not saved yet"))
    }

    @Test func aRowsNumbersLeaveTheDayOut() {
        #expect(TrainRowText.numbers(fromDetailLine: "Tue · 30 min · 5.2 km") == "30 min · 5.2 km")
        #expect(TrainRowText.numbers(fromDetailLine: "Tue") == nil)
        #expect(TrainRowText.numbers(fromDetailLine: nil) == nil)
    }

    @Test func thePlansFoldSaysWhatItHolds() {
        let overview = TrainOverviewModel(TrainOverviewInput(now: at(14, hour: 10), calendar: Self.calendar)).overview
        #expect(TrainScreen.plansSummary(overview) == "No saved workouts · no programs")
    }
}
