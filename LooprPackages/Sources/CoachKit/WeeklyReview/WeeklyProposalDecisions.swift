import Foundation

/// Where the declined proposals live. Not now writes one small value here and nothing else. The default store is a
/// short list in UserDefaults on this iPhone. It never leaves the phone and it holds no health data, only which rule,
/// which outcome and how much evidence a proposal stood on.
public protocol WeeklyProposalDecisionStoring: Sendable {
    func decisions() -> [WeeklyProposalDecision]
    func record(_ decision: WeeklyProposalDecision)
}

public struct UserDefaultsWeeklyProposalDecisionStore: WeeklyProposalDecisionStoring, @unchecked Sendable {
    public static let key = "loopr.weeklyReview.declinedProposals"
    /// Older decisions fall off, so the list stays short.
    public static let capacity = 24

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func decisions() -> [WeeklyProposalDecision] {
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([WeeklyProposalDecision].self, from: data) else { return [] }
        return list
    }

    /// A newer decision for the same rule and outcome replaces the older one.
    public func record(_ decision: WeeklyProposalDecision) {
        var list = decisions().filter { !($0.ruleKey == decision.ruleKey && $0.outcome == decision.outcome) }
        list.append(decision)
        if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
