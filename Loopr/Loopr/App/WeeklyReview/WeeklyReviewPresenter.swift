import CoachKit
import DesignSystem
import DomainKit
import Foundation
import JournalKit
import Observation
import RoutineKit
import SwiftUI
import Synchronization

/// Everything one opening of the weekly review reads and writes. The shell builds it from the open stores.
struct WeeklyReviewEnvironment {
    var now: () -> Date
    var calendar: Calendar
    var locale: Locale = .current
    var sources: WeeklyReviewSources
    var seen: WeeklyReviewSeenStore
    /// Not now writes one decision here (`UserDefaultsWeeklyProposalDecisionStore` in production).
    var decisions: any WeeklyProposalDecisionStoring
    /// Start the experiment. Throws when the store refuses it, such as when another experiment is running.
    var startExperiment: (WeeklyReviewProposal, Date) throws -> Void

    /// The production stores, or the DEBUG Protocol fixture's on a fixture launch. Nil when no protocol store is open.
    static func live(repositories: ProductRepositoryContainer, history provider: any MetricHistoryProviding) -> WeeklyReviewEnvironment? {
        let environment = repositories.environment
        let zone = environment.timeZoneProvider.timeZone
        var calendar = Calendar.current
        calendar.timeZone = zone
        let dateProvider = environment.dateProvider
        let history: @Sendable (MetricKey, Int, Date) async -> [MetricHistoryPoint] = { key, days, end in
            (try? await provider.series(for: key, days: days, endingOn: end)) ?? []
        }
        let routine: RoutineStore
        let experiments: ExperimentStore?
        let persisting: Bool
        if let persistent = repositories.persistent {
            routine = RoutineStore(database: persistent.database)
            experiments = ExperimentStore(database: persistent.database)
            persisting = true
        } else {
            #if DEBUG
            guard repositories.isFixtureComposition,
                  let stores = ProtocolTabFixture.stores(environment: repositories.environment) else { return nil }
            routine = stores.routine
            experiments = stores.experiments
            persisting = false
            #else
            return nil
            #endif
        }
        let decisions: any WeeklyProposalDecisionStoring = persisting
            ? UserDefaultsWeeklyProposalDecisionStore() : InMemoryWeeklyProposalDecisionStore()
        return WeeklyReviewEnvironment(
            now: { dateProvider.now() }, calendar: calendar,
            sources: WeeklyReviewSources(routine: routine, experiments: experiments, history: history,
                                         declined: { decisions.decisions() }),
            seen: .standard(persisting: persisting), decisions: decisions,
            startExperiment: { proposal, now in
                guard let experiments else { throw ProtocolTabError.experimentsUnavailable }
                try WeeklyReviewExperimentStart.start(proposal, routine: routine, experiments: experiments, now: now, timeZone: zone)
            })
    }
}

/// Declined proposals for a fixture launch, kept in memory for the launch.
nonisolated final class InMemoryWeeklyProposalDecisionStore: WeeklyProposalDecisionStoring {
    private let list = Mutex<[WeeklyProposalDecision]>([])
    func decisions() -> [WeeklyProposalDecision] { list.withLock { $0 } }
    func record(_ decision: WeeklyProposalDecision) { list.withLock { $0.append(decision) } }
}

/// Opens the weekly review as a sheet from Today's card, the Protocol row, the reminder or the DEBUG launch argument.
/// Opening marks the review's ISO week seen. Paging and closing write nothing; Start the experiment starts it through
/// RoutineKit's experiment store and Not now records the decline in the decision store, each once.
@MainActor
@Observable
final class WeeklyReviewPresenter {
    struct Sheet: Identifiable {
        enum Content {
            case story(WeeklyStoryController)
            /// Why there is no review, as a sentence.
            case absent(String)
        }

        let id = UUID()
        let week: WeeklyReviewWeek?
        let content: Content
    }

    var sheet: Sheet?
    /// A sentence when Start the experiment did not work.
    var message: String?
    private var isOpening = false

    /// Reads the newest week whose review has opened and presents it.
    func open(_ environment: WeeklyReviewEnvironment) async {
        guard sheet == nil, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let now = environment.now()
        guard let week = WeeklyReviewSchedule.reviewWeek(at: now, calendar: environment.calendar) else { return }
        environment.seen.markSeen(week.isoKey)
        do {
            let input = try await WeeklyReviewInputs.read(week: week, now: now, calendar: environment.calendar,
                                                          sources: environment.sources)
            let writer = WeeklyStoryWriter(context: NoteContext(locale: environment.locale, calendar: environment.calendar))
            present(writer.write(input), week: week, environment: environment)
        } catch {
            sheet = Sheet(week: week, content: .absent(WeeklyReviewCopy.unreadable))
        }
    }

    /// Shows a written story, or why there is none.
    func present(_ result: WeeklyStoryResult, week: WeeklyReviewWeek?, environment: WeeklyReviewEnvironment) {
        switch result {
        case .story(let story):
            let controller = WeeklyStoryController(story: story, startExperiment: { [weak self] proposal in
                do {
                    try environment.startExperiment(proposal, environment.now())
                    self?.message = nil
                } catch {
                    self?.message = WeeklyReviewCopy.startFailed(error)
                }
            }, recordDecline: { decision in
                environment.decisions.record(decision)
            })
            sheet = Sheet(week: week, content: .story(controller))
        case .absent(let absence):
            sheet = Sheet(week: week, content: .absent(absence.reason))
        }
    }

    func close() { sheet = nil }
}

/// The weekly review's own words outside the story, which CoachKit writes.
enum WeeklyReviewCopy {
    static let todayTitle = "Your week"
    static let todayDetail = "Five pages on the week you just had. Nothing changes until you tap."
    static let protocolTitle = "This week's review"
    static let unreadable = "Loopr could not read your protocol on this iPhone, so there is no review to show. Try again in a moment."
    static let absentTitle = "No review this week"

    /// "The week of 19 Oct, written on this iPhone".
    static func protocolDetail(monday: String) -> String { "The week of \(monday), written on this iPhone" }

    static func startFailed(_ error: any Error) -> String {
        "Loopr could not start the experiment. \(error.localizedDescription)"
    }
}

/// The sheet: the five-page story, or the reason there is none. The story keeps its page identifiers.
struct WeeklyReviewSheetView: View {
    let sheet: WeeklyReviewPresenter.Sheet
    let close: () -> Void

    var body: some View {
        ZStack {
            switch sheet.content {
            case .story(let controller):
                WeeklyReviewStoryView(controller: controller, onClose: close)
            case .absent(let reason):
                WeeklyReviewAbsentView(reason: reason, close: close)
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weekly-review-sheet")
        .presentationDragIndicator(.visible)
    }
}

/// No review: the orb, the reason in a sentence and the line that says nothing was sent.
struct WeeklyReviewAbsentView: View {
    let reason: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            HStack(spacing: LooprSpacing.xs) {
                LooprCoachOrb(size: .xs)
                LooprText(WeeklyReviewCopy.todayTitle, style: .caption, color: .inkSecondary)
                Spacer(minLength: 0)
                LooprGlassButton(symbol: "xmark", accessibilityLabel: "Close", size: .small,
                                 identifier: WeeklyReviewStoryView.closeIdentifier, action: close)
            }
            LooprText(WeeklyReviewCopy.absentTitle, style: .titleLarge)
                .accessibilityAddTraits(.isHeader)
            LooprText(reason, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("weekly-review-absent")
            Spacer(minLength: 0)
            LooprText(WeeklyStory.footer, style: .caption, color: .inkMuted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.vertical, LooprSpacing.sm)
    }
}

extension EnvironmentValues {
    /// Opens the weekly review sheet. The shell sets it; the Protocol tab's row and Today's card call it.
    @Entry var looprOpenWeeklyReview: LooprShellAction? = nil
}
