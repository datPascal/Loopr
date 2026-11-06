import AIKit
import DesignSystem
import Foundation
import Testing
@testable import Loopr

/// The Ask sheet's pure parts: origin wording, prompt chips and the consent domain list.
struct AskSheetTests {
    private var perth: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }

    // MARK: Origin

    @Test func aBlankPromptIsNoPrompt() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(AskOrigin(screen: "Sleep", day: "2026-10-12", date: date, prompt: "  \n ").prompt == nil)
        #expect(AskOrigin(screen: "Sleep", day: "2026-10-12", date: date, prompt: " Why? ").prompt == "Why?")
        #expect(AskOrigin(screen: "Sleep", day: "2026-10-12", date: date).prompt == nil)
    }

    @Test func theConsentLineNeverCarriesThePrompt() {
        let origin = AskOrigin(screen: "Sleep", day: "2026-10-12", date: Date(timeIntervalSince1970: 1_760_000_000),
                               prompt: "What was different about this night?", dayLabel: "Mon night")
        #expect(origin.contextLine == "Opened from Sleep, selected day 2026-10-12.")
        #expect(origin.chipText == "From Sleep · Mon night")
    }

    @Test func theChipDropsADayThatRepeatsTheScreenName() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(AskOrigin(screen: "Today", day: "2026-10-15", date: date, dayLabel: "Today").chipText == "From Today")
        #expect(AskOrigin(screen: "Today", day: "2026-10-14", date: date, dayLabel: "Yesterday").chipText == "From Today · Yesterday")
    }

    @Test func askFromAPastTodayNamesTheDayInTheChip() {
        // 10 Nov 2026 is a Tuesday. The origin reads FROM TODAY · TUE 10 NOV once the chip uppercases it.
        let today = LooprDay(year: 2026, month: 11, day: 14)
        let past = LooprDay(year: 2026, month: 11, day: 10)
        let navigation = LooprDayNavigation(day: past, today: today, earliest: nil, calendar: perth, onSelect: { _ in })
        let origin = AskOrigin(screen: "Today", navigation: navigation, day: "2026-11-10", date: Date(timeIntervalSince1970: 1_794_000_000))
        #expect(origin.dayLabel == "Tue 10 Nov")
        #expect(origin.chipText == "From Today · Tue 10 Nov")
        #expect(origin.chipText.uppercased() == "FROM TODAY · TUE 10 NOV")
        #expect(origin.isPastDay)
        #expect(origin.contextLine == "Opened from Today, selected day 2026-11-10.")

        let live = LooprDayNavigation(day: today, today: today, earliest: nil, calendar: perth, onSelect: { _ in })
        let now = AskOrigin(screen: "Today", navigation: live, day: "2026-11-14", date: Date(timeIntervalSince1970: 1_794_000_000))
        #expect(now.chipText == "From Today")
        #expect(!now.isPastDay)
    }

    @Test func aPastTodayOffersThePastDayChipsAndNoPresentTenseOnes() {
        let date = Date(timeIntervalSince1970: 1_794_000_000)
        let past = AskOrigin(screen: "Today", day: "2026-11-10", date: date, dayLabel: "Tue 10 Nov", isPastDay: true)
        #expect(AskPrompts.suggestions(for: past) == ["How did I sleep the night before?", "How did this day compare with my usual?", "What changed from the day before?"])
        let asked = AskOrigin(screen: "Today", day: "2026-11-10", date: date, prompt: "How did I sleep the night before?", dayLabel: "Tue 10 Nov", isPastDay: true)
        #expect(AskPrompts.suggestions(for: asked) == ["How did this day compare with my usual?", "What changed from the day before?"],
                "the question already in the field is not offered again")
        // Today itself keeps the general set.
        let live = AskOrigin(screen: "Today", day: "2026-11-14", date: date, dayLabel: "Today")
        #expect(AskPrompts.suggestions(for: live) == AskPrompts.general)
    }

    @Test func theChipFallsBackToTheDayKey() {
        let origin = AskOrigin(screen: "HRV", day: "2026-10-09", date: Date(timeIntervalSince1970: 1_760_000_000))
        #expect(origin.chipText == "From HRV · 2026-10-09")
    }

    @Test func sleepNamesTheNightAndOtherScreensNameTheDay() {
        let today = LooprDay(year: 2026, month: 10, day: 15)
        let tuesday = LooprDay(year: 2026, month: 10, day: 13)
        let sunday = LooprDay(year: 2026, month: 10, day: 18)
        // 12 October 2026 is a Monday. The night that ends on Tuesday the 13th began that evening.
        #expect(AskOrigin.dayLabel(screen: "Sleep", day: tuesday, today: today, calendar: perth) == "Mon night")
        #expect(AskOrigin.dayLabel(screen: "Sleep", day: today, today: today, calendar: perth) == "Last night")
        #expect(AskOrigin.dayLabel(screen: "Sleep", day: sunday, today: LooprDay(year: 2026, month: 10, day: 20), calendar: perth) == "Sat night")
        #expect(AskOrigin.dayLabel(screen: "Food", day: today, today: today, calendar: perth) == "Today")
        #expect(AskOrigin.dayLabel(screen: "Heart", day: tuesday, today: today, calendar: perth) == "Tue 13 Oct")
    }

    @Test func aNightAcrossAMonthNamesTheEvening() {
        let first = LooprDay(year: 2026, month: 11, day: 1)
        #expect(AskOrigin.dayLabel(screen: "Sleep", day: first, today: LooprDay(year: 2026, month: 11, day: 5), calendar: perth) == "Sat night")
    }

    // MARK: Prompt chips

    @Test func everyChipSetHasBetweenTwoAndFourDistinctQuestions() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        for screen in ["Today", "Sleep", "Food", "Food and your body", "Train", "Program", "Journal", "Heart", "HRV", "Strain and load", "Your data"] {
            let chips = AskPrompts.suggestions(for: AskOrigin(screen: screen, day: "2026-10-12", date: date))
            #expect((2...4).contains(chips.count), "\(screen)")
            #expect(Set(chips).count == chips.count, "\(screen)")
            #expect(chips.allSatisfy { $0.hasSuffix("?") || $0.hasPrefix("Help") }, "\(screen)")
        }
        #expect(AskPrompts.suggestions(for: nil) == AskPrompts.general)
    }

    @Test func sleepLeadsWithSleepQuestions() {
        let origin = AskOrigin(screen: "Sleep", day: "2026-10-12", date: Date(timeIntervalSince1970: 1_760_000_000))
        #expect(AskPrompts.suggestions(for: origin).first == "Why did I sleep worse this week?")
    }

    @Test func aChipNeverRepeatsTheQuestionAlreadyInTheField() {
        let prompt = "What was different about this night?"
        let origin = AskOrigin(screen: "Sleep", day: "2026-10-12", date: Date(timeIntervalSince1970: 1_760_000_000), prompt: prompt)
        #expect(!AskPrompts.suggestions(for: origin).contains(prompt))
    }

    // MARK: Consent domains

    @Test func theConsentListUsesYourDataNamesForEveryDomain() {
        let covered = CoachConsentDomain.rows.flatMap(\.domains)
        #expect(Set(covered) == [.metrics, .journalAnswers, .journalNotes, .cycle, .supplements, .labs])
        #expect(Set(CoachConsentDomain.rows.map(\.id)).count == CoachConsentDomain.rows.count)
        let metrics = CoachConsentDomain.rows.first { $0.domains == [.metrics] }
        #expect(metrics?.title == AgentDataDomain.metrics.title)
        let cycle = CoachConsentDomain.rows.first { $0.domains == [.cycle] }
        #expect(cycle?.title == AgentDataDomain.cycle.title)
        let supplements = CoachConsentDomain.rows.first { $0.domains == [.supplements] }
        #expect(supplements?.title == "Supplements and medication")
        let labs = CoachConsentDomain.rows.first { $0.domains == [.labs] }
        #expect(labs?.title == "Blood tests")
        for row in [supplements, labs] {
            let detail = row?.detail ?? ""
            #expect(!detail.isEmpty && !detail.contains("!") && !detail.contains("\u{2014}") && !detail.contains("\u{2013}"), "\(detail)")
        }
    }

    @Test func eachRowFlipsExactlyItsOwnSwitch() {
        for row in CoachConsentDomain.rows {
            var sharing = CoachSharing(metrics: false, journal: false, cycle: false)
            sharing[keyPath: row.keyPath] = true
            let on = [sharing.metrics, sharing.journal, sharing.cycle, sharing.supplements, sharing.labs].filter { $0 }.count
            #expect(on == 1, "\(row.title)")
        }
        let keys = CoachConsentDomain.rows.map { row -> [Bool] in
            var sharing = CoachSharing(metrics: false, journal: false, cycle: false)
            sharing[keyPath: row.keyPath] = true
            return [sharing.metrics, sharing.journal, sharing.cycle, sharing.supplements, sharing.labs]
        }
        #expect(Set(keys).count == keys.count)
    }

    @Test func theDefaultsMatchYourDataOnTheDomainsTheyShare() {
        let defaults = CoachSharing()
        #expect(defaults.metrics == AgentDataDomain.metrics.defaultAllowed)
        #expect(defaults.journal == false)
        #expect(defaults.cycle == AgentDataDomain.cycle.defaultAllowed)
        #expect(defaults.supplements == AgentDataDomain.supplements.defaultAllowed && !defaults.supplements)
        #expect(defaults.labs == AgentDataDomain.labs.defaultAllowed && !defaults.labs)
    }
}
