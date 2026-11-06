import Foundation
import NotificationKit
import Testing
@testable import Loopr

/// LV-08b step 2: the blood test routes live on Data's stack, a launch can open the list, and the reminder
/// messages say what happened without a health value.
@MainActor
struct LabsRoutesTests {
    @Test func theLabRoutesAreDistinctAndCarryTheReportID() {
        let id = UUID()
        #expect(AppHealthRoute.labReport(id) == .labReport(id))
        #expect(AppHealthRoute.labReport(id) != .labReport(UUID()))
        #expect(Set<AppHealthRoute>([.labs, .labEntry, .labClockEntry, .labs]).count == 3)
        #expect(AppHealthRoute.labs != .yourData)
    }

    @Test func aFixtureLaunchCanStartOnTheBloodTestList() {
        let state = MainTabLaunchState.restoring("labs")
        #expect(state.tab == .data)
        #expect(state.healthPath == [.labs])
    }

    @Test func otherSavedSelectionsStillRestoreAsBefore() {
        #expect(MainTabLaunchState.restoring("data") == .init(tab: .data))
        #expect(MainTabLaunchState.restoring(nil) == .init(tab: .today))
    }

    @Test func reminderMessagesAreSpecificAndPlain() {
        #expect(LabsReminderCopy.message(for: .set) == nil)
        let cases: [UserReminderOutcome] = [.notAllowed, .full, .familyOff, .failed]
        for outcome in cases {
            let text = LabsReminderCopy.message(for: outcome) ?? ""
            #expect(!text.isEmpty)
            #expect(!text.contains("!"))
            #expect(!text.contains("\u{2014}"))
        }
        #expect(LabsReminderCopy.message(for: .full)?.contains("\(NotificationFamily.userReminderLimit)") == true)
    }
}
