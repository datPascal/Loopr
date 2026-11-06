import DomainKit
import Foundation
@testable import JournalKit
import RoutineKit
import XCTest

/// ICP round 1, W1: the start screen's choices, the template preview, and the "Your list is ready" card with its
/// reminder offer.
@MainActor
final class ProtocolStartTests: XCTestCase {
    private typealias Data_ = ProtocolTestData

    // MARK: Start screen

    /// R1-NEW-01, R1-SEN-01: a newcomer meets the templates, the gentlest first and marked, and no "Use my questions".
    func testANewcomerSeesTheTemplatesWithTheGentlestFirstAndNoQuestions() {
        let start = ProtocolStart.make(hasQuestions: false)
        XCTAssertFalse(start.offersQuestions)
        XCTAssertEqual(start.choices.map(\.id), ["gentle-start", "sleep-first", "fitness-for-the-long-run", "everything-at-once", "start-empty"])
        XCTAssertEqual(start.recommended?.template, .gentleStart)
        XCTAssertEqual(start.choices.filter(\.isRecommended).count, 1, "one template says Start here")
    }

    /// R1-HAB-11: a person with Journal questions gets "Use my questions" as a secondary row; the templates still lead.
    func testAPersonWithQuestionsAlsoGetsTheQuestionsRow() {
        let start = ProtocolStart.make(hasQuestions: true)
        XCTAssertTrue(start.offersQuestions)
        XCTAssertEqual(start.choices.first?.template, .recommended)
        XCTAssertEqual(start.choices.last?.template, .startEmpty)
    }

    /// The recommended template leads and Start empty closes the list, whatever order the bundle gives.
    func testTheOrderHoldsWhateverTheBundleOrder() {
        let reversed = ProtocolTemplateChoice.all().reversed()
        XCTAssertEqual(ProtocolStart.make(hasQuestions: false, choices: Array(reversed)).choices.map(\.template),
                       [.gentleStart, .everythingAtOnce, .fitnessForTheLongRun, .sleepFirst, .startEmpty])
    }

    /// R1-SEN-13, R2-NEW-11: the line counts every rule a source checks (band, Food, Fitness, Apple Health), which is
    /// how little the person ticks, and never names a device to buy.
    func testEachTemplateSaysWhatIsInItAndHowManyLooprChecks() {
        let choices = Dictionary(uniqueKeysWithValues: ProtocolTemplateChoice.all().map { ($0.template, $0) })
        XCTAssertEqual(choices[.gentleStart]?.counts, "3 rules. Loopr checks 2 of the 3 for you.")
        XCTAssertEqual(choices[.sleepFirst]?.counts, "6 rules. Loopr checks 5 of the 6 for you.")
        XCTAssertEqual(choices[.fitnessForTheLongRun]?.counts, "6 rules. Loopr checks 4 of the 6 for you.")
        XCTAssertEqual(choices[.everythingAtOnce]?.counts, "12 rules. Loopr checks 10 of the 12 for you.")
        XCTAssertNil(choices[.startEmpty]?.counts)
        XCTAssertEqual(choices[.startEmpty]?.detail, "No rules. You add your own, one at a time.")
        for choice in choices.values {
            XCTAssertFalse(choice.detail.contains("need"), choice.detail)
            XCTAssertFalse(choice.detail.contains("\u{2014}") || choice.detail.contains("!"), choice.detail)
        }
        let band = ProtocolTemplateChoice(template: .sleepFirst, rules: [Data_.bed])
        XCTAssertEqual(band.counts, "1 rule. Loopr checks it for you.")
        XCTAssertEqual(ProtocolTemplateChoice(template: .sleepFirst, rules: [Data_.bed, Data_.zone2]).counts,
                       "2 rules. Loopr checks both for you.")
        XCTAssertEqual(ProtocolTemplateChoice(template: .sleepFirst, rules: [Data_.screens]).counts, "1 rule. You tick it.")
        XCTAssertEqual(ProtocolTemplateChoice(template: .sleepFirst, rules: [Data_.screens, Data_.screens]).counts,
                       "2 rules. You tick each one.")
    }

    /// R1-NEW-04, R1-SEN-05, R1-DES-02: what the list is, said once in one sentence; the first-week card no longer
    /// repeats it. R2-SEN-04: the start screen says "your list" and "rules", never "protocol".
    func testTheListSentenceIsOneSentenceAndTheIntroOnlyFollowsAMove() {
        let lead = ProtocolIntro.lead
        XCTAssertEqual(lead.split(separator: ".").count, 1)
        XCTAssertFalse(lead.contains("\u{2014}"))
        let startWords = [ProtocolStart.title, ProtocolStart.previewHint, lead, ProtocolStart.questionsTitle, ProtocolStart.questionsDetail,
                          ProtocolStart.gitHubTitle, ProtocolStart.gitHubDetail, ProtocolStart.importDetail]
            + ProtocolTemplateChoice.all().map(\.detail)
        for text in startWords { XCTAssertFalse(text.lowercased().contains("protocol"), text) }
        XCTAssertTrue(lead.contains("Your list") && lead.contains("rules"))
        let fresh = routine(rules: [Data_.screens], day: 1)
        XCTAssertFalse(ProtocolIntro.shows(fresh), "a template's first week gets the ready card, not the intro")
        let moved = ProtocolRoutineData(protocolName: "Mine", version: 1, versionCreatedAt: Data_.now, dayNumber: 1, rules: [Data_.screens],
                                        week: Data_.week(monday: [:]), lastWeek: [], today: Data_.day(14), nowMinute: 0,
                                        habitRuleIDs: [UUID()])
        XCTAssertTrue(ProtocolIntro.shows(moved))
    }

    // MARK: Preview

    /// R1-NEW-03, R1-VET-15: every rule says who checks it and why it is there, before anything is saved.
    func testThePreviewListsEachRuleWithWhoChecksItAndWhy() throws {
        let choice = try XCTUnwrap(ProtocolTemplateChoice.all().first { $0.template == .gentleStart })
        let preview = ProtocolTemplatePreview.make(choice, locale: Data_.locale)
        XCTAssertEqual(preview.title, "A gentle start")
        XCTAssertEqual(preview.useTitle, "Use these 3 rules")
        XCTAssertEqual(preview.rows.map(\.key), ["in-bed", "steps", "alcohol"])
        XCTAssertEqual(preview.rows.map(\.checker), ["Your band checks this", "Apple Health checks this", "You tick this"])
        XCTAssertTrue(preview.rows.allSatisfy { $0.why?.isEmpty == false })
        // R2-NEW-07: the short why, then the source under "Where this comes from".
        XCTAssertTrue(preview.rows.allSatisfy { $0.evidence?.isEmpty == false })
        let label = preview.rows[0].accessibilityLabel
        XCTAssertTrue(label.hasPrefix("In bed by 22:30. Your band checks this. A steady bedtime"), label)
        XCTAssertTrue(label.contains("Where this comes from. The American Academy of Sleep Medicine"), label)

        let fitness = try XCTUnwrap(ProtocolTemplateChoice.all().first { $0.template == .fitnessForTheLongRun })
        let rows = ProtocolTemplatePreview.make(fitness, locale: Data_.locale).rows
        XCTAssertEqual(rows.first?.caption, "Each week \u{00B7} Your band checks this")
        XCTAssertEqual(rows.last?.caption, "Each month \u{00B7} You tick this")

        let empty = try XCTUnwrap(ProtocolTemplateChoice.all().first { $0.template == .startEmpty })
        XCTAssertEqual(ProtocolTemplatePreview.make(empty).useTitle, "Start with no rules")
        XCTAssertEqual(ProtocolTemplatePreview.checker(.food), "Food checks this")
        XCTAssertEqual(ProtocolTemplatePreview.checker(.fitness), "Fitness checks this")
    }

    /// The preview's times follow the locale's clock, like the rule rows.
    func testThePreviewTitlesUseTheLocalesClock() throws {
        let choice = try XCTUnwrap(ProtocolTemplateChoice.all().first { $0.template == .gentleStart })
        let us = ProtocolTemplatePreview.make(choice, locale: Locale(identifier: "en_US"))
        let title = try XCTUnwrap(us.rows.first?.title)
        XCTAssertTrue(title.hasPrefix("In bed by 10:30") && !title.contains("22:30"), title)
    }

    /// Using a template from the preview installs it and sends the screen to Check-in; Cancel saves nothing.
    func testUsingATemplateInstallsItAndCancelInstallsNothing() async {
        let source = StartSource()
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()), timeZone: Data_.zone,
                                     locale: Data_.locale, now: { Data_.now })
        await model.load()
        XCTAssertEqual(model.content?.routine, .noProtocol)
        let installedBefore = await source.installed
        XCTAssertTrue(installedBefore.isEmpty, "opening and cancelling a preview calls nothing")
        let used = await model.installTemplate(.gentleStart)
        XCTAssertTrue(used)
        XCTAssertEqual(model.routine?.protocolName, "A gentle start")
        XCTAssertEqual(model.routine?.rules.compactMap(\.why).count, 3, "the whys travel with the template")
    }

    // MARK: Ready card

    /// R1-SEN-03: the card shows on a new protocol's first day until it is dismissed, and never on an older one.
    func testTheReadyCardShowsOnDayOneUntilDismissed() {
        let fresh = routine(rules: [Data_.screens, Data_.bed], day: 1)
        XCTAssertTrue(ProtocolReady.shows(fresh, dismissed: 0))
        XCTAssertFalse(ProtocolReady.shows(fresh, dismissed: ProtocolReady.stamp(fresh)))
        XCTAssertTrue(ProtocolReady.shows(fresh, dismissed: ProtocolReady.stamp(fresh) - 86_400), "a dismissal belongs to one protocol")
        XCTAssertFalse(ProtocolReady.shows(routine(rules: [Data_.screens], day: 2), dismissed: 0))
        XCTAssertFalse(ProtocolReady.shows(routine(rules: [], day: 1), dismissed: 0), "Start empty goes to Rules instead")
        XCTAssertFalse(ProtocolReady.shows(routine(rules: [Data_.screens], day: 1, version: 2), dismissed: 0))
    }

    /// R1-SEN-04: 20:30, or an hour before the earliest evening rule the person ticks, never before 17:00.
    func testTheReminderTimeIs2030OrAnHourBeforeTheFirstEveningTick() {
        XCTAssertEqual(ProtocolReady.reminderMinute(for: [Data_.bed, Data_.light]), 20 * 60 + 30, "the band's rule needs no answer")
        XCTAssertEqual(ProtocolReady.reminderMinute(for: [Data_.magnesium, Data_.screens]), 20 * 60 + 30)
        let early = ProtocolRule(key: "walk", title: "Evening walk", timeOfDayMinutes: 19 * 60, isEvening: true)
        XCTAssertEqual(ProtocolReady.reminderMinute(for: [early, Data_.screens]), 18 * 60)
        let veryEarly = ProtocolRule(key: "tea", title: "Tea", timeOfDayMinutes: 17 * 60 + 30, isEvening: true)
        XCTAssertEqual(ProtocolReady.reminderMinute(for: [veryEarly]), 17 * 60)
        XCTAssertEqual(ProtocolReady.reminderMinute(for: []), ProtocolReady.defaultReminderMinute)
    }

    func testTheReadyCardSaysWhatHappensEachEvening() throws {
        let gentle = try ProtocolTemplate.gentleStart.load().file.rules
        XCTAssertEqual(ProtocolReady.make(rules: gentle, locale: Data_.locale).body,
                       "Each evening, Loopr asks you here about 1 rule. Tap Yes or No. The band and Apple Health check the other 2.")
        XCTAssertEqual(ProtocolReady.make(rules: [Data_.screens, Data_.magnesium], locale: Data_.locale).body,
                       "Each evening, Loopr asks you here about 2 rules. Tap Yes or No.")
        XCTAssertEqual(ProtocolReady.make(rules: [Data_.screens, Data_.bed], locale: Data_.locale).body,
                       "Each evening, Loopr asks you here about 1 rule. Tap Yes or No. The band checks the other one.")
        XCTAssertEqual(ProtocolReady.make(rules: [Data_.bed, Data_.zone2], locale: Data_.locale).body,
                       "The band checks both for you. Look here each evening to see how the day went.")
        XCTAssertEqual(ProtocolReady.offer(minute: 20 * 60 + 30, locale: Data_.locale), "Remind me at 20:30 each evening?")
        XCTAssertEqual(ProtocolReady.confirmation(minute: 20 * 60 + 30, locale: Data_.locale), "Reminder set for 20:30")
        XCTAssertTrue(ProtocolReady.offSwitch.contains("Reminders you set"), "The off switch is named where it is in Loopr")
    }

    // MARK: Helpers

    private func routine(rules: [ProtocolRule], day: Int, version: Int = 1) -> ProtocolRoutineData {
        ProtocolRoutineData(protocolName: "A gentle start", version: version, versionCreatedAt: Data_.now, dayNumber: day, rules: rules,
                            week: Data_.week(monday: [:]), lastWeek: [], today: Data_.day(14), nowMinute: 19 * 60 + 49)
    }
}

/// A source with no protocol until a template is installed.
private actor StartSource: ProtocolTabSource {
    private(set) var installed: [ProtocolTemplate] = []
    private var rules: [ProtocolRule]?
    private var name = ""

    func load(now: Date) async -> ProtocolTabContent {
        guard let rules else { return ProtocolTabContent(routine: .noProtocol) }
        return ProtocolTabContent(routine: .ready(ProtocolRoutineData(
            protocolName: name, version: 1, versionCreatedAt: now, dayNumber: 1, rules: rules,
            week: ProtocolTestData.week(monday: [:]), lastWeek: [], today: ProtocolTestData.day(14), nowMinute: 19 * 60 + 49)))
    }

    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws {}
    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws {}
    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws {}

    func installTemplate(_ template: ProtocolTemplate, now: Date) async throws {
        installed.append(template)
        name = template.title
        rules = try template.load().file.rules
    }
}
