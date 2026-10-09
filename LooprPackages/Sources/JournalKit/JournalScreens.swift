import Combine
import SwiftUI
import DesignSystem
import DomainKit
import UniformTypeIdentifiers

public enum JournalRoute: Hashable, Sendable {
    case history
    case compose
    /// One entry, opened from the row that was tapped.
    case entry(UUID)
    case habits
    case habitSetup
    case checkIn(DayIdentity)
    case habitHistory
    case habitInsights
    case habitDetail(HabitID)
    case privacy

    public static let fixtures: [JournalRoute] = [
        .history, .compose, .entry(JournalFixtures.privateEntry.id), .habits, .habitSetup,
        .checkIn(HabitFixtures.day), .habitHistory, .habitInsights,
        .habitDetail(HabitFixtures.definition.id), .privacy
    ]
}

public enum JournalScreenStateFixtures {
    public static let allStates = MetricState.allCases
    public static let accessibilityIdentifiers = [
        "journal-screen", "journal-compose", "journal-privacy",
        "habit-setup-screen", "habit-management-screen", "habit-check-in-screen",
        "habit-history-screen", "habit-insights-screen", "habit-detail-screen"
    ]
    public static let statesByScreen = Dictionary(uniqueKeysWithValues: accessibilityIdentifiers.map { ($0, allStates) })
    public static func accessibilitySummary(for state: MetricState) -> String { "\(state.title). \(state.detail)" }
}

@MainActor
public final class JournalViewModel: ObservableObject {
    @Published public private(set) var snapshot: JournalScreenSnapshot
    @Published public private(set) var query = JournalSearchQuery()
    private let repository: (any JournalStore)?

    public init(repository: (any JournalStore)? = nil) {
        self.repository = repository
        snapshot = JournalScreenSnapshot(state: .loading)
    }

    public func load(query: JournalSearchQuery = .init()) async {
        self.query = query
        guard let repository else {
            snapshot = JournalScreenSnapshot(state: .empty)
            return
        }
        let entries = await repository.search(query)
        snapshot = JournalScreenSnapshot(state: entries.isEmpty ? .empty : .populated, entries: entries)
    }
}

public enum JournalFixtures {
    public static let privateEntry = JournalEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
        day: "2026-08-18",
        behaviors: ["walk"],
        tags: ["private"],
        note: "A private note stays local.",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

public struct JournalScreen: View {
    @ObservedObject private var viewModel: JournalViewModel
    @ObservedObject private var habitViewModel: HabitViewModel
    private let route: (JournalRoute) -> Void

    public init(viewModel: JournalViewModel, habitViewModel: HabitViewModel, route: @escaping (JournalRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.habitViewModel = habitViewModel
        self.route = route
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                HabitHomeSection(viewModel: habitViewModel, route: route)

                LooprSectionGroup(title: "Entries") {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        composeButton

                        switch viewModel.snapshot.state {
                        case .loading:
                            JournalStateCard(
                                state: .loading,
                                detail: "Loading journal entries."
                            )
                        case .empty, .noRecords:
                            JournalStateCard(
                                state: .noRecords,
                                detail: "No journal entries yet. Add an entry to start."
                            )
                        case .populated:
                            entries
                        case .destructiveFailure:
                            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                                JournalStateCard(
                                    state: .destructiveFailure,
                                    detail: "Journal data needs review before changes.",
                                    tone: .critical
                                )
                                retryButton
                            }
                        default:
                            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                                JournalStateCard(
                                    state: metricState(for: viewModel.snapshot.state),
                                    detail: "Journal entries are temporarily unavailable.",
                                    tone: .warning
                                )
                                retryButton
                            }
                        }
                    }
                }

                reviewMenu
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("journal-screen")
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
    }

    @ViewBuilder
    private var composeButton: some View {
        Button { route(.compose) } label: {
            LooprSurface(emphasis: .hero(.brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText(headerMeta, style: .headerMeta, color: .inkSecondary)
                    LooprRow(
                        title: "Add an entry",
                        subtitle: "Keep a note on this device",
                        symbol: "square.and.pencil"
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("journal-compose")
    }

    @ViewBuilder
    private var entries: some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(viewModel.snapshot.entries.enumerated()), id: \.element.id) { index, entry in
                    // Opens the entry that was tapped. Routing every row to the
                    // full list loses the entry the user picked.
                    Button { route(.entry(entry.id)) } label: {
                        JournalEntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("journal-entry-\(entry.id.uuidString)")
                    .accessibilityLabel(journalEntryAccessibilityLabel(for: entry))

                    if index < viewModel.snapshot.entries.count - 1 {
                        LooprHairline()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reviewMenu: some View {
        LooprMenuGroup(
            title: "Review",
            rows: [
                // History had no entry point at all after the review menu was
                // rebuilt, which left the screen unreachable in the app.
                LooprMenuItem(
                    title: "History",
                    value: entriesCountValue,
                    accessibilityIdentifier: "journal-history",
                    action: { route(.history) }
                ),
                LooprMenuItem(
                    title: "Privacy",
                    value: "On device",
                    accessibilityIdentifier: "journal-privacy",
                    action: { route(.privacy) }
                )
            ]
        )
    }

    private var retryButton: some View {
        Button("Try again") {
            Task { await viewModel.load(query: viewModel.query) }
        }
        .buttonStyle(LooprButtonStyle(prominent: false))
        .accessibilityIdentifier("journal-retry")
    }

    private var entriesCountValue: String {
        let count = viewModel.snapshot.entries.count
        return count == 1 ? "1 entry" : "\(count) entries"
    }

    private var headerMeta: String {
        switch viewModel.snapshot.state {
        case .populated:
            let count = viewModel.snapshot.entries.count
            return "\(count) \(count == 1 ? "ENTRY" : "ENTRIES") · ON DEVICE"
        default:
            return "PRIVATE · ON DEVICE"
        }
    }

}

public struct JournalComposeScreen: View {
    public let onSave: (JournalEntry) -> Void
    private let editingEntry: JournalEntry?
    @State private var day: String
    @State private var tags = ""
    @State private var note = ""

    public init(
        entry: JournalEntry? = nil,
        day: String = "2026-08-18",
        onSave: @escaping (JournalEntry) -> Void = { _ in }
    ) {
        self.onSave = onSave
        self.editingEntry = entry
        _day = State(initialValue: entry?.day ?? day)
        _tags = State(initialValue: entry.map { $0.tags.union($0.behaviors).sorted().joined(separator: ", ") } ?? "")
        _note = State(initialValue: entry?.note ?? "")
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Entry") {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        LooprTextFieldRow(
                            title: "Day",
                            placeholder: "YYYY-MM-DD",
                            text: $day
                        )
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("journal-day-input")

                        LooprHairline()

                        LooprTextFieldRow(
                            title: "Tags",
                            placeholder: "tag1, tag2",
                            text: $tags
                        )
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("journal-tags-input")

                        LooprHairline()

                        LooprTextEditorRow(
                            title: "Note",
                            placeholder: "Optional note",
                            text: $note,
                            minimumHeight: LooprSpacing.formButtonHeight * 2
                        )
                        .accessibilityIdentifier("journal-note-input")
                    }
                }
            }

            LooprSectionGroup(title: "Privacy") {
                LooprFormCard {
                    LooprText(
                        "Journal content stays on this device. Include it in an export only when you select it.",
                        style: .prose,
                        color: .inkSecondary
                    )
                }
            }

            LooprSectionGroup(title: "Actions") {
                Button(editingEntry == nil ? "Save entry" : "Save changes") {
                    let values = Set(
                        tags
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    )
                    onSave(JournalEntry(
                        id: editingEntry?.id ?? UUID(),
                        day: day,
                        behaviors: values,
                        tags: values,
                        note: note.isEmpty ? nil : note,
                        createdAt: editingEntry?.createdAt ?? Date(),
                        updatedAt: editingEntry?.updatedAt
                    ))
                }
                .buttonStyle(LooprPrimaryButtonStyle())
                .accessibilityIdentifier("journal-save")
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(editingEntry == nil ? "New journal entry" : "Edit journal entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier(editingEntry == nil ? "journal-compose-screen" : "journal-edit-screen")
    }
}

public struct JournalHistoryScreen: View {
    public let entries: [JournalEntry]
    private let onEdit: (JournalEntry) -> Void
    private let onDelete: (JournalEntry) -> Void
    @State private var entryPendingDeletion: JournalEntry?

    public init(
        entries: [JournalEntry] = [],
        onEdit: @escaping (JournalEntry) -> Void = { _ in },
        onDelete: @escaping (JournalEntry) -> Void = { _ in }
    ) {
        self.entries = entries
        self.onEdit = onEdit
        self.onDelete = onDelete
        _entryPendingDeletion = State(initialValue: nil)
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Entries") {
                if entries.isEmpty {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            StateMessage(.noRecords, compact: true)
                            LooprText(
                                "No journal entries yet. Add an entry to start.",
                                style: .prose,
                                color: .inkSecondary
                            )
                        }
                        .accessibilityIdentifier("journal-history-empty")
                    }
                } else {
                    LooprFormCard(padding: LooprSpacing.none) {
                        VStack(spacing: LooprSpacing.none) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                historyRow(entry)

                                if index < entries.count - 1 {
                                    LooprHairline()
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Journal history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("journal-history-screen")
        .confirmationDialog(
            "Delete this journal entry?",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { entryPendingDeletion = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete entry", role: .destructive) {
                if let entryPendingDeletion {
                    onDelete(entryPendingDeletion)
                }
                entryPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: {
            Text("This removes the entry from your local journal.")
        }
    }

    private func historyRow(_ entry: JournalEntry) -> some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            Button { onEdit(entry) } label: {
                JournalEntrySummary(entry: entry, insideButton: true)
                    .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(journalEntryAccessibilityLabel(for: entry))
            .accessibilityHint("Double tap to edit this journal entry.")

            Menu {
                Button("Edit") { onEdit(entry) }
                    .accessibilityIdentifier("journal-edit-\(entry.id.uuidString)")
                Button("Delete", role: .destructive) {
                    entryPendingDeletion = entry
                }
                .accessibilityIdentifier("journal-delete-\(entry.id.uuidString)")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .looprTypography(.metricUnit)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(
                        width: LooprSpacing.interactiveRowHeight,
                        height: LooprSpacing.interactiveRowHeight
                    )
                    .accessibilityLabel("Actions for journal entry \(entry.day)")
            }
            .accessibilityIdentifier("journal-entry-actions-\(entry.id.uuidString)")
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(journalEntryAccessibilityLabel(for: entry))
    }
}

/// One journal entry, opened from the row that was tapped.
public struct JournalEntryScreen: View {
    public let entry: JournalEntry?
    private let onEdit: (JournalEntry) -> Void
    private let onDelete: (JournalEntry) -> Void
    @State private var confirmingDeletion = false

    public init(
        entry: JournalEntry?,
        onEdit: @escaping (JournalEntry) -> Void = { _ in },
        onDelete: @escaping (JournalEntry) -> Void = { _ in }
    ) {
        self.entry = entry
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    public var body: some View {
        LooprDetailScaffold {
            if let entry {
                LooprSectionGroup(title: "Entry") {
                    LooprFormCard {
                        JournalEntrySummary(entry: entry)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(journalEntryAccessibilityLabel(for: entry))
                    }
                    LooprFormCard(padding: LooprSpacing.none) {
                        VStack(spacing: LooprSpacing.none) {
                            Button { onEdit(entry) } label: {
                                LooprRow(title: "Edit entry", symbol: "square.and.pencil")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("journal-entry-edit")
                            LooprHairline()
                            Button(role: .destructive) { confirmingDeletion = true } label: {
                                LooprRow(title: "Delete entry", symbol: "trash")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("journal-entry-delete")
                        }
                    }
                }
            } else {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        StateMessage(.noRecords, compact: true)
                        LooprText(
                            "This entry is no longer in your journal.",
                            style: .prose,
                            color: .inkSecondary
                        )
                    }
                    .accessibilityIdentifier("journal-entry-missing")
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(entry?.day ?? "Journal entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("journal-entry-screen")
        .confirmationDialog(
            "Delete this journal entry?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete entry", role: .destructive) {
                if let entry { onDelete(entry) }
                confirmingDeletion = false
            }
            Button("Cancel", role: .cancel) { confirmingDeletion = false }
        } message: {
            Text("This removes the entry from your local journal.")
        }
    }
}

public struct JournalPrivacyScreen: View {
    @State private var includeContent = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var showingImporter = false
    @State private var pendingRestoreURL: URL?
    @State private var restorePreview: JournalRestorePreview?
    public let onExport: (Bool) -> Void
    private let onExportFile: ((Bool) async throws -> URL)?
    private let onRestorePreview: ((URL) async throws -> JournalRestorePreview)?
    private let onRestore: ((URL) async throws -> Void)?

    public init(
        onExport: @escaping (Bool) -> Void = { _ in },
        onExportFile: ((Bool) async throws -> URL)? = nil,
        onRestorePreview: ((URL) async throws -> JournalRestorePreview)? = nil,
        onRestore: ((URL) async throws -> Void)? = nil
    ) {
        self.onExport = onExport
        self.onExportFile = onExportFile
        self.onRestorePreview = onRestorePreview
        self.onRestore = onRestore
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Privacy") {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        LooprToggleRow(
                            title: "Include journal content",
                            subtitle: "Include journal notes in this export.",
                            isOn: $includeContent
                        )

                        LooprHairline()

                        LooprText(
                            "Journal notes are left out of the exported file unless you turn this on. Nothing else in Loopr reads your notes.",
                            style: .prose,
                            color: .inkSecondary
                        )
                        .padding(.horizontal, LooprSpacing.formCardPadding)
                        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                    }
                }
            }

            LooprSectionGroup(title: "Export") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Button("Create private export") {
                        guard let onExportFile else {
                            onExport(includeContent)
                            return
                        }
                        errorMessage = nil
                        Task { @MainActor in
                            do { exportURL = try await onExportFile(includeContent) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("journal-export")

                    if let exportURL {
                        LooprFormCard {
                            if #available(iOS 16.0, macOS 13.0, *) {
                                ShareLink(item: exportURL) {
                                    Label("Share export", systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(LooprButtonStyle(prominent: false))
                                .accessibilityIdentifier("journal-export-share")
                            } else {
                                LooprInlineMessage("Export saved locally.", tone: .positive)
                            }
                        }
                    }

                    if let errorMessage {
                        LooprFormCard {
                            LooprInlineMessage(errorMessage, tone: .critical)
                                .accessibilityIdentifier("journal-export-error")
                        }
                    }
                }
            }

            if onRestorePreview != nil, onRestore != nil {
                LooprSectionGroup(title: "Restore") {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        Button("Choose journal archive") { showingImporter = true }
                            .buttonStyle(LooprButtonStyle(prominent: false))
                            .accessibilityIdentifier("journal-restore-choose")
                        if let restorePreview {
                            LooprFormCard {
                                LooprText("\(restorePreview.entryCount) entries, \(restorePreview.habitCount) habits, and \(restorePreview.dayCount) habit days", style: .prose)
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Journal privacy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("journal-privacy-screen")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                errorMessage = nil
                Task { @MainActor in
                    do {
                        restorePreview = try await onRestorePreview?(url)
                        pendingRestoreURL = url
                    } catch { errorMessage = error.localizedDescription }
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Restore this journal archive?",
            isPresented: Binding(get: { pendingRestoreURL != nil }, set: { if !$0 { pendingRestoreURL = nil; restorePreview = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore journal", role: .destructive) {
                guard let url = pendingRestoreURL else { return }
                Task { @MainActor in
                    do {
                        try await onRestore?(url)
                        pendingRestoreURL = nil
                        restorePreview = nil
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { pendingRestoreURL = nil; restorePreview = nil }
        } message: {
            if let restorePreview {
                Text("This replaces local journal source records with \(restorePreview.entryCount) entries and \(restorePreview.habitCount) habits. Loopr will rebuild insights from local health data.")
            }
        }
    }
}

private struct JournalEntryRow: View {
    let entry: JournalEntry

    var body: some View {
        JournalEntrySummary(entry: entry, insideButton: true)
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct JournalEntrySummary: View {
    let entry: JournalEntry
    let insideButton: Bool

    init(entry: JournalEntry, insideButton: Bool = false) {
        self.entry = entry
        self.insideButton = insideButton
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(entry.day, style: .metricValue)

            JournalTagChips(tags: journalTags(for: entry), insideButton: insideButton)

            if let note = entry.note, !note.isEmpty {
                LooprText(note, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct JournalTagChips: View {
    let tags: [String]
    let insideButton: Bool

    init(tags: [String], insideButton: Bool = false) {
        self.tags = tags
        self.insideButton = insideButton
    }

    var body: some View {
        if tags.isEmpty {
            EmptyView()
        } else if insideButton {
            HStack(spacing: LooprSpacing.xs) {
                ForEach(tags, id: \.self) { tag in
                    StatusChip(tag, symbol: "tag", accent: .brand)
                }
            }
            .lineLimit(1)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LooprSpacing.xs) {
                    ForEach(tags, id: \.self) { tag in
                        StatusChip(tag, symbol: "tag", accent: .brand)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct JournalStateCard: View {
    let state: MetricState
    let detail: String
    let tone: ChipTone?

    init(state: MetricState, detail: String, tone: ChipTone? = nil) {
        self.state = state
        self.detail = detail
        self.tone = tone
    }

    var body: some View {
        LooprSurface(emphasis: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                StateMessage(state, compact: true)
                if let tone {
                    LooprInlineMessage(detail, tone: tone)
                } else {
                    LooprText(detail, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private func journalTags(for entry: JournalEntry) -> [String] {
    entry.tags
        .union(entry.behaviors)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .sorted()
}

private func journalEntryAccessibilityLabel(for entry: JournalEntry) -> String {
    var parts = ["Journal entry for \(entry.day)"]
    let tags = journalTags(for: entry)
    if !tags.isEmpty {
        parts.append("Tags \(tags.joined(separator: ", "))")
    }
    if let note = entry.note, !note.isEmpty {
        parts.append("Note \(note)")
    }
    return parts.joined(separator: ", ")
}

private func metricState(for state: JournalScreenSnapshot.State) -> MetricState {
    switch state {
    case .loading: .loading
    case .empty, .noRecords: .noRecords
    case .absent: .absent
    case .measuredZero: .measuredZero
    case .partial: .partial
    case .lowConfidence: .lowConfidence
    case .settling: .settling
    case .stale: .stale
    case .disconnected: .disconnected
    case .bluetoothOff: .bluetoothOff
    case .permissionDenied: .permissionDenied
    case .unsupportedHardware: .unsupportedHardware
    case .recoverableError, .unavailable, .error, .migrationFailure: .recoverableError
    case .destructiveFailure: .destructiveFailure
    case .populated: .measuredZero
    }
}
