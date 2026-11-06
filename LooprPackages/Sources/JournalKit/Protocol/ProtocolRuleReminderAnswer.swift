import DomainKit
import Foundation
import RoutineKit

/// Writes one answer to a protocol rule the way the deck does: Yes on a rule the person ticks is a tick, any other Yes or
/// No overrides what a source said, and Skip skips the rule for that day. The deck and a rule reminder's "Done" and
/// "Skip today" both write through here, so an answer from the lock screen is the same answer as one on the card.
public enum ProtocolRuleAnswerWrite {
    public static func save(_ choice: ProtocolDeckChoice, key: RuleKey, ruleSource: CheckSource, day: DayIdentity,
                            to source: any ProtocolTabSource, now: Date) async throws {
        switch choice {
        case .skip: try await source.skip(key, day: day, now: now)
        case .yes where ruleSource == .manual: try await source.tick(key, day: day, now: now)
        case .yes, .no: try await source.override(key, day: day, kept: choice == .yes, now: now)
        }
    }
}

/// "Done" and "Skip today" on a rule reminder, answered without opening Loopr (ICP R3-HAB-02). The answer is for the day
/// the reminder came on, and only for a rule the newest version still holds and that is due that day, so a reminder left
/// over from a removed rule, or one answered on a day off, writes nothing. A rule a source checks takes no answer from a
/// reminder, so an old reminder cannot write "kept" at 20:30 for "In bed by 22:30", and neither does a running test's off
/// night, which would put a tick into the test's off nights (ICP round 4, Q1b and VET).
public enum ProtocolRuleReminderAnswer {
    public enum Outcome: Equatable, Sendable {
        case saved
        /// The newest version no longer has the rule.
        case ruleGone
        /// The rule is not due that day, so there is nothing to answer.
        case notDue
        /// The band, Food, Fitness or Apple Health checks the rule, so only the deck or the day sheet can change it.
        case checkedBySource
        /// A running test keeps the rule off that night.
        case offNight
    }

    /// - Parameters:
    ///   - rules: the newest version's rules.
    ///   - day: the day the reminder came on, in the person's time zone.
    ///   - offNightTest: the running test that keeps the rule off that night, if any.
    public static func save(_ choice: ProtocolDeckChoice, key: RuleKey, day: DayIdentity, rules: [ProtocolRule],
                            offNightTest: String? = nil, to source: any ProtocolTabSource, now: Date) async throws -> Outcome {
        guard let rule = rules.first(where: { $0.key == key }) else { return .ruleGone }
        guard rule.source == .manual else { return .checkedBySource }
        guard rule.isDue(on: day) else { return .notDue }
        guard offNightTest == nil else { return .offNight }
        try await ProtocolRuleAnswerWrite.save(choice, key: key, ruleSource: rule.source, day: day, to: source, now: now)
        return .saved
    }
}
