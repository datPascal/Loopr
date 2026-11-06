import DataKit
import Foundation
import JournalKit
import TodayKit

/// Where the controls under Today's dial go (LV-10 integration). "Why 49?" opens the method page of the number the note
/// is about, on Data. "All 29 nights" opens Sleep. The experiment strip opens Protocol on its Experiments segment.
enum TodayCompanionRouting {
    enum Route: Equatable {
        /// Another tab, through the shell's cross-tab path.
        case destination(TodayAgentDestination)
        /// A Today route, such as Sleep or Ask.
        case today(TodayRoute)
        case startWindDown
    }

    /// The morning note states sleep heart rate, so its "Why" opens that metric's method page.
    static let noteMetric = MetricKey.sleepingHeartRate

    static func route(for action: TodayNoteAction) -> Route {
        switch action {
        case .explainOutcome:
            if let method = MethodMetricText.methodID(for: noteMetric) { return .destination(.method(method)) }
            return .today(.sleep)
        case .showNights: return .today(.sleep)
        case .ask: return .today(.coach)
        case .startWindDown: return .startWindDown
        }
    }

    static let experimentStrip = TodayAgentDestination.protocolSegment(.experiments)

    /// The Data stack a destination opens, or nil when it is not on Data.
    static func dataPath(for destination: TodayAgentDestination) -> [AppHealthRoute]? {
        if case .method(let id) = destination { return [.method(id)] }
        return nil
    }
}
