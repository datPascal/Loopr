import AnalyticsKit
import DesignSystem
import RoutineKit
import SwiftUI

/// What the blood tests list can do. The app wires each closure to the stores and to notifications.
public struct LabsListActions {
    public var openReport: @MainActor (UUID) -> Void
    public var addTyped: @MainActor () -> Void
    public var addClock: @MainActor () -> Void
    /// Opens the camera's Lab mode. Nil hides "Scan a report" until that route exists.
    public var scan: (@MainActor () -> Void)?
    /// Each returns an error message, or nil when it worked.
    public var deleteClock: @MainActor (UUID) async -> String?
    public var setReminder: @MainActor (LabTestDue) async -> String?
    public var removeReminder: @MainActor (LabTestDue) async -> Void
    public var markDone: @MainActor (LabTestDue) async -> String?
    /// Saves an edited value from a marker page. Nil keeps "Your markers" read-only.
    public var saveValue: (@MainActor (LabValue) async -> String?)?
    public var openRangesMethod: (@MainActor () -> Void)?
    public var openBloodAgeMethod: (@MainActor () -> Void)?

    public init(
        openReport: @escaping @MainActor (UUID) -> Void,
        addTyped: @escaping @MainActor () -> Void,
        addClock: @escaping @MainActor () -> Void,
        scan: (@MainActor () -> Void)? = nil,
        deleteClock: @escaping @MainActor (UUID) async -> String?,
        setReminder: @escaping @MainActor (LabTestDue) async -> String?,
        removeReminder: @escaping @MainActor (LabTestDue) async -> Void,
        markDone: @escaping @MainActor (LabTestDue) async -> String?,
        saveValue: (@MainActor (LabValue) async -> String?)? = nil,
        openRangesMethod: (@MainActor () -> Void)? = nil,
        openBloodAgeMethod: (@MainActor () -> Void)? = nil
    ) {
        self.saveValue = saveValue
        self.openRangesMethod = openRangesMethod
        self.openBloodAgeMethod = openBloodAgeMethod
        self.openReport = openReport
        self.addTyped = addTyped
        self.addClock = addClock
        self.scan = scan
        self.deleteClock = deleteClock
        self.setReminder = setReminder
        self.removeReminder = removeReminder
        self.markDone = markDone
    }
}

enum LabsListCopy {
    static let emptyTitle = "No blood tests yet"
    static let emptyBody = "Your lab reports and lab clock results live here, each with the lab's own ranges. Scan a page of your report with the camera, type it in from the paper or PDF, or add a clock result such as DunedinPACE."
    static let emptyAction = "Type in a report"
    static let scanAction = "Scan a report"
    static let clockAction = "Add a lab clock result"
    /// The toolbar menu's visible label, so the actions behind it are not a bare plus.
    static let addMenu = "Add"
    static let dueHeader = "Due"
    static let upcomingHeader = "Coming up"
    static let reportsHeader = "Reports"
    static let clocksHeader = "Lab clocks"

    static func status(_ test: LabTestDue, now: Date, calendar: Calendar) -> String {
        switch test.status {
        case .notDoneYet:
            return "\(test.cadenceText). No result yet."
        case .due:
            guard let next = test.nextDue else { return test.cadenceText }
            let today = calendar.startOfDay(for: now)
            return calendar.startOfDay(for: next) == today
                ? "\(test.cadenceText). Due today."
                : "\(test.cadenceText). Due since \(LabsDisplay.day(next, calendar: calendar))."
        case .upcoming:
            guard let next = test.nextDue else { return test.cadenceText }
            return "\(test.cadenceText). Next \(LabsDisplay.day(next, calendar: calendar))."
        }
    }

    static func lastDone(_ test: LabTestDue, calendar: Calendar) -> String? {
        guard let last = test.lastDone, let source = test.lastDoneSourceText else { return nil }
        return "Last \(LabsDisplay.day(last, calendar: calendar)). \(source)."
    }

    /// What changed between two loads of the list: one new report ("Saved the 12 Sep 2026 report with 9 values.") or
    /// one report gone ("Report deleted."). Nil for anything else, such as the first load or an edit.
    static func notice(before: [LabReportSummary], after: [LabReportSummary]) -> String? {
        let old = Set(before.map(\.id)), new = Set(after.map(\.id))
        let added = after.filter { !old.contains($0.id) }
        let removed = before.filter { !new.contains($0.id) }
        if added.count == 1, removed.isEmpty, let report = added.first {
            return "Saved the \(report.title) report with \(LabsDisplay.valueCount(report.valueCount))."
        }
        if removed.count == 1, added.isEmpty { return "Report deleted." }
        return nil
    }

    /// "Down 14 since 12 Mar" against the draw before in the same unit, "Same as 12 Mar" with no change, nil with one
    /// draw. A change is a direction, never a verdict.
    static func change(_ row: LabValueRow, calendar: Calendar) -> String? {
        guard row.history.count >= 2 else { return nil }
        let last = row.history[row.history.count - 1], before = row.history[row.history.count - 2]
        let difference = last.value - before.value
        let day = LabsDisplay.day(before.date, calendar: calendar)
        guard abs(difference) > 0.000_1 else { return "Same as \(day)" }
        let amount = LooprSignedNumber.text(abs(difference), fractionLength: 0...2, plus: false)
        return "\(difference > 0 ? "Up" : "Down") \(amount) since \(day)"
    }

    static func clockValue(_ result: LabClockResult, locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        let number = LabEntryNumber.localized(result.value.description, locale: locale)
        return [number, result.unit].compactMap { $0 }.joined(separator: " ")
    }
}

/// The blood tests list (`labs-screen`): the tests that are due, reports newest first, lab clock results, and an
/// Add menu. Nothing on it judges a value.
public struct LabsListScreen: View {
    private let snapshot: LabsListSnapshot?
    private let failure: String?
    private let actions: LabsListActions
    private let now: Date
    private let calendar: Calendar
    @State private var message: String?
    @State private var pendingClockDelete: LabClockResult?
    @State private var pendingReminder: LabTestDue?
    @State private var working: Set<String> = []
    /// "Saved the 12 Sep 2026 report with 9 values." or "Report deleted.", after the list comes back with one report
    /// more or fewer (ICP R2-LAB-6, R3-LAB-4).
    @State private var notice: String?
    /// The marker page opened from "Your markers" or the star map.
    @State private var openedMarker: LabValueRow?

    public init(snapshot: LabsListSnapshot?, failure: String? = nil, actions: LabsListActions, now: Date,
                calendar: Calendar = .current) {
        self.snapshot = snapshot
        self.failure = failure
        self.actions = actions
        self.now = now
        self.calendar = calendar
    }

    public var body: some View {
        LabsPage {
            if let failure { LooprInlineMessage(failure, tone: .warning) }
            if let message { LooprInlineMessage(message, tone: .warning).accessibilityIdentifier("labs-message") }
            if let notice { LooprInlineMessage(notice, tone: .positive).accessibilityIdentifier("labs-notice") }
            if let snapshot {
                content(snapshot)
            } else if failure == nil {
                LooprSkeleton(height: 120)
            }
        }
        .navigationTitle("Blood tests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let scan = actions.scan {
                        Button(LabsListCopy.scanAction, systemImage: "camera.viewfinder") { scan() }
                            .accessibilityIdentifier("labs-add-scan")
                    }
                    Button(LabsListCopy.emptyAction, systemImage: "square.and.pencil") { actions.addTyped() }
                        .accessibilityIdentifier("labs-add-typed")
                    Button(LabsListCopy.clockAction, systemImage: "clock") { actions.addClock() }
                        .accessibilityIdentifier("labs-add-clock")
                } label: {
                    // Words beside the plus: the menu holds scan, type in and lab clock (ICP R1-LAB-12).
                    Label(LabsListCopy.addMenu, systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Add a blood test")
                .accessibilityIdentifier("labs-add")
            }
        }
        .confirmationDialog("Delete this lab clock result?", isPresented: Binding(
            get: { pendingClockDelete != nil }, set: { if !$0 { pendingClockDelete = nil } }),
            titleVisibility: .visible, presenting: pendingClockDelete) { result in
            Button("Delete", role: .destructive) {
                Task { message = await actions.deleteClock(result.id) }
            }
            .accessibilityIdentifier("labs-clock-delete-confirm")
            Button("Cancel", role: .cancel) {}
        } message: { result in
            Text("\(result.kind.displayName) from \(result.labName) leaves Loopr.")
        }
        .confirmationDialog("Set this reminder?", isPresented: Binding(
            get: { pendingReminder != nil }, set: { if !$0 { pendingReminder = nil } }),
            titleVisibility: .visible, presenting: pendingReminder) { test in
            Button("Set reminder") { run(test) { await actions.setReminder(test) } }
                .accessibilityIdentifier("labs-due-remind-confirm-\(test.ruleKey.rawValue)")
            Button("Cancel", role: .cancel) {}
        } message: { test in
            Text(reminderMessage(test))
        }
        .onChange(of: snapshot?.reports) { old, new in
            // The first load is not a change: only a list that had reports before can gain or lose one.
            guard let old, let new, let text = LabsListCopy.notice(before: old, after: new) else { return }
            notice = text
            AccessibilityNotification.Announcement(text).post()
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { notice = nil }
        }
        .navigationDestination(item: $openedMarker) { row in
            LabMarkerScreen(row: snapshot?.markers.first { $0.id == row.id } ?? row,
                            labName: row.entries.last.map { LabsDisplay.labName($0.report) },
                            save: actions.saveValue ?? { _ in nil }, openRangesMethod: actions.openRangesMethod,
                            openBloodAgeMethod: actions.openBloodAgeMethod)
        }
        .accessibilityIdentifier("labs-screen")
    }

    @ViewBuilder
    private func content(_ snapshot: LabsListSnapshot) -> some View {
        if snapshot.hasResults { hero(snapshot) }
        // Blood is an area (Data ICP R3): the markers lead, by body system, each opening its whole history. The
        // reports that hold them follow.
        if let map = snapshot.starMap {
            DataStarMapSection(map: map, openStar: { star in
                guard let key = DataStarMapRule.labMarkerKey(star), let row = snapshot.marker(key) else { return }
                openedMarker = row
            })
        }
        if !snapshot.markers.isEmpty {
            LabsSection("Your markers", detail: "The newest value of each, and how it moved since the draw before",
                        identifier: "labs-markers-header") {
                ForEach(snapshot.markerGroups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        LooprText(group.title, style: .sectionLabel, color: .inkSecondary)
                            .padding(.horizontal, LooprSpacing.formCardPadding)
                            .padding(.top, LooprSpacing.sm)
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            markerRow(row)
                            if index < group.rows.count - 1 { LooprHairline() }
                        }
                    }
                }
            }
            .accessibilityIdentifier("labs-markers")
        }
        if !snapshot.tests.due.isEmpty {
            section(LabsListCopy.dueHeader) {
                ForEach(Array(snapshot.tests.due.enumerated()), id: \.element.id) { index, test in
                    testRow(test, reminded: snapshot.remindedTests.contains(test.ruleKey))
                    if index < snapshot.tests.due.count - 1 { LooprHairline() }
                }
            }
        }
        if snapshot.hasResults {
            if !snapshot.reports.isEmpty {
                section(LabsListCopy.reportsHeader) {
                    ForEach(Array(snapshot.reports.enumerated()), id: \.element.id) { index, report in
                        reportRow(report)
                        if index < snapshot.reports.count - 1 { LooprHairline() }
                    }
                }
            }
            if !snapshot.clockResults.isEmpty {
                section(LabsListCopy.clocksHeader) {
                    ForEach(Array(snapshot.clockResults.enumerated()), id: \.element.id) { index, result in
                        clockRow(result)
                        if index < snapshot.clockResults.count - 1 { LooprHairline() }
                    }
                }
            }
        } else {
            emptyState
        }
        if !snapshot.tests.upcoming.isEmpty {
            section(LabsListCopy.upcomingHeader) {
                ForEach(Array(snapshot.tests.upcoming.enumerated()), id: \.element.id) { index, test in
                    testRow(test, reminded: snapshot.remindedTests.contains(test.ruleKey))
                    if index < snapshot.tests.upcoming.count - 1 { LooprHairline() }
                }
            }
        }
        LooprText(LabsDisplay.notAMedicalDevice, style: .caption, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xxs)
            .accessibilityIdentifier("labs-disclaimer")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        LabsSection(title) { content() }
    }

    /// The lead: how many reports, every draw on one line, and the newest one named.
    private func hero(_ snapshot: LabsListSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LabsEyebrow(text: "Your blood tests")
            if snapshot.reports.isEmpty {
                LooprText(snapshot.summaryLine, style: .title)
                    .accessibilityIdentifier("labs-summary")
            } else {
                LooprHeroNumber(Double(snapshot.reports.count), unit: snapshot.reports.count == 1 ? "report" : "reports",
                                style: .heroNumeralXL, color: .brand)
                    .accessibilityHidden(true)
                // The line of dots needs a name: one dot is one draw (ICP R2-LAB-6).
                LooprText("Draws over time. Each dot is one draw.", style: .caption, color: .inkSecondary)
                    .accessibilityHidden(true)
                LabDrawStrip(draws: snapshot.reports.map { LabDrawStrip.Draw(id: $0.id, date: $0.collectedAt, values: $0.valueCount) })
                LooprText(snapshot.summaryLine, style: .caption, color: .inkSecondary)
                    .accessibilityIdentifier("labs-summary")
                if let newest = snapshot.reports.first {
                    LooprText("Newest draw \(newest.title), \(newest.labName.flatMap { $0.isEmpty ? nil : $0 } ?? "lab not named").",
                              style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("labs-newest")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("labs-hero")
    }

    private var emptyState: some View {
        LooprCard(style: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(LabsListCopy.emptyTitle, style: .cardTitle)
                LooprText(LabsListCopy.emptyBody, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let scan = actions.scan {
                    Button(LabsListCopy.scanAction, systemImage: "camera.viewfinder") { scan() }
                        .buttonStyle(LooprButtonStyle())
                        .accessibilityIdentifier("labs-empty-scan")
                }
                Button(LabsListCopy.emptyAction, systemImage: "square.and.pencil") { actions.addTyped() }
                    .buttonStyle(LooprButtonStyle(prominent: actions.scan == nil))
                    .accessibilityIdentifier("labs-empty-add")
                Button(LabsListCopy.clockAction, systemImage: "clock") { actions.addClock() }
                    .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                    .accessibilityIdentifier("labs-empty-clock")
            }
        }
        .accessibilityIdentifier("labs-empty")
    }

    private func reportRow(_ report: LabReportSummary) -> some View {
        Button { actions.openReport(report.id) } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(report.title, style: .rowTitle)
                    LooprText(report.subtitle, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let look = report.needsLookText {
                        StatusChip(look, symbol: "eye", tone: .warning)
                    }
                }
                Spacer(minLength: LooprSpacing.sm)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(report.title), \(report.subtitle)" + (report.needsLookText.map { ", \($0)" } ?? ""))
        .accessibilityHint("Opens the report")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("labs-report-\(report.id.uuidString)")
    }

    /// "ApoB · 78 mg/dL · 3 Oct · down 14 since 12 Mar", opening the marker's page with every draw.
    private func markerRow(_ row: LabValueRow) -> some View {
        let value = [row.value.printedText, row.value.unit].compactMap { $0 }.joined(separator: " ")
        let date = row.entries.last.map { LabsDisplay.day($0.report.collectedAt, calendar: calendar) }
        let detail = [date, LabsListCopy.change(row, calendar: calendar)].compactMap { $0 }.joined(separator: ". ")
        return Button { openedMarker = row } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(row.name, style: .rowTitle)
                    LooprText(detail, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: LooprSpacing.sm)
                LooprText(value, style: .metricValue)
                    .monospacedDigit()
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(value), \(detail)")
        .accessibilityHint("Opens every draw of this marker")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("labs-marker-\(row.value.subject.markerKey?.rawValue ?? row.name)")
    }

    private func clockRow(_ result: LabClockResult) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                LooprText(result.kind.displayName, style: .rowTitle)
                Spacer(minLength: LooprSpacing.sm)
                LooprText(LabsListCopy.clockValue(result), style: .metricValue)
            }
            HStack(spacing: LooprSpacing.sm) {
                ProvenanceChip(.lab(name: result.labName), qualifier: LabsDisplay.day(result.collectedAt, timeZoneIdentifier: result.timeZoneIdentifier),
                               identifier: "labs-clock-source-\(result.id.uuidString)")
                Spacer(minLength: LooprSpacing.sm)
                Button("Delete") { pendingClockDelete = result }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .critical, quiet: true))
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Delete \(result.kind.displayName) from \(result.labName)")
                    .accessibilityIdentifier("labs-clock-delete-\(result.id.uuidString)")
            }
            if let note = result.note { LooprText(note, style: .caption, color: .inkSecondary) }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("labs-clock-\(result.id.uuidString)")
    }

    private func testRow(_ test: LabTestDue, reminded: Bool) -> some View {
        let key = test.ruleKey.rawValue
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(test.title, style: .rowTitle)
                LooprText(LabsListCopy.status(test, now: now, calendar: calendar), style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = LabsListCopy.lastDone(test, calendar: calendar) {
                    LooprText(last, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("labs-due-\(key)")
            HStack(spacing: LooprSpacing.sm) {
                if reminded {
                    LooprText("Reminder set", style: .caption, color: .inkSecondary)
                    Button("Turn off") { run(test) { await actions.removeReminder(test); return nil } }
                        .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Turn off the reminder for \(test.title)")
                        .accessibilityIdentifier("labs-due-remind-off-\(key)")
                } else {
                    Button("Remind me") { pendingReminder = test }
                        .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Remind me about \(test.title)")
                        .accessibilityIdentifier("labs-due-remind-\(key)")
                }
                Spacer(minLength: LooprSpacing.sm)
                if test.kind.isManual {
                    Button("Mark done") { run(test) { await actions.markDone(test) } }
                        .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Mark \(test.title) done today")
                        .accessibilityIdentifier("labs-due-done-\(key)")
                }
            }
            .disabled(working.contains(key))
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }

    private func reminderMessage(_ test: LabTestDue) -> String {
        let when = LabTestReminder.fireDate(for: test, now: now, calendar: calendar)
            .map { "On \(LabsDisplay.day($0, calendar: calendar)) at \(LooprClockFormat.text(minuteOfDay: LabTestReminder.minuteOfDay))" } ?? "Once"
        return "\(when) your phone will show \"\(LabTestReminder.title(for: test))\" with \"\(LabTestReminder.detail)\""
    }

    private func run(_ test: LabTestDue, _ work: @escaping @MainActor () async -> String?) {
        working.insert(test.ruleKey.rawValue)
        message = nil
        Task {
            message = await work()
            working.remove(test.ruleKey.rawValue)
        }
    }
}
