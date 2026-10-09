import Combine
import SwiftUI
import DesignSystem

public enum DataRoute: String, Hashable, Sendable, CaseIterable {
    case history
    case importPreview
    case export
    case reanalysis
    case diagnostics
    case deletion
}

public enum DataScreenStateFixtures {
    public static let allStates = MetricState.allCases
    public static let accessibilityIdentifiers = ["data-screen", "data-loading", "data-importPreview", "data-export", "data-deletion"]
    public static let statesByScreen = Dictionary(uniqueKeysWithValues: accessibilityIdentifiers.map { ($0, allStates) })
    public static func accessibilitySummary(for state: MetricState) -> String { "\(state.title). \(state.detail)" }
}

@MainActor
public final class DataViewModel: ObservableObject {
    @Published public private(set) var snapshot: DataScreenSnapshot
    @Published public private(set) var inventory = DataStoreInventory()
    @Published public private(set) var records: [DataRecord] = []
    @Published public private(set) var lastError: String?
    private let repository: (any DataStore)?

    public init(repository: (any DataStore)? = nil) {
        self.repository = repository
        snapshot = DataScreenSnapshot(state: .loading)
    }

    public func load() async {
        guard let repository else {
            snapshot = DataScreenSnapshot(state: .noRecords)
            lastError = "Data storage is unavailable."
            return
        }
        do {
            if let checked = repository as? any CheckedDataStore {
                records = try await checked.recordsChecked()
                inventory = try await checked.inventorySnapshotChecked()
            } else {
                records = await repository.records()
                inventory = await repository.inventorySnapshot()
            }
            lastError = nil
            snapshot = DataScreenSnapshot(state: records.isEmpty ? .noRecords : .ready)
        } catch {
            records = []
            lastError = error.localizedDescription
            snapshot = DataScreenSnapshot(state: .recoverableError)
        }
    }

    public func deleteAll() async {
        do {
            try await deleteAllOrThrow()
        } catch {
            lastError = error.localizedDescription
            snapshot = DataScreenSnapshot(state: .destructiveFailure)
        }
    }

    public func deleteAllOrThrow() async throws {
        guard let repository else { throw DataError.repositoryUnavailable }
        try await repository.completeDeletionChecked()
        await load()
    }
}

public enum DataFixtures {
    public static let importedRecord = DataRecord(id: "fixture-import", day: "2026-08-18", table: "metrics", payload: ["value": "42"], provenance: .whoopCSV)
    public static let conflict = ImportConflict(recordID: importedRecord.id, existing: importedRecord, incoming: DataRecord(id: importedRecord.id, day: importedRecord.day, table: importedRecord.table, payload: ["value": "43"], provenance: .edgeMerged))
}

public struct DataScreen: View {
    @ObservedObject private var viewModel: DataViewModel
    private let route: (DataRoute) -> Void

    public init(viewModel: DataViewModel, route: @escaping (DataRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.none) {
            if viewModel.snapshot.state == .loading {
                ScrollView {
                    loadingContent
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.md)
                    .padding(.bottom, LooprSpacing.tabBarClearance)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("data-loading")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                        LooprFormCard {
                            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                                LooprText("LOCAL STORAGE", style: .headerMeta, color: .inkSecondary)

                                if let screenState {
                                    StateMessage(screenState)

                                    if screenState == .recoverableError {
                                        Button("Try again") {
                                            Task { await viewModel.load() }
                                        }
                                        .buttonStyle(LooprButtonStyle(prominent: false))
                                        .accessibilityIdentifier("data-retry")
                                    }
                                }
                            }
                        }

                        LooprMenuGroup(
                            title: "Data control",
                            rows: [
                                destination("History", .history),
                                destination("Import preview", .importPreview),
                                destination("Export", .export),
                                destination("Re-analysis", .reanalysis)
                            ]
                        )

                        LooprMenuGroup(
                            title: "Diagnostics",
                            rows: [
                                destination("Advanced diagnostics", .diagnostics),
                                destination("Delete Loopr data", .deletion)
                            ]
                        )

                        LooprSectionGroup(title: "Health data") {
                            LooprFormCard {
                                LooprInlineMessage(
                                    "HealthKit samples remain until you explicitly remove them.",
                                    tone: .neutral
                                )
                                .accessibilityIdentifier("data-healthkit-disclosure")
                            }
                        }
                    }
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.md)
                    .padding(.bottom, LooprSpacing.tabBarClearance)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Data")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("data-screen")
    }

    private var loadingContent: some View {
        LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprSkeleton(height: LooprSpacing.sm)
                LooprSkeleton(height: LooprSpacing.interactiveRowHeight)
                LooprSkeleton(height: LooprSpacing.interactiveRowHeight)
                LooprSkeleton(height: LooprSpacing.interactiveRowHeight)
            }
        }
    }

    private func destination(_ title: String, _ destination: DataRoute) -> LooprMenuItem {
        LooprMenuItem(
            title: title,
            accessibilityIdentifier: "data-\(destination.rawValue)",
            action: { route(destination) }
        )
    }

    private var screenState: MetricState? {
        switch viewModel.snapshot.state {
        case .noRecords:
            .noRecords
        case .recoverableError, .migrationFailure, .conflict, .rollback:
            .recoverableError
        case .destructiveFailure:
            .destructiveFailure
        default:
            nil
        }
    }
}

public struct DataDestinationScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public let route: DataRoute
    public let records: [DataRecord]
    public let inventory: DataStoreInventory
    public let onDeleteAll: (() -> Void)?
    public let onDeleteHealthKitSamples: (() -> Void)?
    public let onExport: (() -> Void)?
    public let onExportDiagnostics: (() -> Void)?
    public let onRunReanalysis: (() -> Void)?
    public let onImport: (() -> Void)?
    public let onExportDay: ((String) -> Void)?
    public let onDeleteDay: ((String) -> Void)?
    public let onRunDayReanalysis: ((String) -> Void)?
    public let legacyMigrationState: LegacyMigrationState
    public let onRunLegacyMigration: (() -> Void)?
    @State private var isDeleteConfirmationPresented = false
    @State private var isHealthKitConfirmationPresented = false
    @State private var dayPendingDeletion: String?

    public init(
        route: DataRoute,
        records: [DataRecord] = [],
        inventory: DataStoreInventory = .init(),
        onDeleteAll: (() -> Void)? = nil,
        onDeleteHealthKitSamples: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil,
        onExportDiagnostics: (() -> Void)? = nil,
        onRunReanalysis: (() -> Void)? = nil,
        onImport: (() -> Void)? = nil,
        onExportDay: ((String) -> Void)? = nil,
        onDeleteDay: ((String) -> Void)? = nil,
        onRunDayReanalysis: ((String) -> Void)? = nil,
        legacyMigrationState: LegacyMigrationState = .notAvailable,
        onRunLegacyMigration: (() -> Void)? = nil
    ) {
        self.route = route
        self.records = records
        self.inventory = inventory
        self.onDeleteAll = onDeleteAll
        self.onDeleteHealthKitSamples = onDeleteHealthKitSamples
        self.onExport = onExport
        self.onExportDiagnostics = onExportDiagnostics
        self.onRunReanalysis = onRunReanalysis
        self.onImport = onImport
        self.onExportDay = onExportDay
        self.onDeleteDay = onDeleteDay
        self.onRunDayReanalysis = onRunDayReanalysis
        self.legacyMigrationState = legacyMigrationState
        self.onRunLegacyMigration = onRunLegacyMigration
    }

    public var body: some View {
        LooprDetailScaffold {
            switch route {
            case .history:
                history
            case .importPreview:
                importPreview
            case .export:
                export
            case .reanalysis:
                reanalysis
            case .diagnostics:
                diagnostics
            case .deletion:
                deletion
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(routeAccent))
        .accessibilityIdentifier(identifier)
        .confirmationDialog(
            "Delete all Loopr-owned data?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let onDeleteAll {
                Button("Delete all Loopr-owned data", role: .destructive, action: onDeleteAll)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DataDisclosureCopy.deleteAllData)
        }
        .confirmationDialog(
            "Delete saved data records for this day?",
            isPresented: Binding(
                get: { dayPendingDeletion != nil },
                set: { if !$0 { dayPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let dayPendingDeletion, let onDeleteDay {
                Button("Delete saved data records for " + dayPendingDeletion, role: .destructive) {
                    onDeleteDay(dayPendingDeletion)
                    self.dayPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { dayPendingDeletion = nil }
        } message: {
            Text("This deletes records listed in Data for \(dayPendingDeletion ?? "the selected day"). Band history, derived charts, and Apple Health samples remain.")
        }
        .confirmationDialog(
            "Remove Loopr samples from HealthKit?",
            isPresented: $isHealthKitConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let onDeleteHealthKitSamples {
                Button("Remove Loopr samples from HealthKit", role: .destructive, action: onDeleteHealthKitSamples)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the Loopr samples stored in HealthKit. It does not delete Loopr's local records.")
        }
    }

    private var title: String {
        switch route {
        case .history: "Data history"
        case .importPreview: "Import preview"
        case .export: "Export data"
        case .reanalysis: "Re-analysis"
        case .diagnostics: "Diagnostics"
        case .deletion: "Delete data"
        }
    }

    private var identifier: String {
        switch route {
        case .history: "data-history-screen"
        case .importPreview: "data-import-preview-screen"
        case .export: "data-export-screen"
        case .reanalysis: "data-reanalysis-screen"
        case .diagnostics: "data-diagnostics-screen"
        case .deletion: "data-deletion-screen"
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprSectionGroup(title: "Inventory") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            id: "data-history-records",
                            title: "Records",
                            value: String(records.count)
                        ),
                        HairlineMetricRow(
                            id: "data-history-stored-items",
                            title: "Stored items",
                            value: String(inventory.sqliteRows)
                        )
                    ])

                    if records.isEmpty {
                        LooprFormCard {
                            StateMessage(.noRecords)
                        }
                    }
                }
            }

            if !records.isEmpty {
                LooprSectionGroup(title: "Saved records") {
                    LooprFormCard(padding: LooprSpacing.none) {
                        VStack(spacing: LooprSpacing.none) {
                            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                                LooprRow(
                                    title: record.day,
                                    subtitle: record.provenance.displayName,
                                    symbol: "doc.text"
                                ) {
                                    EmptyView()
                                }
                                .padding(.horizontal, LooprSpacing.formCardPadding)
                                .accessibilityIdentifier("data-record-\(record.id)")

                                if index < records.count - 1 {
                                    LooprHairline()
                                }
                            }
                        }
                    }
                }

                LooprSectionGroup(title: "By day") {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        ForEach(historyDays, id: \.self) { day in
                            dayHistoryItem(day)
                        }
                    }
                }
            }
        }
    }

    private var importPreview: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprSectionGroup(title: "Import") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText("Review before importing", style: .cardTitle)
                            LooprText(
                                "Loopr checks each incoming record and asks before replacing a conflict.",
                                style: .prose,
                                color: .inkSecondary
                            )
                        }
                    }

                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            id: "data-import-incoming-records",
                            title: "Existing records",
                            value: String(records.count)
                        )
                    ])
                    .accessibilityIdentifier("data-import-state")

                    if let onImport {
                        Button("Choose backup", action: onImport)
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("data-import-choose")
                    } else {
                        unavailableState(
                            "Import is unavailable because the file picker is not connected.",
                            identifier: "data-import-unavailable"
                        )
                    }
                }
            }

            legacyMigration
        }
    }

    private var export: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprSectionGroup(title: "Export") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText("Create a local backup", style: .cardTitle)
                            LooprText(
                                "The local database backup can contain health, journal, and route data. Loopr does not upload it. Review the file before sharing it.",
                                style: .prose,
                                color: .inkSecondary
                            )
                        }
                    }

                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            id: "data-export-records",
                            title: "Records",
                            value: String(records.count)
                        )
                    ])

                    LooprText("ACTIONS", style: .sectionLabel, color: .inkSecondary)

                    if let onExport {
                        Button("Create backup", action: onExport)
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("data-export-create")
                    } else {
                        unavailableState(
                            "Export is unavailable because the backup handler is not connected.",
                            identifier: "data-export-unavailable"
                        )
                    }
                }
            }
        }
    }

    private var reanalysis: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprSectionGroup(title: "Re-analysis") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText("Re-analyze local records", style: .cardTitle)
                            LooprText(
                                "Re-analysis runs on this device and updates saved results for every record.",
                                style: .prose,
                                color: .inkSecondary
                            )
                        }
                    }

                    if let onRunReanalysis {
                        Button("Run local re-analysis", action: onRunReanalysis)
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("data-reanalysis-run")
                    } else {
                        unavailableState(
                            "Re-analysis is unavailable because the local analysis handler is not connected.",
                            identifier: "data-reanalysis-unavailable"
                        )
                    }
                }
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprSectionGroup(title: "Diagnostics") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText("Local diagnostics", style: .cardTitle)
                            LooprInlineMessage(
                                "Diagnostic capture is local. It never includes journal content, route coordinates, or private notes.",
                                tone: .neutral
                            )
                        }
                    }

                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            id: "data-diagnostics-storage-rows",
                            title: "Storage rows",
                            value: String(inventory.sqliteRows)
                        ),
                        inventoryRow(
                            id: "data-diagnostics-files",
                            title: "Files",
                            value: inventory.files
                        ),
                        inventoryRow(
                            id: "data-diagnostics-healthkit-samples",
                            title: "HealthKit samples",
                            value: inventory.healthKitSamples
                        )
                    ])

                    LooprText("ACTIONS", style: .sectionLabel, color: .inkSecondary)

                    if let onExportDiagnostics {
                        Button("Export diagnostics", action: onExportDiagnostics)
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("data-diagnostics-export")
                    } else {
                        unavailableState(
                            "Diagnostics are unavailable because the diagnostics handler is not connected.",
                            identifier: "data-diagnostics-unavailable"
                        )
                    }
                }
            }
        }
    }

    private var deletion: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprSurface(emphasis: .hero(.critical)) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    StatusChip("Destructive action", symbol: "trash", accent: .critical)
                    LooprText("Delete Loopr data", style: .cardTitle)
                    DataDestructiveDisclosure(
                        DataDisclosureCopy.deleteAllData,
                        symbol: "xmark.octagon"
                    )
                }
            }

            LooprSectionGroup(title: "Loopr-owned data") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            id: "data-deletion-records",
                            title: "Loopr records",
                            value: String(records.count)
                        ),
                        HairlineMetricRow(
                            id: "data-deletion-stored-items",
                            title: "Stored items",
                            value: String(inventory.sqliteRows)
                        )
                    ])

                    if onDeleteAll != nil {
                        Button("Delete all Loopr-owned data", role: .destructive) {
                            isDeleteConfirmationPresented = true
                        }
                        .buttonStyle(LooprDestructiveButtonStyle())
                        .accessibilityIdentifier("data-delete-all")
                    } else {
                        unavailableState(
                            "Deletion is unavailable because the local data store is not connected.",
                            identifier: "data-delete-unavailable"
                        )
                    }
                }
            }

            LooprSectionGroup(title: "HealthKit samples") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HairlineMetricList(rows: [
                        inventoryRow(
                            id: "data-deletion-healthkit-samples",
                            title: "Loopr samples",
                            value: inventory.healthKitSamples
                        )
                    ])

                    LooprFormCard {
                        DataDestructiveDisclosure(
                            "This action permanently deletes Loopr samples stored in HealthKit. It does not delete Loopr's local records.",
                            symbol: "xmark.octagon"
                        )
                    }

                    if onDeleteHealthKitSamples != nil {
                        Button("Remove Loopr samples from HealthKit", role: .destructive) {
                            isHealthKitConfirmationPresented = true
                        }
                        .buttonStyle(LooprDestructiveButtonStyle())
                        .accessibilityIdentifier("data-delete-healthkit-samples")
                    } else {
                        unavailableState(
                            "HealthKit sample removal is unavailable because HealthKit access is not connected.",
                            identifier: "data-delete-healthkit-unavailable"
                        )
                    }
                }
            }
        }
    }

    private var legacyMigration: some View {
        LooprSectionGroup(title: "Legacy data") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HairlineMetricList(rows: [
                    HairlineMetricRow(
                        id: "data-legacy-migration-state",
                        title: "Migration status",
                        value: legacyMigrationState.displayName
                    )
                ])

                switch legacyMigrationState {
                case .ready:
                    if let onRunLegacyMigration {
                        Button("Migrate legacy data", action: onRunLegacyMigration)
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("data-legacy-migration-run")
                    } else {
                        unavailableState(
                            "Legacy migration is unavailable because the migration handler is not connected.",
                            identifier: "data-legacy-migration-unavailable"
                        )
                    }
                case .notAvailable:
                    unavailableState(
                        "Legacy migration is unavailable because no legacy data was found.",
                        identifier: "data-legacy-migration-unavailable"
                    )
                case .completed, .refusedAlreadyMigrated:
                    unavailableState(
                        "Legacy migration is unavailable because the legacy data has already been migrated.",
                        identifier: "data-legacy-migration-unavailable"
                    )
                }
            }
        }
    }

    private func dayHistoryItem(_ day: String) -> some View {
        let dayRecordCount = records.filter { $0.day == day }.count
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LooprSpacing.sm))

        return LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                headerLayout {
                    LooprText(day, style: .rowTitle)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: LooprSpacing.sm) }
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                        MetricNumeral(String(dayRecordCount), compact: true)
                        LooprText(dayRecordCount == 1 ? "record" : "records", style: .metricUnit, color: .inkSecondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                LooprText("ACTIONS FOR THIS DAY", style: .sectionLabel, color: .inkSecondary)

                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    if let onExportDay {
                        Button("Export day") { onExportDay(day) }
                            .buttonStyle(LooprButtonStyle(prominent: false))
                            .accessibilityIdentifier("data-export-day-" + day)
                    }

                    if let onRunDayReanalysis {
                        Button("Re-analyze day") { onRunDayReanalysis(day) }
                            .buttonStyle(LooprButtonStyle(prominent: false))
                            .accessibilityIdentifier("data-reanalysis-day-" + day)
                    }

                }

                if onExportDay == nil {
                    LooprInlineMessage(
                        "Export for this day is unavailable because the export handler is not connected.",
                        tone: .neutral
                    )
                    .accessibilityIdentifier("data-export-day-" + day)
                }

                if onRunDayReanalysis == nil {
                    LooprInlineMessage(
                        "Re-analysis for this day is unavailable because the local analysis handler is not connected.",
                        tone: .neutral
                    )
                    .accessibilityIdentifier("data-reanalysis-day-" + day)
                }

                if onDeleteDay == nil {
                    LooprInlineMessage(
                        "Deleting this day is unavailable because the local data store is not connected.",
                        tone: .neutral
                    )
                    .accessibilityIdentifier("data-delete-day-" + day)
                }

                if onDeleteDay != nil {
                    LooprHairline()

                    Button("Delete day", role: .destructive) {
                        dayPendingDeletion = day
                    }
                    .buttonStyle(LooprDestructiveButtonStyle())
                    .accessibilityIdentifier("data-delete-day-" + day)
                }
            }
        }
    }

    private var historyDays: [String] {
        Array(Set(records.map(\.day))).sorted()
    }

    private var routeAccent: LooprColorToken {
        route == .deletion ? .critical : .brand
    }

    private func unavailableState(_ reason: String, identifier: String) -> some View {
        LooprFormCard {
            DataUnavailableState(reason: reason, accent: routeAccent)
        }
        .accessibilityIdentifier(identifier)
    }

    private func inventoryRow(id: String, title: String, value: Int?) -> HairlineMetricRow {
        HairlineMetricRow(
            id: id,
            title: title,
            value: value.map(String.init) ?? MetricState.absent.title,
            accent: value == nil ? .inkSecondary : nil
        )
    }
}

private struct DataDestructiveDisclosure: View {
    let text: String
    let symbol: String

    init(_ text: String, symbol: String = "xmark.octagon") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            Image(systemName: symbol)
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(.critical))
                .frame(width: LooprSpacing.lg, height: LooprSpacing.lg)
                .accessibilityHidden(true)

            LooprText(text, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

private struct DataUnavailableState: View {
    let reason: String
    let accent: LooprColorToken

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            StatusChip("Unavailable", symbol: "minus.circle", accent: accent)
            LooprInlineMessage(reason, tone: .neutral)
        }
    }
}
