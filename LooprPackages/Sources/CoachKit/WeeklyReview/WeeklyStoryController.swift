import Foundation
import Observation

/// What the person chose on the proposal page.
public enum WeeklyStoryResolution: Equatable, Sendable {
    case started(WeeklyReviewProposal)
    case declined(WeeklyProposalDecision)
}

/// Drives the story: which page is showing and what the two proposal buttons do. Building the story, moving between
/// pages and closing it write nothing. Only `startExperiment()` calls `start`, and only `notNow()` calls `decline`,
/// each once. Not now hands back the decision and starts nothing.
@MainActor
@Observable
public final class WeeklyStoryController {
    public let story: WeeklyStory
    public private(set) var pageIndex = 0
    public private(set) var resolution: WeeklyStoryResolution?

    @ObservationIgnored private let start: @MainActor (WeeklyReviewProposal) -> Void
    @ObservationIgnored private let decline: @MainActor (WeeklyProposalDecision) -> Void

    public init(story: WeeklyStory, startExperiment: @escaping @MainActor (WeeklyReviewProposal) -> Void,
                recordDecline: @escaping @MainActor (WeeklyProposalDecision) -> Void) {
        self.story = story
        start = startExperiment
        decline = recordDecline
    }

    public var pages: [WeeklyStoryPage] { story.pages }
    public var page: WeeklyStoryPage? { story.pages.indices.contains(pageIndex) ? story.pages[pageIndex] : nil }
    public var canGoBack: Bool { pageIndex > 0 }
    public var canGoForward: Bool { pageIndex < story.pages.count - 1 }
    public var isOnLastPage: Bool { pageIndex >= story.pages.count - 1 }

    /// The proposal buttons show on the proposal page until the person has chosen.
    public var offersProposal: Bool { page?.kind == .proposal && story.proposal != nil && resolution == nil }

    public func next() { if canGoForward { pageIndex += 1 } }
    public func previous() { if canGoBack { pageIndex -= 1 } }

    public func go(to index: Int) {
        guard story.pages.indices.contains(index) else { return }
        pageIndex = index
    }

    /// Start the experiment. This is the only call that does.
    public func startExperiment() {
        guard resolution == nil, let proposal = story.proposal else { return }
        resolution = .started(proposal)
        start(proposal)
    }

    /// Not now. It records that this week's proposal was declined and nothing else.
    public func notNow() {
        guard resolution == nil, let proposal = story.proposal else { return }
        let decision = proposal.declineDecision
        resolution = .declined(decision)
        decline(decision)
    }
}
