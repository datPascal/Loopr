import DomainKit
import Foundation
@testable import JournalKit
import RoutineKit
import XCTest

/// LV-07.4: the Rules segment's list, the rule editor's draft, the version history, the pass card's counts and the
/// import review, and the model's save, import and template paths over a fake source.
@MainActor
final class ProtocolRulesTests: XCTestCase {
    private typealias Data_ = ProtocolTestData

    // MARK: Rules list

    func testRulesAreGroupedByTimeOfDayWithCadenceAndSource() {
        let weekly = ProtocolRule(key: "zone2w", title: "Zone 2, 150 minutes a week",
                                  target: RuleTarget(kind: .atLeast, metric: RoutineMetric.zone2Minutes.rawValue, value: 150),
                                  source: .band, cadence: RuleCadence(unit: .week))
        let blood = ProtocolRule(key: "blood", title: "Blood test", group: .tests, cadence: RuleCadence(unit: .month, every: 6))
        let sections = ProtocolRulesPresentation.sections(Data_.rules + [weekly, blood], reminders: ["screens": 21 * 60 + 45],
                                                          locale: Data_.locale)
        XCTAssertEqual(sections.map(\.part), [.morning, .afternoon, .evening, .anyTime])
        XCTAssertEqual(sections[0].rows.map(\.rule.key), ["light"])
        XCTAssertEqual(sections[1].rows.map(\.rule.key), ["caffeine"])
        XCTAssertEqual(sections[2].rows.map(\.rule.key), ["meal", "magnesium", "screens", "bed"], "earliest first")
        XCTAssertEqual(sections[3].rows.map(\.rule.key), ["alcohol", "zone2", "training", "stretch", "zone2w", "blood"])

        XCTAssertEqual(sections[2].rows[3].caption, "Every day \u{00B7} checked by the band", "no time: the name says it")
        XCTAssertEqual(sections[0].rows[0].caption, "Every day \u{00B7} you tick it")
        XCTAssertEqual(sections[3].rows[4].caption, "Each week \u{00B7} checked by the band")
        XCTAssertEqual(sections[3].rows[5].caption, "Every 6 months \u{00B7} you tick it")
        XCTAssertEqual(sections[2].rows[2].reminderMinute, 21 * 60 + 45)
        XCTAssertEqual(sections[2].rows[2].reminderText, "Reminder 21:45")
        XCTAssertNil(sections[2].rows[3].reminderText, "a time shows on the row only as a reminder (ICP R1-DES-07)")
        XCTAssertTrue(sections[2].rows[2].accessibilityLabel.contains("Reminder 21:45"))
    }

    /// ICP R1-NEW-02, R1-SEN-24, R1-HAB-02, R1-VET-08, R1-VET-23: the why line, the source chip, the days and how far a
    /// longer rule has come.
    func testRowsShowWhySourceDaysAndProgress() {
        let gym = ProtocolRule(key: "gym", title: "Gym", cadence: .on([.monday, .wednesday, .friday]), why: "  Strength keeps you on your feet.  ")
        let weekdays = ProtocolRule(key: "walk", title: "Walk to work", source: .appleHealth,
                                    cadence: .on([.monday, .tuesday, .wednesday, .thursday, .friday]))
        let swim = ProtocolRule(key: "swim", title: "Swim", cadence: .timesAWeek(3))
        let zone2 = ProtocolRule(key: "zone2w", title: "Zone 2, 150 min a week",
                                 target: RuleTarget(kind: .atLeast, metric: RoutineMetric.zone2Minutes.rawValue, value: 150, unit: "min"),
                                 source: .band, cadence: RuleCadence(unit: .week))
        let panel = ProtocolRule(key: "panel", title: "Blood panel", group: .tests, cadence: RuleCadence(unit: .month, every: 3))
        let progress: [RuleKey: RuleProgress] = [
            "swim": .times(done: 2, target: 3), "zone2w": .amount(measured: 112, target: 150, unit: "min"),
            "panel": .due(lastDone: DayIdentity(year: 2023, month: 8, day: 20), next: DayIdentity(year: 2023, month: 11, day: 20))
        ]
        let rows = ProtocolRulesPresentation.sections([gym, weekdays, swim, zone2, panel], progress: progress, today: Data_.day(14),
                                                      locale: Data_.locale).flatMap(\.rows)
        let byKey: [RuleKey: ProtocolRuleRow] = Dictionary(uniqueKeysWithValues: rows.map { ($0.rule.key, $0) })
        XCTAssertEqual(byKey["gym"]?.why, "Strength keeps you on your feet.")
        XCTAssertEqual(byKey["gym"]?.schedule, "Mon, Wed, Fri \u{00B7} not today", "Tuesday is an off day")
        XCTAssertEqual(byKey["gym"]?.sourceChip, "You")
        XCTAssertEqual(byKey["walk"]?.schedule, "Weekdays")
        XCTAssertEqual(byKey["walk"]?.sourceChip, "Apple Health")
        XCTAssertEqual(byKey["swim"]?.schedule, "3 times a week \u{00B7} done 2 of 3 times this week")
        XCTAssertEqual(byKey["zone2w"]?.schedule, "Each week \u{00B7} 112 of 150 min \u{00B7} 6 days left", "Tuesday to Sunday (ICP R3-VET-09)")
        XCTAssertEqual(byKey["zone2w"]?.weekShare ?? 0, 112.0 / 150.0, accuracy: 0.001)
        XCTAssertNil(byKey["swim"]?.weekShare, "a bar only for a weekly amount")
        XCTAssertEqual(byKey["zone2w"]?.sourceChip, "Band")
        XCTAssertEqual(byKey["panel"]?.schedule, "Every 3 months \u{00B7} last done 20 Aug \u{00B7} due 20 Nov")
        XCTAssertNil(ProtocolRulesPresentation.row(Data_.stretch).schedule, "an every-day rule says nothing extra")
        XCTAssertTrue(byKey["gym"]?.accessibilityLabel.contains("You tick it") ?? false)

        XCTAssertEqual(ProtocolRulesPresentation.progressText(.amount(measured: nil, target: 150, unit: "min"), today: nil),
                       "nothing measured this week yet")
        XCTAssertEqual(ProtocolRulesPresentation.progressText(.times(done: 1, target: 1), today: nil), "done this week")
        XCTAssertEqual(ProtocolRulesPresentation.progressText(.due(lastDone: nil, next: nil), today: nil), "not done yet")
        XCTAssertEqual(ProtocolRulesPresentation.progressText(.due(lastDone: Data_.day(1), next: Data_.day(8)), today: Data_.day(14),
                                                              locale: Data_.locale), "last done 1 Nov \u{00B7} was due 8 Nov")
    }

    // MARK: Draft

    /// ICP R2-OPT-5 and R2-OPT-6: typing a new amount moves the number in the name with it, through an empty field and
    /// a single digit, and a leading zero goes.
    func testTheNameFollowsTheAmountAndLeadingZerosGo() {
        let zone2 = ProtocolRule(key: "zone-2", title: "Zone 2, 45 min", group: .fitness,
                                 target: RuleTarget(kind: .atLeast, metric: RoutineMetric.zone2Minutes.rawValue, value: 45, unit: "min"),
                                 source: .band)
        var draft = ProtocolRuleDraft(rule: zone2)
        draft.setAmount(nil)
        XCTAssertEqual(draft.title, "Zone 2, 45 min")
        draft.setAmount(5)
        draft.setAmount(50)
        XCTAssertEqual(draft.title, "Zone 2, 50 min")
        XCTAssertEqual(draft.rule(key: "zone-2").target.value, 50)
        XCTAssertEqual(ProtocolRuleDraft.trimmingLeadingZeros("045"), "45")
        XCTAssertEqual(ProtocolRuleDraft.trimmingLeadingZeros("0"), "0")
        XCTAssertEqual(ProtocolRuleDraft.trimmingLeadingZeros("0.5"), "0.5")
    }

    func testTheDraftKeepsARebuttalOnlyOnAnEveningRule() {
        var draft = ProtocolRuleDraft(rule: Data_.screens)
        XCTAssertFalse(draft.canSave, "nothing changed yet")
        draft.minuteOfDay = 22 * 60
        draft.rebuttal = "  Tomorrow starts tonight. "
        XCTAssertTrue(draft.canSave)
        let rule = draft.rule(key: "screens")
        XCTAssertEqual(rule.timeOfDayMinutes, 22 * 60)
        XCTAssertEqual(rule.rebuttal, "Tomorrow starts tonight.")

        var measured = ProtocolRuleDraft(rule: Data_.bed)
        measured.rebuttal = "Sleep wins"
        XCTAssertEqual(measured.rule(key: "bed").rebuttal, "Sleep wins")
        measured.isEvening = false
        XCTAssertNil(measured.rule(key: "bed").rebuttal, "a source rule the person does not answer drops the rebuttal")

        var long = ProtocolRuleDraft(rule: Data_.screens)
        long.rebuttal = String(repeating: "a", count: 281)
        XCTAssertFalse(long.canSave)
        XCTAssertNotNil(long.problem)
    }

    func testAnUnchangedRuleKeepsItsTargetAndANightTimeAfterMidnightCountsPast1440() {
        let draft = ProtocolRuleDraft(rule: Data_.bed)
        XCTAssertEqual(draft.rule(key: "bed"), Data_.bed)
        var late = draft
        late.value = 30
        XCTAssertEqual(late.rule(key: "bed").target.value, 1_470, "00:30 for bed is the night after midnight")
    }

    func testApplyingADraftEditsAddsAndRemoves() {
        var edit = ProtocolRuleDraft(rule: Data_.stretch)
        edit.title = "Stretch for 10 minutes"
        XCTAssertEqual(ProtocolRuleEdit.apply(edit, to: Data_.rules).last?.title, "Stretch for 10 minutes")

        var removal = ProtocolRuleDraft(rule: Data_.alcohol)
        removal.isRemoved = true
        XCTAssertTrue(removal.canSave)
        XCTAssertFalse(ProtocolRuleEdit.apply(removal, to: Data_.rules).contains { $0.key == "alcohol" })
        removal.isRemoved = false
        XCTAssertEqual(ProtocolRuleEdit.apply(removal, to: Data_.rules), Data_.rules, "undo before save changes nothing")

        var added = ProtocolRuleDraft.newRule()
        XCTAssertFalse(added.canSave, "a new rule needs a name")
        added.title = "Stretch"
        let rules = ProtocolRuleEdit.apply(added, to: Data_.rules)
        XCTAssertEqual(rules.count, Data_.rules.count + 1)
        XCTAssertEqual(rules.last?.key, "stretch-2", "a taken key gets a number")
        XCTAssertEqual(ProtocolRuleDraft.newKey(title: "Café au lait!", existing: []), "caf-au-lait")
    }

    /// ICP R1-HAB-02, R1-VET-22, R1-DES-20: days, why and the hint beside its field.
    func testTheDraftCarriesDaysAndWhyAndPointsAtTheFieldSaveWaitsOn() {
        var draft = ProtocolRuleDraft(rule: Data_.stretch)
        XCTAssertEqual(draft.daysMode, .everyDay)
        draft.daysMode = .someDays
        XCTAssertEqual(draft.problemField, .days)
        XCTAssertEqual(draft.problem, "Pick at least one day.")
        XCTAssertFalse(draft.canSave)
        draft.chosenDays = [.saturday, .sunday]
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.rule(key: "stretch").cadence, .on([.saturday, .sunday]))

        draft.daysMode = .timesAWeek
        draft.timesPerWeek = 4
        XCTAssertEqual(draft.rule(key: "stretch").cadence?.timesPerWeek, 4)
        draft.daysMode = .lessOften
        draft.cadenceUnit = .month
        draft.cadenceEvery = 3
        XCTAssertEqual(draft.rule(key: "stretch").cadence, RuleCadence(unit: .month, every: 3))
        draft.daysMode = .everyDay
        XCTAssertNil(draft.rule(key: "stretch").cadence)

        draft.why = "  Loose hips, fewer aches.  "
        XCTAssertEqual(draft.rule(key: "stretch").why, "Loose hips, fewer aches.")
        draft.why = String(repeating: "a", count: 281)
        XCTAssertEqual(draft.problemField, .why)
        draft.why = ""
        XCTAssertNil(draft.rule(key: "stretch").why)

        let reopened = ProtocolRuleDraft(rule: Data_.stretch.with(cadence: .some(.on([.monday])), why: .some("Because")))
        XCTAssertEqual(reopened.daysMode, .someDays)
        XCTAssertEqual(reopened.chosenDays, [.monday])
        XCTAssertEqual(reopened.why, "Because")
        XCTAssertEqual(reopened.rule(key: "stretch"), Data_.stretch.with(cadence: .some(.on([.monday])), why: .some("Because")),
                       "an untouched rule keeps its days and why")
        XCTAssertEqual(ProtocolRuleDraft(rule: Data_.stretch.with(cadence: .some(.timesAWeek(3)))).daysMode, .timesAWeek)
        XCTAssertEqual(ProtocolRuleDraft(rule: Data_.stretch.with(cadence: .some(RuleCadence(unit: .month, every: 6)))).cadenceEvery, 6)

        var empty = ProtocolRuleDraft.newRule()
        XCTAssertEqual(empty.problemField, .name)
        empty.title = "Walk"
        XCTAssertNil(empty.problemField)
    }

    // MARK: History

    func testTheHistorySaysWhatEachVersionChanged() throws {
        let id = ProtocolID()
        let v1 = try ProtocolVersion(protocolID: id, number: 1, createdAt: Data_.now, note: "Started from the Sleep first template.",
                                     rules: [Data_.light, Data_.screens])
        let v2 = try ProtocolVersion(protocolID: id, number: 2, createdAt: Data_.now.addingTimeInterval(86_400),
                                     rules: [Data_.light, Data_.screens.with(timeOfDayMinutes: .some(22 * 60), rebuttal: .some("Sleep wins"))])
        let v3 = try ProtocolVersion(protocolID: id, number: 3, createdAt: Data_.now.addingTimeInterval(172_800), note: "Kept a result.",
                                     rules: v2.rules)
        let saved = ProtocolVersionDiff.summary(ProtocolVersionDiff.changes(from: v1.rules, to: v2.rules))
        let v2Noted = try ProtocolVersion(protocolID: id, number: 2, createdAt: v2.createdAt, note: saved, rules: v2.rules)
        let v4 = try ProtocolVersion(protocolID: id, number: 4, createdAt: Data_.now.addingTimeInterval(259_200),
                                     note: "My GP asked for it.", rules: v2.rules + [Data_.stretch])
        let entries = ProtocolVersionEntry.entries([v2Noted, v1, v4, v3], locale: Data_.locale)
        XCTAssertEqual(entries.map(\.number), [4, 3, 2, 1], "newest first")
        XCTAssertTrue(entries[0].isCurrent && !entries[1].isCurrent)
        // ICP R2-VET-07: every row says what changed, and why when the version has a reason.
        XCTAssertEqual(entries[0].summary, "Added Stretch")
        XCTAssertEqual(entries[0].reason, "My GP asked for it.")
        XCTAssertEqual(entries[1].summary, "Same rules as version 2")
        XCTAssertEqual(entries[1].reason, "Kept a result.")
        XCTAssertEqual(entries[2].summary, "Changed Screens off by 21:45: time to 22:00 and reason")
        XCTAssertNil(entries[2].reason, "the note Loopr wrote from the changes is not said twice")
        XCTAssertEqual(entries[3].summary, "First version, 2 rules")
        XCTAssertEqual(entries[3].reason, "Started from the Sleep first template.")
        XCTAssertEqual(entries[3].dateText(locale: Data_.locale, timeZone: Data_.zone), "14 Nov 2023")
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(ProtocolVersionEntry.entries([v1, v2], locale: us)[0].summary,
                       "Changed \(Data_.screens.displayTitle(locale: us)): time to \(ProtocolRule(key: "clock", title: "22:00").displayTitle(locale: us)) and reason",
                       "times in the locale's clock")
        // A name whose time only followed the rule's time is not a rename.
        let shifted = try ProtocolVersion(protocolID: id, number: 2, createdAt: v2.createdAt, rules: [
            Data_.light, Data_.screens.with(title: "Screens off by 22:05", timeOfDayMinutes: .some(22 * 60 + 5))])
        XCTAssertEqual(ProtocolVersionEntry.entries([v1, shifted], locale: Data_.locale)[0].summary,
                       "Changed Screens off by 22:05: time to 22:05")
    }

    /// ICP R1-VET-06: a version lists what changed against the one before, then the rules that stayed the same.
    func testAVersionSaysWhatChangedFirst() throws {
        let id = ProtocolID()
        let protein = ProtocolRule(key: "protein", title: "Protein 150 g",
                                   target: RuleTarget(kind: .atLeast, metric: RoutineMetric.proteinG.rawValue, value: 150, unit: "g"),
                                   source: .food)
        let v1 = try ProtocolVersion(protocolID: id, number: 1, createdAt: Data_.now, note: "Started from the Sleep first template.",
                                     rules: [Data_.light, Data_.screens, protein, Data_.alcohol])
        let v2 = try ProtocolVersion(protocolID: id, number: 2, createdAt: Data_.now, rules: [
            Data_.light, Data_.screens.with(timeOfDayMinutes: .some(22 * 60 + 5)),
            protein.with(title: "Protein 160 g", target: RuleTarget(kind: .atLeast, metric: RoutineMetric.proteinG.rawValue, value: 160, unit: "g")),
            ProtocolRule(key: "sauna", title: "Sauna", cadence: .timesAWeek(2))
        ])
        let detail = ProtocolVersionDetail.make(v2, previous: v1, locale: Data_.locale)
        XCTAssertEqual(detail.changesTitle, "What changed from version 1")
        XCTAssertEqual(detail.changes.map(\.title), ["Screens off by 21:45", "Protein 160 g", "Removed: No alcohol", "Added: Sauna"])
        XCTAssertEqual(detail.changes[0].detail, "Time 21:45 to 22:05.")
        XCTAssertEqual(detail.changes[1].detail, "Target 150 to 160 g.", "a name that followed its amount is not a rename")
        XCTAssertNil(detail.changes[2].detail)
        XCTAssertEqual(detail.unchanged.map(\.rule.key), ["light"])
        XCTAssertEqual(detail.unchangedTitle, "1 rule stayed the same")

        let first = ProtocolVersionDetail.make(v1, previous: nil, locale: Data_.locale)
        XCTAssertNil(first.previousNumber)
        XCTAssertEqual(first.unchanged.count, 4, "the first version lists every rule")
        XCTAssertEqual(first.note, "Started from the Sleep first template.")

        let days = ProtocolVersionDetail.line(.changed(before: Data_.stretch, after: Data_.stretch.with(cadence: .some(.on([.monday]))),
                                                       fields: [.cadence]), locale: Data_.locale)
        XCTAssertEqual(days.detail, "Was every day, now Mon.")
    }

    /// ICP R2-NEW-05, R2-SEN-08, R2-HAB-07: a tick rule has no ask switch and always asks; a morning line makes it an
    /// evening rule so the reminder can quote it. A source rule offers "Also ask me".
    func testOnlyASourceRuleOffersTheAskSwitchAndATickRuleKeepsItsMorningLine() {
        var tick = ProtocolRuleDraft(rule: Data_.stretch)
        XCTAssertFalse(tick.offersAlsoAsk)
        XCTAssertTrue(tick.keepsMorningLine)
        tick.rebuttal = "Two minutes is enough."
        let rule = tick.rule(key: "stretch")
        XCTAssertTrue(rule.isEvening)
        XCTAssertEqual(rule.rebuttal, "Two minutes is enough.")
        XCTAssertFalse(ProtocolRuleDraft(rule: Data_.stretch).rule(key: "stretch").isEvening, "no line, nothing changes")

        var food = ProtocolRuleDraft(rule: Data_.alcohol)
        XCTAssertTrue(food.offersAlsoAsk)
        XCTAssertFalse(food.keepsMorningLine, "the line waits for Also ask me")
        food.isEvening = true
        XCTAssertTrue(food.keepsMorningLine)
        XCTAssertEqual(ProtocolRulesText.eveningTitle, "Also ask me, even when it is checked for me")
    }

    /// ICP R2-HAB-08: the editor's first line says what the folded options hold.
    func testTheEditorSummarySaysDaysTimeWhoChecksAndTheReminder() {
        var draft = ProtocolRuleDraft.newRule()
        XCTAssertEqual(draft.summary(locale: Data_.locale), "Every day. You tick it in the check-in.")
        draft.hasTime = true
        draft.minuteOfDay = 21 * 60 + 45
        draft.remindMe = true
        draft.daysMode = .someDays
        draft.chosenDays = [.monday, .wednesday, .friday]
        XCTAssertEqual(draft.summary(locale: Data_.locale), "Mon, Wed, Fri at 21:45. You tick it in the check-in. Reminder on.")
        draft.chosenDays = []
        XCTAssertTrue(draft.summary(locale: Data_.locale).hasPrefix("No days picked yet"))

        var bed = ProtocolRuleDraft(rule: Data_.bed)
        XCTAssertEqual(bed.summary(locale: Data_.locale), "Every day at 22:30. The band checks it for you. You answer it too.")
        bed.isEvening = false
        XCTAssertEqual(bed.summary(locale: Data_.locale), "Every day at 22:30. The band checks it for you.")
        XCTAssertEqual(ProtocolRuleDraft.DaysMode.allCases.map(\.title),
                       ["Every day", "Some days", "A few times a week", "Once a week or less"], "ICP R2-SEN-10")
    }

    /// ICP R2-HAB-05, R2-DES-15: a daily rule's row has this week's seven dots and its run from 3 days on. Days off and
    /// skipped days are passed over, a miss or a past day nobody could check ends the run, and today counts once kept.
    func testARowShowsTheWeeksDotsAndTheRun() {
        let lastWeek = (6...12).map { Data_.input($0, .past, ["stretch": .kept, "light": $0 == 10 ? .missed : .kept]) }
        let week = [Data_.input(13, .past, ["stretch": .kept, "light": .kept]),
                    Data_.input(14, .today, ["stretch": .pending, "light": .kept])] + (15...19).map { Data_.input($0, .future, [:]) }
        let rows = ProtocolRulesPresentation.sections(Data_.rules, today: Data_.day(14), week: week, lastWeek: lastWeek,
                                                      locale: Data_.locale).flatMap(\.rows)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.rule.key, $0) })
        let stretch = byKey["stretch"]
        XCTAssertEqual(stretch?.weekDots.map(\.state), [.kept, .open, .future, .future, .future, .future, .future])
        XCTAssertEqual(stretch?.weekDots.map(\.dayName).first, "Mon")
        XCTAssertEqual(stretch?.weekDots[1].isToday, true)
        XCTAssertEqual(stretch?.run, 8, "today is open, so the run counts back from Monday")
        XCTAssertEqual(stretch?.runText, "8 days in a row")
        XCTAssertEqual(byKey["light"]?.run, 4, "Friday's miss ends it: Sat, Sun, Mon and today")
        XCTAssertTrue(stretch?.accessibilityLabel.contains("This week: Mon kept, Tue not answered yet") ?? false)

        let short = ProtocolRuleWeek.run(for: Data_.light, week: week, lastWeek: [])
        XCTAssertEqual(short, 2)
        XCTAssertNil(ProtocolRuleRow(rule: Data_.light, title: "Morning light", caption: "", run: 2).runText, "under 3 is not a run")

        let gym = ProtocolRule(key: "gym", title: "Gym", cadence: .on([.monday, .wednesday, .friday]))
        // The loader leaves a rule out of its off days, as here.
        func gymDay(_ day: Int, _ phase: ProtocolDayPhase) -> ProtocolDayInput {
            let due = gym.isDue(on: Data_.day(day))
            return Data_.input(day, phase, phase == .future ? [:] : ["gym": .kept], rules: due ? [gym] : [])
        }
        let gymWeek = (6...13).map { gymDay($0, .past) } + [gymDay(14, .today)] + (15...19).map { gymDay($0, .future) }
        XCTAssertEqual(ProtocolRuleWeek.run(for: gym, week: Array(gymWeek.suffix(7)), lastWeek: Array(gymWeek.prefix(7))), 4,
                       "off days neither add nor break: Mon, Wed, Fri, Mon")
        XCTAssertEqual(ProtocolRuleWeek.dots(for: gym, week: Array(gymWeek.suffix(7))).map(\.state),
                       [.kept, .off, .future, .off, .future, .off, .off])

        let sick = [Data_.input(13, .past, ["stretch": .skipped]), Data_.input(14, .today, ["stretch": .kept])]
            + (15...19).map { Data_.input($0, .future, [:]) }
        XCTAssertEqual(ProtocolRuleWeek.run(for: Data_.stretch, week: sick, lastWeek: lastWeek), 8, "a skipped day is passed over")
        let unknown = [Data_.input(13, .past, [:]), Data_.input(14, .today, ["stretch": .kept])] + (15...19).map { Data_.input($0, .future, [:]) }
        XCTAssertEqual(ProtocolRuleWeek.run(for: Data_.stretch, week: unknown, lastWeek: lastWeek), 1, "a day nobody checked ends it")

        let weekly = ProtocolRule(key: "zone2w", title: "Zone 2, 150 min a week", source: .band, cadence: RuleCadence(unit: .week))
        XCTAssertTrue(ProtocolRuleWeek.dots(for: weekly, week: week).isEmpty, "a longer rule shows its progress, not dots")
        XCTAssertTrue(ProtocolRulesPresentation.row(Data_.stretch).weekDots.isEmpty, "read-only lists have no dots")
    }

    // MARK: Times in names (ICP R1-OPT-9)

    func testTheNamesTimeMovesWithTheWheelItStandsFor() {
        var screens = ProtocolRuleDraft(rule: Data_.screens)
        XCTAssertFalse(screens.titleFollowsTarget)
        screens.setMinuteOfDay(22 * 60)
        XCTAssertEqual(screens.title, "Screens off by 22:00")
        XCTAssertEqual(screens.rule(key: "screens").timeOfDayMinutes, 22 * 60)

        var bed = ProtocolRuleDraft(rule: Data_.bed)
        XCTAssertTrue(bed.titleFollowsTarget, "In bed by 22:30 names the target, not the reminder time")
        bed.setMinuteOfDay(21 * 60)
        XCTAssertEqual(bed.title, "In bed by 22:30", "Moving the reminder time leaves a target time alone")
        bed.setTargetMinute(23 * 60)
        XCTAssertEqual(bed.title, "In bed by 23:00")

        var stretch = ProtocolRuleDraft(rule: Data_.stretch)
        stretch.setMinuteOfDay(7 * 60)
        XCTAssertEqual(stretch.title, "Stretch")
    }

    func testTheEditorSaysHowANameWithATimeShows() {
        let draft = ProtocolRuleDraft(rule: Data_.screens)
        XCTAssertNil(draft.shownTitle(locale: Data_.locale), "A 24-hour locale shows the name as typed")
        let shown = draft.shownTitle(locale: Locale(identifier: "en_US"))
        XCTAssertNotNil(shown)
        XCTAssertFalse(shown?.contains("21:45") ?? true)
        XCTAssertNil(ProtocolRuleDraft(rule: Data_.stretch).shownTitle(locale: Locale(identifier: "en_US")))
    }

    func testTheRulesListShowsTheNameInTheLocalesClock() {
        let us = Locale(identifier: "en_US")
        let row = ProtocolRulesPresentation.sections([Data_.screens], locale: us)[0].rows[0]
        XCTAssertEqual(row.title, Data_.screens.displayTitle(locale: us))
        XCTAssertFalse(row.title.contains("21:45"), "The name and the caption use one clock")
        XCTAssertTrue(row.accessibilityLabel.hasPrefix(row.title))
    }

    // MARK: Pass

    func testThePassCountsAndDescribesTheFile() throws {
        let file = ProtocolFile(name: "Sleep first", author: "Pascal", lineage: ProtocolLineage(forkedFromName: "sleep-first"),
                                version: 7, createdAt: Data_.now, rules: Data_.rules, experiments: [
                                    ProtocolExperimentDesign(title: "Magnesium", interventionRuleKey: "magnesium", design: .alternatingDays, washout: 0,
                                                             minimumNightsPerArm: 5, plannedNights: 14, outcome: .deepSleep)])
        let data = try ProtocolFileCodec.encode(file)
        let pass = ProtocolPass.make(file: file, data: data, keptPercent: 86)
        XCTAssertEqual(pass.versionText, "v7")
        XCTAssertEqual(pass.byline, "by Pascal \u{00B7} fork of sleep-first")
        XCTAssertEqual(pass.ruleCount, 10)
        XCTAssertEqual(pass.keptText, "86%")
        XCTAssertEqual(pass.experimentCount, 1)
        XCTAssertEqual(pass.fileName, "sleep-first.looprprotocol")
        XCTAssertEqual(pass.byteCount, data.count, "the real size of the encoded file")
        XCTAssertTrue(pass.fileDetail.hasSuffix("rules and experiment designs only. No health data inside."))
        XCTAssertEqual(pass.countsAccessibilityLabel, "10 rules, 86 percent kept this week, 1 experiment")
        XCTAssertTrue(pass.rosetteAccessibilityLabel.hasPrefix("Rosette of 10 rules"))
        XCTAssertEqual(pass.fingerprint, ProtocolPassFingerprint(data: data), "the same file gives the same fingerprint")
        XCTAssertNotEqual(pass.fingerprint, ProtocolPassFingerprint(data: data + Data("x".utf8)))
        XCTAssertEqual(pass.fingerprint.levels.count, ProtocolPassFingerprint.dotCount, "one row of dots, not a grid")

        XCTAssertEqual(ProtocolPass.sizeText(812), "812 bytes")
        XCTAssertEqual(ProtocolPass.sizeText(3_277), "3.2 KB")
        XCTAssertNil(ProtocolPass.make(file: ProtocolFile(name: "Mine", version: 1, createdAt: Data_.now, rules: []), data: Data(),
                                       keptPercent: nil).byline)
    }

    func testTheFingerprintIsTheStartOfTheFilesSHA256() {
        // SHA-256 of no bytes starts e3b0c44298fc.
        let empty = ProtocolPassFingerprint(data: Data())
        XCTAssertEqual(empty.hex, "e3b0c44298fc")
        XCTAssertEqual(empty.text, "e3b0 c442 98fc")
        XCTAssertEqual(empty.levels, [3, 2, 3, 1, 2, 3], "the top two bits of each byte pick one of four dot sizes")
        XCTAssertEqual(empty.accessibilityLabel, "File fingerprint: e 3 b 0, c 4 4 2, 9 8 f c")
        XCTAssertEqual(ProtocolPassFingerprint.caption, "Fingerprint of this file. Two copies match when these match.")
    }

    // MARK: Import review

    func testTheImportReviewSaysWhatChangesAgainstTheCurrentVersion() throws {
        let file = ProtocolFile(name: "Theirs", author: "Robin", version: 2, createdAt: Data_.now,
                                rules: [Data_.light, Data_.bed.with(timeOfDayMinutes: .some(22 * 60)), Data_.stretch,
                                        ProtocolRule(key: "walk", title: "Walk")])
        let preview = try ProtocolFileCodec.validate(try ProtocolFileCodec.encode(file))
        let review = ProtocolImportReview.make(preview, current: [Data_.light, Data_.bed, Data_.screens.with(rebuttal: .some("Mine"))],
                                               currentVersion: 7, locale: Data_.locale)
        XCTAssertEqual(review.byline, "by Robin")
        XCTAssertEqual(review.changeLines, ["Changes In bed by 22:30: time", "Removes Screens off by 21:45", "Adds Stretch", "Adds Walk"])
        XCTAssertEqual(review.headline, "Against your version 7: 2 added, 1 removed, 1 changed. Using it saves version 8.")
        XCTAssertEqual(ProtocolImportReview.make(preview, current: nil, currentVersion: nil).headline,
                       "This becomes version 1 of your protocol, with 4 rules.")
    }

    func testTheFiveTemplatesEachHaveALine() {
        let choices = ProtocolTemplateChoice.all()
        XCTAssertEqual(choices.map(\.id), ["gentle-start", "sleep-first", "fitness-for-the-long-run", "everything-at-once", "start-empty"])
        XCTAssertTrue(choices.allSatisfy { !$0.detail.isEmpty && !$0.detail.contains("\u{2014}") && !$0.detail.contains("!") })
        XCTAssertEqual(choices[4].ruleCount, 0)
    }

    // MARK: Model

    private func model(_ source: RulesSource) async -> ProtocolTabModel {
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()), timeZone: Data_.zone,
                                     locale: Data_.locale, now: { Data_.now })
        await model.load()
        return model
    }

    func testSavingARuleWritesTheNextVersionAndSaysSoAfterwardsWithUndo() async throws {
        let source = RulesSource()
        let model = await model(source)
        XCTAssertEqual(model.routine?.version, 1)
        var draft = model.draft(for: Data_.screens)
        draft.minuteOfDay = 22 * 60
        draft.rebuttal = "Sleep wins"
        XCTAssertFalse(model.hasEarlierVersions, "Versions waits for a second version (ICP R1-DES-16)")
        let saved = await model.saveRule(draft)
        let notice = try XCTUnwrap(saved)
        XCTAssertEqual(notice.message, "Saved as version 2.", "the version line comes after Save (ICP R1-HAB-19)")
        XCTAssertTrue(notice.canUndo)
        XCTAssertEqual(model.routine?.version, 2)
        XCTAssertFalse(model.headerMeta.contains("Version"), "The version lives on Rules, not in the header (R1-DES-16)")
        XCTAssertTrue(model.hasEarlierVersions)
        XCTAssertEqual(model.rulesTitle, "Your rules")
        XCTAssertEqual(model.versionEntries.map(\.number), [2, 1])
        let saves = await source.saves
        XCTAssertEqual(saves.count, 1, "one save writes one version")
        XCTAssertEqual(saves[0].first { $0.key == "screens" }?.rebuttal, "Sleep wins")

        let undone = await model.undoSave(notice)
        XCTAssertEqual(undone?.message, ProtocolRulesText.undone)
        XCTAssertEqual(undone?.canUndo, false)
        XCTAssertEqual(model.routine?.version, 3, "undo saves the old rules as the next version")
        XCTAssertEqual(model.routine?.rules, Data_.rules)

        var removal = model.draft(for: Data_.stretch)
        removal.isRemoved = true
        let removed = await model.saveRule(removal)
        XCTAssertEqual(removed?.message, "Removed Stretch. Saved as version 4.")

        var moved = model.draft(for: Data_.light)
        moved.minuteOfDay = 7 * 60
        _ = await model.saveRule(moved, reason: "Earlier sun now.")
        let reasons = await source.reasons
        XCTAssertEqual(reasons.last, "Earlier sun now.", "Why this change? goes to the source (ICP R2-VET-07)")
        XCTAssertEqual(reasons.first, .some(nil))
    }

    func testAFileArrivingOpensTheReviewOnRulesAndUseSavesIt() async throws {
        let source = RulesSource()
        let model = await model(source)
        model.receive(.preview(try ProtocolTemplate.sleepFirst.load()))
        XCTAssertEqual(model.requestedSegment, .rules)
        XCTAssertEqual(model.importReview?.name, "Sleep first")
        XCTAssertNil(model.importError)
        let used = await model.useImport()
        XCTAssertTrue(used)
        XCTAssertNil(model.importReview)
        let adopted = await source.adopted
        XCTAssertEqual(adopted, ["Sleep first"])

        model.receive(.rejected("This file is not a Loopr protocol."))
        XCTAssertEqual(model.importError, "This file is not a Loopr protocol.")
        XCTAssertNil(model.importReview, "a refused file opens no review")
        let after = await source.adopted
        XCTAssertEqual(after.count, 1, "a refused file changes nothing")
    }

    func testThePassUsesTheSourcesFileAndTheWeeksKeptShare() async throws {
        let model = await model(RulesSource())
        let made = await model.passContent()
        let content = try XCTUnwrap(made)
        XCTAssertEqual(content.pass.ruleCount, Data_.rules.count)
        XCTAssertEqual(content.pass.byteCount, content.document.data.count)
        XCTAssertEqual(content.pass.keptPercent, model.summary?.percent)
    }

    // MARK: Round 3 (ICP R3)

    /// ICP R3-NEW-10, R3-VET-12: the rule under test says so on its row and to VoiceOver.
    func testTheRuleUnderTestShowsItsNight() {
        let rows = ProtocolRulesPresentation.sections(Data_.rules, tests: ["magnesium": "Under test, night 9 of 14"],
                                                      locale: Data_.locale).flatMap(\.rows)
        let magnesium = rows.first { $0.rule.key == "magnesium" }
        XCTAssertEqual(magnesium?.testText, "Under test, night 9 of 14")
        XCTAssertTrue(magnesium?.accessibilityLabel.contains("Under test, night 9 of 14") == true)
        XCTAssertNil(rows.first { $0.rule.key == "screens" }?.testText)
        XCTAssertEqual(ProtocolRulesPresentation.testTexts(running: nil), [:])
    }

    /// ICP R3-VET-08: the editor shows where a rule comes from, read only, trimmed. A new rule has none.
    func testTheEditorShowsWhereARuleComesFrom() {
        let sourced = Data_.screens.with(evidence: .some("  No study sets how long to stay off screens.  "))
        XCTAssertEqual(ProtocolRuleDraft(rule: sourced).evidence, "No study sets how long to stay off screens.")
        XCTAssertNil(ProtocolRuleDraft(rule: Data_.screens.with(evidence: .some("   "))).evidence)
        XCTAssertNil(ProtocolRuleDraft.newRule().evidence)
        XCTAssertEqual(ProtocolRuleDraft(rule: sourced).rule(key: "screens").evidence, sourced.evidence, "Save keeps it as it was")
    }

    /// ICP R3-DES-07: the "How often" row shows the real cadence, not the mode's name.
    func testHowOftenShowsTheRealCadence() {
        var draft = ProtocolRuleDraft.newRule()
        XCTAssertEqual(draft.cadenceSummary, "Every day")
        draft.daysMode = .someDays
        XCTAssertEqual(draft.cadenceSummary, "No days picked yet")
        draft.chosenDays = [.monday, .wednesday, .friday]
        XCTAssertEqual(draft.cadenceSummary, "Mon, Wed, Fri")
        draft.daysMode = .timesAWeek
        draft.timesPerWeek = 3
        XCTAssertEqual(draft.cadenceSummary, "3 times a week")
        let panel = ProtocolRule(key: "panel", title: "Blood panel", group: .tests, cadence: RuleCadence(unit: .month, every: 3))
        XCTAssertEqual(ProtocolRuleDraft(rule: panel).cadenceSummary, "Every 3 months")
    }

    /// ICP R3-VET-09: a weekly amount reads as a pace, with the days the week still has.
    func testAWeeklyAmountSaysHowManyDaysAreLeft() {
        XCTAssertEqual(ProtocolRulesPresentation.daysLeftInWeek(Data_.day(13)), 7, "Monday")
        XCTAssertEqual(ProtocolRulesPresentation.daysLeftInWeek(Data_.day(19)), 1, "Sunday")
        let amount = RuleProgress.amount(measured: 112, target: 150, unit: "min")
        XCTAssertEqual(ProtocolRulesPresentation.progressText(amount, today: Data_.day(19)), "112 of 150 min \u{00B7} last day")
        XCTAssertEqual(ProtocolRulesPresentation.progressText(amount, today: nil), "112 of 150 min this week")
        XCTAssertEqual(ProtocolRulesPresentation.progressText(.amount(measured: 160, target: 150, unit: "min"), today: Data_.day(14)),
                       "160 of 150 min \u{00B7} done this week")
        XCTAssertNil(ProtocolRulesPresentation.weekShare(.amount(measured: nil, target: 150, unit: "min")), "nothing measured is no bar")
        XCTAssertEqual(ProtocolRulesPresentation.weekShare(.amount(measured: 160, target: 150, unit: "min")), 1)
    }

    /// ICP R3-VET-05: a second rule on the same measure asks first, in words that name it.
    func testASecondRuleOnTheSameMeasureAsksKeepBoth() async throws {
        let source = RulesSource()
        let model = await model(source)
        var weekly = ProtocolRuleDraft.newRule()
        weekly.title = "Zone 2, 150 min a week"
        weekly.setSource(.band)
        weekly.setMetric(.zone2Minutes)
        weekly.setAmount(150)
        weekly.daysMode = .lessOften
        XCTAssertEqual(model.ruleSharingMeasure(with: weekly)?.key, "zone2")
        XCTAssertEqual(ProtocolRulesText.overlapTitle(Data_.zone2), "You already have a Zone 2 rule. Keep both?")
        XCTAssertEqual(ProtocolRulesText.overlapTitle(Data_.alcohol), "You already have an alcohol rule. Keep both?")
        XCTAssertEqual(ProtocolRulesText.overlapDetail(Data_.zone2, locale: Data_.locale),
                       "Zone 2 for 30 minutes already checks this. With both, one reading counts twice.")

        var raised = model.draft(for: Data_.zone2)
        raised.setAmount(45)
        XCTAssertNil(model.ruleSharingMeasure(with: raised), "an edit that keeps its measure never asks")
        var manual = ProtocolRuleDraft.newRule()
        manual.title = "Stretch again"
        XCTAssertNil(model.ruleSharingMeasure(with: manual), "a rule you tick measures nothing")

        let saved = await model.saveRule(weekly, replacing: "zone2")
        let notice = try XCTUnwrap(saved)
        XCTAssertEqual(notice.message, "Replaced Zone 2 for 30 minutes. Saved as version 2.")
        let saves = await source.saves
        XCTAssertEqual(saves.last?.contains { $0.key == "zone2" }, false, "Replace takes the old rule out in the same version")
        XCTAssertEqual(saves.last?.last?.title, "Zone 2, 150 min a week")
    }

    /// ICP R3-HAB-08: after a new rule the toast offers "Add another" instead of Undo.
    func testANewRuleOffersAddAnother() async throws {
        let model = await model(RulesSource())
        var gym = ProtocolRuleDraft.newRule()
        gym.title = "Gym"
        let saved = await model.saveRule(gym)
        let notice = try XCTUnwrap(saved)
        XCTAssertEqual(notice.message, "Added Gym. Saved as version 2.")
        XCTAssertTrue(notice.addsAnother)
        XCTAssertEqual(notice.toast.actionTitle, "Add another")
        XCTAssertFalse(notice.canUndo)

        var moved = model.draft(for: Data_.light)
        moved.minuteOfDay = 7 * 60
        let edited = await model.saveRule(moved)
        XCTAssertEqual(edited?.toast.actionTitle, "Undo", "an edit still offers Undo")
        XCTAssertEqual(edited?.addsAnother, false)
    }

    func testATemplateMakesVersionOne() async {
        let source = RulesSource(startsEmpty: true)
        let model = await model(source)
        XCTAssertEqual(model.content?.routine, .noProtocol)
        let installed = await model.installTemplate(.sleepFirst)
        XCTAssertTrue(installed)
        XCTAssertEqual(model.routine?.version, 1)
        XCTAssertEqual(model.routine?.protocolName, "Sleep first")
    }
}

/// A source that keeps its versions in memory.
private actor RulesSource: ProtocolTabSource {
    private var versionList: [ProtocolVersion] = []
    private var name = "My protocol"
    private(set) var saves: [[ProtocolRule]] = []
    private(set) var reasons: [String?] = []
    private(set) var adopted: [String] = []
    private let id = ProtocolID()

    init(startsEmpty: Bool = false) {
        if !startsEmpty {
            versionList = [try! ProtocolVersion(protocolID: id, number: 1, createdAt: ProtocolTestData.now, rules: ProtocolTestData.rules)]
        }
    }

    func load(now: Date) async -> ProtocolTabContent {
        guard let latest = versionList.last else { return ProtocolTabContent(routine: .noProtocol) }
        let week = ProtocolTestData.week(monday: [:])
        return ProtocolTabContent(routine: .ready(ProtocolRoutineData(
            protocolName: name, version: latest.number, versionCreatedAt: latest.createdAt, dayNumber: 2, rules: latest.rules,
            week: week, lastWeek: [], today: ProtocolTestData.day(14), nowMinute: 22 * 60 + 13)))
    }

    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws {}
    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws {}
    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws {}

    func saveRules(_ rules: [ProtocolRule], now: Date) async throws -> ProtocolVersion {
        try await saveRules(rules, reason: nil, now: now)
    }

    func saveRules(_ rules: [ProtocolRule], reason: String?, now: Date) async throws -> ProtocolVersion {
        saves.append(rules)
        reasons.append(reason)
        return try append(rules.map(\.normalized), now: now)
    }

    func versions() async throws -> [ProtocolVersion] { versionList }

    func protocolFile() async throws -> ProtocolFile {
        guard let latest = versionList.last else { throw RoutineError.missingProtocol }
        return ProtocolFile(name: name, version: latest.number, createdAt: latest.createdAt, rules: latest.rules.map(\.withoutRebuttal))
    }

    func installTemplate(_ template: ProtocolTemplate, now: Date) async throws {
        guard versionList.isEmpty else { throw ProtocolEditError.protocolExists }
        name = template.title
        _ = try append(try template.load().file.rules, now: now)
    }

    func adoptFile(_ preview: ProtocolImportPreview, now: Date) async throws -> ProtocolVersion {
        adopted.append(preview.file.name)
        name = preview.file.name
        return try append(preview.file.rules, now: now)
    }

    private func append(_ rules: [ProtocolRule], now: Date) throws -> ProtocolVersion {
        let next = try ProtocolVersion(protocolID: id, number: (versionList.last?.number ?? 0) + 1, createdAt: now, rules: rules)
        versionList.append(next)
        return next
    }
}
