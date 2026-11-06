import DesignSystem
import SwiftUI

/// Opens one saved blood test report on Data (LV-08b integration). The shell sets it, so Lab mode in the Food camera
/// can offer "See it in blood tests" without knowing Data's stack. It closes nothing itself: the caller dismisses
/// the camera first.
struct LabReportLink: Sendable {
    let open: @MainActor @Sendable (UUID) -> Void
    /// Opens typed entry of a report on Data, for a page the camera could not read. Nil hides "Type it in instead".
    var openEntry: (@MainActor @Sendable () -> Void)?

    init(open: @escaping @MainActor @Sendable (UUID) -> Void, openEntry: (@MainActor @Sendable () -> Void)? = nil) {
        self.open = open
        self.openEntry = openEntry
    }

    /// The path Data's stack shows for a report: the blood tests list with the report on top, so back lands on the list.
    static func path(for reportID: UUID) -> [AppHealthRoute] { [.labs, .labReport(reportID)] }

    /// The path for typed entry: the blood tests list with the entry form on top.
    static let entryPath: [AppHealthRoute] = [.labs, .labEntry]
}

extension EnvironmentValues {
    @Entry var looprOpenLabReport: LabReportLink? = nil
    /// Opens the Food camera in Lab mode, for Blood tests' "Scan a report". Nil hides that action.
    @Entry var looprScanLabReport: LooprShellAction? = nil
}
