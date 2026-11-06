import Foundation
import NotificationKit
import XCTest

/// LV-07.4: a protocol rule's reminder under "Reminders you set" quotes the evening rule's rebuttal (DEC-12.18).
final class ProtocolRuleReminderTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// Mon 26 Oct 2026, 09:00 in Berlin.
    private var morning: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))! }

    private func request(_ outcome: ProtocolRuleReminder.Outcome) throws -> (NotificationRequest, Bool) {
        guard case .request(let request, let replaces) = outcome else {
            XCTFail("expected a request, got \(outcome)")
            throw CocoaError(.featureUnsupported)
        }
        return (request, replaces)
    }

    func testTheEveningReminderQuotesTheRebuttalAtTheRulesTime() throws {
        let outcome = ProtocolRuleReminder.build(ruleKey: "screens-off", title: "Screens off by 21:45", rebuttal: "  Tomorrow starts tonight. ",
                                                 isEvening: true, minuteOfDay: 21 * 60 + 45, now: morning, calendar: calendar, pending: [])
        let (request, replaces) = try request(outcome)
        XCTAssertFalse(replaces)
        XCTAssertEqual(request.title, "Screens off by 21:45")
        XCTAssertEqual(request.detail, "You wrote this morning: \"Tomorrow starts tonight.\"")
        XCTAssertEqual(request.lockScreenBody, request.detail, "the person's own words show as written")
        XCTAssertEqual(request.identity, NotificationIdentity(family: .userReminders, objectID: "protocol.rule.screens-off", day: "recurring"))
        XCTAssertEqual(request.repeats, .daily)
        XCTAssertEqual(request.quietHoursBehavior, .deliver)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: request.fireDate)
        XCTAssertEqual([parts.day, parts.hour, parts.minute], [26, 21, 45])
        XCTAssertTrue(ProtocolRuleReminder.isRuleReminder(request))
        XCTAssertEqual(ProtocolRuleReminder.ruleKey(from: request.identity.objectID), "screens-off")
    }

    func testWithoutARebuttalOrOnAMorningRuleNothingIsQuoted() throws {
        let plain = try request(ProtocolRuleReminder.build(ruleKey: "screens-off", title: "Screens off", rebuttal: "   ", isEvening: true,
                                                           minuteOfDay: 21 * 60, now: morning, calendar: calendar, pending: [])).0
        XCTAssertFalse(plain.detail.contains("You wrote"))
        let morningRule = try request(ProtocolRuleReminder.build(ruleKey: "light", title: "Morning light", rebuttal: "Stray text", isEvening: false,
                                                                 minuteOfDay: 10 * 60, now: morning, calendar: calendar, pending: [])).0
        XCTAssertFalse(morningRule.detail.contains("Stray text"), "only an evening rule quotes a rebuttal")
    }

    /// ICP R2-HAB-06: a rule on chosen weekdays reminds on those days only, one weekly request per day, and counts as
    /// one reminder in the cap.
    func testARuleOnChosenDaysRemindsOnlyOnThoseDays() throws {
        // Monday, Wednesday and Friday, in Calendar numbers.
        let outcome = ProtocolRuleReminder.build(ruleKey: "gym", title: "Gym", rebuttal: nil, isEvening: false, minuteOfDay: 18 * 60,
                                                 weekdays: [6, 2, 4], now: morning, calendar: calendar, pending: [])
        guard case .weekdays(let requests, let replaces) = outcome else { return XCTFail("expected weekday requests, got \(outcome)") }
        XCTAssertFalse(replaces)
        XCTAssertEqual(requests.map(\.identity.day), ["weekday-2", "weekday-4", "weekday-6"], "Monday first")
        XCTAssertTrue(requests.allSatisfy { $0.repeats == .weekly && $0.identity.objectID == "protocol.rule.gym" })
        let fires = requests.map { calendar.dateComponents([.weekday, .day, .hour, .minute], from: $0.fireDate) }
        XCTAssertEqual(fires.map(\.weekday), [2, 4, 6])
        XCTAssertEqual(fires.map(\.day), [26, 28, 30], "Mon 26, Wed 28 and Fri 30 Oct")
        XCTAssertTrue(fires.allSatisfy { $0.hour == 18 && $0.minute == 0 })
        XCTAssertEqual(outcome.requests.count, 3)

        let everyDay = ProtocolRuleReminder.build(ruleKey: "gym", title: "Gym", rebuttal: nil, isEvening: false, minuteOfDay: 18 * 60,
                                                  weekdays: Set(1...7), now: morning, calendar: calendar, pending: [])
        XCTAssertEqual(try request(everyDay).0.repeats, .daily, "all seven days is a daily reminder")

        // Eight other reminders and the rule's three requests are nine reminders, not eleven.
        let others = (0..<8).map { index in
            NotificationRequest(identity: NotificationIdentity(family: .userReminders, objectID: "ask.\(index)", day: "recurring"),
                                fireDate: morning, title: "Other", detail: "Other", sensitivity: .userRequestedAlert, deepLink: .ask("\(index)"))
        }
        let moved = ProtocolRuleReminder.build(ruleKey: "gym", title: "Gym", rebuttal: nil, isEvening: false, minuteOfDay: 19 * 60,
                                               weekdays: [3], now: morning, calendar: calendar, pending: others + requests)
        XCTAssertTrue(moved.replacesPending)
        XCTAssertEqual(moved.requests.map(\.identity.day), ["weekday-3"])
        let another = ProtocolRuleReminder.build(ruleKey: "swim", title: "Swim", rebuttal: nil, isEvening: false, minuteOfDay: 7 * 60,
                                                 weekdays: [7], now: morning, calendar: calendar, pending: others + requests)
        XCTAssertEqual(another.requests.count, 1, "the rule's three weekdays count as one of the ten")
        let full = ProtocolRuleReminder.build(ruleKey: "swim", title: "Swim", rebuttal: nil, isEvening: false, minuteOfDay: 7 * 60,
                                              weekdays: [7], now: morning, calendar: calendar, pending: others + requests + another.requests)
        XCTAssertEqual(ProtocolRuleReminder.build(ruleKey: "walk", title: "Walk", rebuttal: nil, isEvening: false, minuteOfDay: 7 * 60,
                                                  now: morning, calendar: calendar, pending: others + requests + another.requests),
                       .refused(.full(limit: NotificationFamily.userReminderLimit)), "ten different reminders are full")
        XCTAssertTrue(full.replacesPending, "the swim rule's own reminder still moves")
        XCTAssertEqual(ProtocolRuleReminder.build(ruleKey: "gym", title: "Gym", rebuttal: nil, isEvening: false, minuteOfDay: 60,
                                                  weekdays: [8], now: morning, calendar: calendar, pending: []), .refused(.invalidTime))
    }

    func testAMovedReminderReplacesItsOwnAndTheSharedCapHolds() throws {
        let first = try request(ProtocolRuleReminder.build(ruleKey: "in-bed", title: "In bed", rebuttal: nil, isEvening: true,
                                                           minuteOfDay: 22 * 60, now: morning, calendar: calendar, pending: [])).0
        let moved = try request(ProtocolRuleReminder.build(ruleKey: "in-bed", title: "In bed", rebuttal: "Sleep wins", isEvening: true,
                                                           minuteOfDay: 22 * 60 + 15, now: morning, calendar: calendar, pending: [first]))
        XCTAssertTrue(moved.1, "the same rule replaces its waiting reminder")

        let others = (0..<NotificationFamily.userReminderLimit).map { index in
            NotificationRequest(identity: NotificationIdentity(family: .userReminders, objectID: "ask.\(index)", day: "recurring"),
                                fireDate: morning, title: "Other", detail: "Other", sensitivity: .userRequestedAlert, deepLink: .ask("\(index)"))
        }
        XCTAssertEqual(ProtocolRuleReminder.build(ruleKey: "in-bed", title: "In bed", rebuttal: nil, isEvening: true, minuteOfDay: 22 * 60,
                                                  now: morning, calendar: calendar, pending: others),
                       .refused(.full(limit: NotificationFamily.userReminderLimit)))
        XCTAssertEqual(ProtocolRuleReminder.build(ruleKey: "in-bed", title: "In bed", rebuttal: nil, isEvening: true, minuteOfDay: 1_440,
                                                  now: morning, calendar: calendar, pending: []), .refused(.invalidTime))
    }

    // MARK: Done and Skip today (ICP R3-HAB-02)

    private func ruleRequest(_ key: String = "magnesium") throws -> NotificationRequest {
        try request(ProtocolRuleReminder.build(ruleKey: key, title: "Magnesium, 300 mg", rebuttal: nil, isEvening: true,
                                               minuteOfDay: 21 * 60 + 30, now: morning, calendar: calendar, pending: [])).0
    }

    func testARuleReminderCarriesDoneAndSkipTodayAndOtherRemindersDoNot() throws {
        let rule = try ruleRequest()
        XCTAssertEqual(rule.categoryIdentifier, NotificationCategoryCatalog.protocolRule)
        let category = NotificationCategoryCatalog.all.first { $0.identifier == NotificationCategoryCatalog.protocolRule }
        XCTAssertEqual(category?.actions.map(\.title), ["Done", "Skip today"])
        XCTAssertEqual(category?.actions.map(\.identifier),
                       [NotificationCategoryCatalog.ruleDoneAction, NotificationCategoryCatalog.ruleSkipTodayAction])
        XCTAssertEqual(category?.actions.map(\.opensApp), [false, false], "both answer without opening Loopr")

        let ask = NotificationRequest(identity: NotificationIdentity(family: .userReminders, objectID: "ask.a1", day: "recurring"),
                                      fireDate: morning, title: "Stretch", detail: "Ten slow reps.", sensitivity: .userRequestedAlert,
                                      deepLink: .ask("a1"))
        XCTAssertEqual(ask.categoryIdentifier, NotificationCategoryCatalog.reminder, "a reminder from Ask has nothing to tick")
    }

    func testTheResponseNamesTheRuleAndTheAction() throws {
        let info = try NotificationResponsePayload.userInfo(for: try ruleRequest("screens-off"))
        XCTAssertEqual(ProtocolRuleReminder.answer(actionIdentifier: NotificationCategoryCatalog.ruleDoneAction, userInfo: info),
                       ProtocolRuleReminder.Answer(ruleKey: "screens-off", action: .done))
        XCTAssertEqual(ProtocolRuleReminder.answer(actionIdentifier: NotificationCategoryCatalog.ruleSkipTodayAction, userInfo: info),
                       ProtocolRuleReminder.Answer(ruleKey: "screens-off", action: .skipToday))
        XCTAssertTrue(ProtocolRuleReminder.isAnswerAction(NotificationCategoryCatalog.ruleDoneAction))
        XCTAssertFalse(ProtocolRuleReminder.isAnswerAction(NotificationCategoryCatalog.pauseForTodayAction))
    }

    func testAResponseLooprCannotPlaceWritesNothing() throws {
        let info = try NotificationResponsePayload.userInfo(for: try ruleRequest())
        XCTAssertNil(ProtocolRuleReminder.answer(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info),
                     "a plain tap opens the app instead")
        let ask = NotificationRequest(identity: NotificationIdentity(family: .userReminders, objectID: "ask.a1", day: "recurring"),
                                      fireDate: morning, title: "Stretch", detail: "Ten slow reps.", sensitivity: .userRequestedAlert,
                                      deepLink: .ask("a1"))
        XCTAssertNil(ProtocolRuleReminder.answer(actionIdentifier: NotificationCategoryCatalog.ruleDoneAction,
                                                 userInfo: try NotificationResponsePayload.userInfo(for: ask)))
        var other = info
        other[NotificationResponsePayload.familyKey] = NotificationFamily.journaling.rawValue
        XCTAssertNil(ProtocolRuleReminder.answer(actionIdentifier: NotificationCategoryCatalog.ruleDoneAction, userInfo: other))
        var empty = info
        empty[NotificationResponsePayload.objectKey] = ProtocolRuleReminder.objectIDPrefix
        XCTAssertNil(ProtocolRuleReminder.answer(actionIdentifier: NotificationCategoryCatalog.ruleDoneAction, userInfo: empty))
        XCTAssertNil(ProtocolRuleReminder.answer(actionIdentifier: NotificationCategoryCatalog.ruleDoneAction, userInfo: [:]))
    }

    // MARK: Planned days and plain reminders (ICP round 4)

    /// Q1b and Q5: a rule planned day by day gets one request per day still ahead, keyed by its date, at the rule's time.
    func testPlannedDaysAreOneRequestEachAndPastOnesAreLeftOut() throws {
        // Mon 26 Oct 2026 at 09:00: Sunday the 25th is gone, the 26th at 21:30 is still ahead.
        let days = [25, 26, 28, 28].map { DateComponents(year: 2026, month: 10, day: $0) }
        let outcome = ProtocolRuleReminder.build(ruleKey: "magnesium", title: "Magnesium, 300 mg", rebuttal: nil, isEvening: true,
                                                 minuteOfDay: 21 * 60 + 30, schedule: .days(days), answerable: true,
                                                 now: morning, calendar: calendar, pending: [])
        guard case .dated(let requests, let replaces) = outcome else { return XCTFail("expected dated requests, got \(outcome)") }
        XCTAssertFalse(replaces)
        XCTAssertEqual(requests.map(\.identity.day), ["2026-10-26", "2026-10-28"], "a day twice is one request")
        XCTAssertTrue(requests.allSatisfy { $0.repeats == nil && $0.identity.objectID == "protocol.rule.magnesium" })
        XCTAssertTrue(requests.allSatisfy { $0.categoryIdentifier == NotificationCategoryCatalog.protocolRule })
        let fires = requests.map { calendar.dateComponents([.day, .hour, .minute], from: $0.fireDate) }
        XCTAssertEqual(fires.map(\.day), [26, 28])
        XCTAssertTrue(fires.allSatisfy { $0.hour == 21 && $0.minute == 30 })
        XCTAssertEqual(requests.map(\.deepLink), [.journal("2026-10-26"), .journal("2026-10-28")])

        let none = ProtocolRuleReminder.build(ruleKey: "sauna", title: "Sauna", rebuttal: nil, isEvening: false, minuteOfDay: 18 * 60,
                                              schedule: .days([]), answerable: true, now: morning, calendar: calendar, pending: [])
        XCTAssertEqual(none, .dated([], replacesPending: false), "a met week has nothing to send, and that is not an error")
    }

    /// VET: a rule the band, Food, Fitness or Apple Health checks gets a plain reminder with no Done and no Skip today.
    func testARuleASourceChecksGetsAPlainReminder() throws {
        let outcome = ProtocolRuleReminder.build(ruleKey: "in-bed", title: "In bed by 22:30", rebuttal: nil, isEvening: true,
                                                 minuteOfDay: 22 * 60 + 30, schedule: .repeating(weekdays: []), answerable: false,
                                                 now: morning, calendar: calendar, pending: [])
        let request = try request(outcome).0
        XCTAssertEqual(request.categoryIdentifier, NotificationCategoryCatalog.reminder)
        let plain = NotificationCategoryCatalog.all.first { $0.identifier == NotificationCategoryCatalog.reminder }
        XCTAssertEqual(plain?.actions, [], "nothing to press on the lock screen")
        XCTAssertEqual(ProtocolRuleReminder.category(answerable: true), NotificationCategoryCatalog.protocolRule)
    }

    /// A rule kept on with nothing waiting still counts once toward the ten.
    func testAStandingRuleCountsTowardTheCap() {
        let others = (0..<9).map { index in
            NotificationRequest(identity: NotificationIdentity(family: .userReminders, objectID: "ask.\(index)", day: "recurring"),
                                fireDate: morning, title: "Other", detail: "Other", sensitivity: .userRequestedAlert, deepLink: .ask("\(index)"))
        }
        let refused = ProtocolRuleReminder.build(ruleKey: "walk", title: "Walk", rebuttal: nil, isEvening: false, minuteOfDay: 7 * 60,
                                                 schedule: .repeating(weekdays: []), answerable: true, now: morning, calendar: calendar,
                                                 pending: others, standing: ["protocol.rule.sauna"])
        XCTAssertEqual(refused, .refused(.full(limit: NotificationFamily.userReminderLimit)))
        let own = ProtocolRuleReminder.build(ruleKey: "sauna", title: "Sauna", rebuttal: nil, isEvening: false, minuteOfDay: 18 * 60,
                                             schedule: .days([DateComponents(year: 2026, month: 11, day: 2)]), answerable: true,
                                             now: morning, calendar: calendar, pending: others, standing: ["protocol.rule.sauna"])
        XCTAssertTrue(own.replacesPending)
        XCTAssertEqual(own.requests.count, 1)
    }

    /// Planning again with the same days leaves the waiting requests alone; a changed day, word or button does not.
    func testPlanningTheSameDaysAgainChangesNothing() throws {
        func build(_ days: [Int], answerable: Bool = true, title: String = "Sauna", weekdays: Set<Int>? = nil) -> [NotificationRequest] {
            let schedule: ProtocolRuleReminder.Schedule = weekdays.map { .repeating(weekdays: $0) }
                ?? .days(days.map { DateComponents(year: 2026, month: 10, day: $0) })
            return ProtocolRuleReminder.build(ruleKey: "sauna", title: title, rebuttal: nil, isEvening: false, minuteOfDay: 18 * 60,
                                              schedule: schedule, answerable: answerable, now: morning, calendar: calendar,
                                              pending: []).requests
        }
        let waiting = build([26, 27, 28])
        XCTAssertTrue(ProtocolRuleReminder.isUnchanged(waiting, planned: build([28, 27, 26]), calendar: calendar))
        XCTAssertFalse(ProtocolRuleReminder.isUnchanged(waiting, planned: build([26, 28]), calendar: calendar))
        XCTAssertFalse(ProtocolRuleReminder.isUnchanged(waiting, planned: build([26, 27, 28], answerable: false), calendar: calendar))
        XCTAssertFalse(ProtocolRuleReminder.isUnchanged(waiting, planned: build([26, 27, 28], title: "Sauna, 20 min"), calendar: calendar))

        // A daily request planned a day later fires first on a later date, and is still the same reminder.
        let daily = build([], weekdays: [])
        let tomorrow = ProtocolRuleReminder.build(ruleKey: "sauna", title: "Sauna", rebuttal: nil, isEvening: false, minuteOfDay: 18 * 60,
                                                  schedule: .repeating(weekdays: []), answerable: true,
                                                  now: morning.addingTimeInterval(86_400), calendar: calendar, pending: []).requests
        XCTAssertTrue(ProtocolRuleReminder.isUnchanged(daily, planned: tomorrow, calendar: calendar))
        XCTAssertFalse(ProtocolRuleReminder.isUnchanged(daily, planned: waiting, calendar: calendar))

        // One saved before reminders named their category is set again, so it gets the right buttons.
        let old = NotificationRequest(identity: daily[0].identity, fireDate: daily[0].fireDate, title: daily[0].title,
                                      detail: daily[0].detail, sensitivity: .userRequestedAlert, deepLink: daily[0].deepLink,
                                      quietHoursBehavior: .deliver, repeats: .daily)
        XCTAssertFalse(ProtocolRuleReminder.isUnchanged([old], planned: daily, calendar: calendar))
    }
}
