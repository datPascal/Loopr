import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import Testing
@testable import CoachKit

/// Inputs and checks shared by the coach note suites. Locale and calendar are injected, so nothing reads the device.
enum NoteFixtures {
    static let enUS = Locale(identifier: "en_US")
    static let enGB = Locale(identifier: "en_GB")
    static let deDE = Locale(identifier: "de_DE")

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// The clock text the engine writes for a time of day, from the injected locale and calendar only.
    static func clock(_ minute: Int, _ locale: Locale) -> String {
        NoteContext(locale: locale, calendar: calendar).clockText(minuteOfDay: minute)
    }

    static func writer(_ locale: Locale = enUS) -> CoachNoteWriter {
        CoachNoteWriter(context: NoteContext(locale: locale, calendar: calendar))
    }

    /// Thursday 22 October 2026.
    static let thursday = DayIdentity(year: 2026, month: 10, day: 22)

    static func day(_ offset: Int) -> DayIdentity {
        DayIdentity(year: 2026, month: 9, day: 1 + offset % 28)
    }

    // MARK: Morning

    static let longGroup = NoteFactorGroup(id: "long", label: "4 h or more")
    static let shortGroup = NoteFactorGroup(id: "short", label: "less")

    /// `long` outcomes whose mean is 50 and `short` outcomes whose mean is 55, so the difference is exactly 5 lower.
    static func dinnerHistory(long: Int = 21, short: Int = 9, longMean: Double = 50, shortMean: Double = 55) -> [NoteFactorNight] {
        var nights: [NoteFactorNight] = []
        for index in 0..<long {
            // Alternate one under and one over the mean. An odd count ends on the mean itself.
            let spread: Double = index == long - 1 && long.isMultiple(of: 2) == false ? 0 : (index.isMultiple(of: 2) ? -1 : 1)
            nights.append(NoteFactorNight(day: day(index), groupID: "long", outcome: longMean + spread))
        }
        for index in 0..<short {
            nights.append(NoteFactorNight(day: day(index + 30), groupID: "short", outcome: shortMean))
        }
        return nights
    }

    static func dinner(history: [NoteFactorNight]? = nil, lastGroup: String? = "long",
                       value: NoteFactorValue? = .duration(minutes: 244)) -> NightFactor {
        NightFactor(id: "dinner", name: "Dinner 4 h before bed", statement: "You stopped eating {value} before bed.",
                    lastNightValue: value, lastNightGroupID: lastGroup, groups: [longGroup, shortGroup],
                    history: history ?? dinnerHistory())
    }

    static func alcohol(long: Int, short: Int, shortMean: Double, longMean: Double, id: String = "alcohol") -> NightFactor {
        var history: [NoteFactorNight] = []
        for index in 0..<long { history.append(NoteFactorNight(day: day(index), groupID: "none", outcome: longMean)) }
        for index in 0..<short { history.append(NoteFactorNight(day: day(index), groupID: "some", outcome: shortMean)) }
        return NightFactor(id: id, name: "Alcohol", statement: "You had a drink in the evening.",
                           lastNightValue: .flag, lastNightGroupID: "some",
                           groups: [NoteFactorGroup(id: "some", label: "a drink"), NoteFactorGroup(id: "none", label: "no drink")],
                           history: history)
    }

    static let heartRate = NightOutcome(kind: .sleepHeartRate, value: 49, day: thursday)
    static let usual = NoteUsual(median: 53, nights: 28, windowDays: 30)

    static func morning(factors: [NightFactor]? = nil, usual: NoteUsual? = usual,
                        outcome: NightOutcome? = heartRate) -> MorningNoteInput {
        MorningNoteInput(lastNight: outcome, usual: usual, factors: factors ?? [dinner()])
    }

    // MARK: Evening

    static func rule(_ key: String, _ title: String, at minute: Int?, source: CheckSource = .manual) -> ProtocolRule {
        ProtocolRule(key: RuleKey(rawValue: key), title: title, timeOfDayMinutes: minute, source: source)
    }

    static func ruleDay(_ key: String, _ title: String, at minute: Int?, _ state: CheckState, keptAt: Int? = nil,
                        label: String? = nil, week: Int? = nil, of days: Int? = nil) -> NoteRuleDay {
        NoteRuleDay(rule: rule(key, title, at: minute), state: state, keptAtMinuteOfDay: keptAt, keptLabel: label,
                    keptDaysThisWeek: week, daysThisWeek: days)
    }

    static let kitchen = ruleDay("kitchen", "Kitchen closes", at: 18 * 60 + 30, .kept, keptAt: 18 * 60 + 20,
                                 label: "Kitchen closed", week: 7, of: 7)
    static let screens = ruleDay("screens", "Screens off", at: 21 * 60 + 45, .pending)

    // MARK: Checks

    static let bannedWords = ["caused", "cause", "because", "due to", "!", "\u{2014}", "\u{2013}"]

    static func expectNoCauseWording(_ note: CoachNote, sourceLocation: SourceLocation = #_sourceLocation) {
        let lowered = note.text.lowercased()
        for word in bannedWords {
            #expect(!lowered.contains(word), "The note says \"\(word)\": \(note.text)", sourceLocation: sourceLocation)
        }
    }

    /// Every digit group in the text is a number run, every number run is in the text, and the sets say the same.
    static func expectNumbersExact(_ note: CoachNote, sourceLocation: SourceLocation = #_sourceLocation) {
        for run in note.runs {
            if let number = run.number {
                #expect(run.text == number.displayed, sourceLocation: sourceLocation)
            } else {
                #expect(NoteDigits.tokens(in: run.text).isEmpty, "A text run holds a number: \(run.text)", sourceLocation: sourceLocation)
                #expect(!run.isHighlighted, sourceLocation: sourceLocation)
            }
        }
        let inText = NoteDigits.tokens(in: note.text)
        let inRuns = note.runs.compactMap(\.number).flatMap(\.numerals)
        #expect(inText == inRuns, "Text digits \(inText) differ from the number set \(inRuns)", sourceLocation: sourceLocation)
        #expect(Set(inText) == note.numerals, sourceLocation: sourceLocation)
        for displayed in note.displayedNumbers {
            #expect(note.text.contains(displayed), "\(displayed) is in the set but not in the text", sourceLocation: sourceLocation)
        }
        // Chips and descriptions may state only numbers the note carries.
        var extras = [note.daysCovered]
        extras.append(contentsOf: note.chips.map(\.label))
        if let comparison = note.comparisonGroup { extras.append(comparison) }
        if let receipt = note.receipt { extras.append(contentsOf: receipt.groups.map(\.label)) }
        for text in extras {
            for token in NoteDigits.tokens(in: text) {
                #expect(note.allNumerals.contains(token), "\"\(text)\" states \(token), which the note does not carry",
                        sourceLocation: sourceLocation)
            }
        }
    }

    static func expectClean(_ note: CoachNote, sourceLocation: SourceLocation = #_sourceLocation) {
        expectNoCauseWording(note, sourceLocation: sourceLocation)
        expectNumbersExact(note, sourceLocation: sourceLocation)
    }
}
