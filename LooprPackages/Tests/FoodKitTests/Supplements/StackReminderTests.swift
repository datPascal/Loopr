import FoodKit
import Foundation
import NotificationKit
import Testing

struct StackReminderTests {
    private var calendar: Calendar { Longevity.calendar(Longevity.berlin) }
    private var now: Date { Longevity.instant(2026, 10, 21, 9, 30) }

    private func other(_ id: String) -> NotificationRequest {
        UserReminderRequestFactory.request(source: .ask, objectID: id, day: "recurring", fireDate: now.addingTimeInterval(3_600),
                                           title: "Other \(id)", detail: "Other \(id)", repeats: .daily)
    }

    private func built(_ lane: StackLane, _ slot: StackSlot, minute: Int, pending: [NotificationRequest] = []) -> StackReminder.Outcome {
        StackReminder.build(lane: lane, slot: slot, minuteOfDay: minute, now: now, calendar: calendar, pending: pending)
    }

    @Test func theRequestFiresDailyAtTheChosenTimeInTheUserRemindersFamily() throws {
        guard case .request(let request, let replaces) = built(.supplement, .evening, minute: 21 * 60 + 15) else { Issue.record("refused"); return }
        #expect(!replaces)
        #expect(request.identity == NotificationIdentity(family: .userReminders, objectID: "stack.supplement.evening", day: "recurring"))
        #expect(request.repeats == .daily && request.quietHoursBehavior == .deliver && request.sensitivity == .userRequestedAlert)
        #expect(request.fireDate == Longevity.instant(2026, 10, 21, 21, 15) && request.minuteOfDay(calendar: calendar) == 21 * 60 + 15)
        #expect(request.deepLink == .today("2026-10-21"))
        #expect(StackReminder.isStackReminder(request) && request.reminderSource == nil)
        // A time already past today fires tomorrow.
        guard case .request(let tomorrow, _) = built(.supplement, .morning, minute: 7 * 60) else { Issue.record("refused"); return }
        #expect(tomorrow.fireDate == Longevity.instant(2026, 10, 22, 7, 0))
    }

    @Test func theTextNamesTheSlotAndNeverADoseAnItemOrAHealthValue() throws {
        for lane in StackLane.allCases {
            for slot in StackSlot.allCases {
                guard case .request(let request, _) = built(lane, slot, minute: 8 * 60) else { Issue.record("refused"); return }
                let text = [request.title, request.detail, request.lockScreenBody].joined(separator: " ")
                #expect(!text.contains { $0.isNumber }, "\(text)")
                #expect(request.lockScreenBody == request.detail)
                #expect(!text.contains("!") && !text.contains("\u{2014}"))
                for word in ["mg", "IU", "mcg", "D3", "Ramipril", "creatine", "recovery", "heart", "sleep"] { #expect(!text.contains(word), "\(word) in \(text)") }
            }
        }
        #expect(StackReminder.title(lane: .supplement, slot: .evening) == "Evening stack")
        #expect(StackReminder.title(lane: .medication, slot: .morning) == "Morning medication")
        #expect(StackReminder.detail(lane: .supplement, slot: .morning) == "Time for your morning stack.")
        #expect(StackReminder.objectID(lane: .medication, slot: .evening) == "stack.medication.evening")
    }

    @Test func aFullListRefusesANewReminderButAllowsMovingOneThatIsAlreadyThere() throws {
        let ten = (0..<10).map { other("ask.\($0)") }
        #expect(built(.supplement, .morning, minute: 480, pending: ten) == .refused(.full(limit: 10)))
        let nine = Array(ten.prefix(9))
        guard case .request(_, let replaces) = built(.supplement, .morning, minute: 480, pending: nine) else { Issue.record("refused at nine"); return }
        #expect(!replaces)
        // Ten waiting and one of them is this slot: moving it is not an eleventh.
        guard case .request(let mine, _) = built(.supplement, .morning, minute: 480, pending: nine) else { Issue.record("refused"); return }
        guard case .request(let moved, let replacesMine) = built(.supplement, .morning, minute: 9 * 60, pending: nine + [mine]) else { Issue.record("refused moving"); return }
        #expect(replacesMine && moved.minuteOfDay(calendar: calendar) == 9 * 60)
        // A different slot is a new reminder and the list is full.
        #expect(built(.supplement, .evening, minute: 20 * 60, pending: nine + [mine]) == .refused(.full(limit: 10)))
        // Other families do not count against the cap.
        let journal = NotificationRequest(identity: .init(family: .journaling, objectID: "habit", day: "d"), fireDate: now, title: "t", detail: "d",
                                          sensitivity: .ordinary, deepLink: .journal("d"))
        guard case .request = built(.supplement, .morning, minute: 480, pending: nine + [journal]) else { Issue.record("journaling counted"); return }
    }

    @Test func invalidMinutesAreRefused() {
        for minute in [-1, 1_440, 5_000] { #expect(built(.supplement, .morning, minute: minute) == .refused(.invalidTime)) }
        if case .request = built(.supplement, .morning, minute: 0) {} else { Issue.record("midnight refused") }
        if case .request = built(.supplement, .morning, minute: 1_439) {} else { Issue.record("23:59 refused") }
    }
}
