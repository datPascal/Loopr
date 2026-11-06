import Foundation
import SwiftUI
import DesignSystem

// The weight and body composition log screen and its entry sheet (LV-08b step 5). Every value shows where it came
// from through `ProvenanceChip`, and a quantity nobody recorded reads "Not recorded", never a zero.

/// Opens the log from the Body screen. The app sets it; without it the Body screen leaves the row out.
public struct BodyLogAction: Sendable {
    public let open: @MainActor @Sendable () -> Void

    public init(open: @escaping @MainActor @Sendable () -> Void) { self.open = open }
}

extension EnvironmentValues {
    @Entry public var bodyOpenLog: BodyLogAction? = nil
    /// The newest weight, body fat and lean mass across typed entries and Apple Health, set by the app. Nil until it
    /// has loaded, and then the Body screen shows only what the profile holds.
    @Entry public var bodyLogSummary: BodyLogSummary? = nil
}

extension View {
    @ViewBuilder fileprivate func bodyDecimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    @ViewBuilder fileprivate func bodyInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: Screen

public struct BodyLogScreen: View {
    @Environment(\.looprMeasurementSystem) private var system
    @Environment(\.calendar) private var calendar
    @ObservedObject private var viewModel: BodyLogViewModel
    @State private var showsEntrySheet = false

    public init(viewModel: BodyLogViewModel) { self.viewModel = viewModel }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.xl) {
                if viewModel.loadState != .loaded {
                    LooprLoadingPlaceholder(.heroCard(cards: 2))
                } else if viewModel.entries.isEmpty {
                    empty
                } else {
                    trend
                    entries
                }
                if let failure = viewModel.failure {
                    LooprText(failure, style: .body, color: .critical)
                        .accessibilityIdentifier("body-log-error")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(BodyLogCopy.title)
        .bodyInlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsEntrySheet = true } label: { Label("Log", systemImage: "plus") }
                    .accessibilityIdentifier("body-log-add")
            }
        }
        .sheet(isPresented: $showsEntrySheet) {
            BodyEntrySheet(now: viewModel.currentTime) { input in await viewModel.save(input) }
        }
        .looprToast($viewModel.toast) { Task { await viewModel.undoDelete() } }
        .task { await viewModel.load() }
        .accessibilityIdentifier("body-log-screen")
    }

    // MARK: Empty

    private var empty: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText("Nothing logged yet", style: .rowTitle)
                Text(BodyLogCopy.emptyText(viewModel.snapshot.healthStatus))
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Log") { showsEntrySheet = true }
                    .buttonStyle(LooprButtonStyle(accent: .strain))
                    .accessibilityIdentifier("body-log-empty-add")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body-log-empty")
    }

    // MARK: Trend

    private var trend: some View {
        let now = viewModel.currentTime
        let series = BodyLogQuantity.allCases.map {
            BodyLogSeries.make(entries: viewModel.entries, quantity: $0, system: system, now: now, calendar: calendar)
        }
        return BodySection(title: "Trend", detail: "The last 90 days", identifier: "body-log-trend") {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                        BodyLogTrendBlock(series: item, system: system, prominent: index == 0)
                        if index < series.count - 1 {
                            Rectangle().fill(Color.loopr(.divider)).frame(height: 1).accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Entries

    private var entries: some View {
        BodySection(title: "Entries", detail: "Newest first") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprSurface {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                            BodyLogEntryRow(entry: entry, system: system) { Task { await viewModel.delete(entry) } }
                                .padding(.vertical, LooprSpacing.sm)
                            if index < viewModel.entries.count - 1 {
                                Rectangle().fill(Color.loopr(.divider)).frame(height: 1).accessibilityHidden(true)
                            }
                        }
                    }
                }
                if let note = BodyLogCopy.healthNote(viewModel.snapshot.healthStatus) {
                    LooprText(note, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("body-log-health-note")
                } else if viewModel.snapshot.healthStatus == .reading {
                    LooprText(BodyLogCopy.healthFootnote, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("body-log-health-footnote")
                }
            }
        }
    }
}

// MARK: Trend block

struct BodyLogTrendBlock: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let series: BodyLogSeries
    let system: LooprMeasurementSystem
    let prominent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LooprSpacing.sm))
            layout {
                LooprText(series.quantity.title, style: .rowTitle)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: LooprSpacing.sm) }
                if let latest = series.latest {
                    let shown = BodyLogFormat.measurement(series.quantity, value: latest.value, system: system)
                    LooprValueText(shown.value, unit: shown.unit, valueStyle: prominent ? .metricCompact : .metricValue)
                } else {
                    LooprText(BodyLogCopy.absent, style: .caption, color: .inkSecondary)
                }
            }
            if let latest = series.latest {
                ProvenanceChip(latest.provenance, qualifier: latest.measuredAt.formatted(.dateTime.day().month(.abbreviated)),
                               identifier: "body-log-trend-source-\(series.quantity.rawValue)")
            }
            if series.hasTrend {
                LooprSparkline(points: series.points, days: series.days, endingOn: series.endingOn, accent: .strain,
                               height: prominent ? 64 : 40)
                    .padding(.top, LooprSpacing.xxs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body-log-trend-\(series.quantity.rawValue)")
    }
}

// MARK: Entry row

struct BodyLogEntryRow: View {
    let entry: BodyLogEntry
    let system: LooprMeasurementSystem
    let delete: () -> Void

    private var values: [(BodyLogQuantity, Double)] {
        BodyLogQuantity.allCases.compactMap { quantity in entry.value(quantity).map { (quantity, $0) } }
    }

    var body: some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                ForEach(values, id: \.0) { quantity, value in
                    let shown = BodyLogFormat.measurement(quantity, value: value, system: system)
                    HStack(alignment: .firstTextBaseline) {
                        LooprText(quantity.title, style: quantity == values.first?.0 ? .rowTitle : .caption,
                                  color: quantity == values.first?.0 ? .ink : .inkSecondary)
                        Spacer(minLength: LooprSpacing.sm)
                        LooprValueText(shown.value, unit: shown.unit,
                                       valueStyle: quantity == values.first?.0 ? .metricValue : .metricUnit)
                    }
                }
                LooprText(entry.measuredAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
                          style: .caption, color: .inkSecondary)
                ProvenanceChip(entry.origin.provenance, identifier: "body-log-source-\(entry.id)")
                if !entry.isTyped {
                    LooprText(BodyLogCopy.readOnlyHealthNote, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if entry.isTyped {
                Button(role: .destructive, action: delete) {
                    Label("Delete entry", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.loopr(.critical))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete entry from \(entry.measuredAt.formatted(date: .abbreviated, time: .shortened))")
                .accessibilityIdentifier("body-log-delete-\(entry.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body-log-entry-\(entry.id)")
    }
}

// MARK: Entry sheet

/// Weight is required. Body fat and lean mass are optional, and an empty field stays absent.
struct BodyEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.looprMeasurementSystem) private var system
    let now: Date
    /// Stores the checked entry. True when it was saved.
    let save: @MainActor (BodyLogInput) async -> Bool

    @State private var weightText = ""
    @State private var bodyFatText = ""
    @State private var leanMassText = ""
    @State private var measuredAt: Date
    @State private var error: BodyLogValidationError?
    @State private var saveFailed = false
    @State private var saving = false

    init(now: Date, save: @escaping @MainActor (BodyLogInput) async -> Bool) {
        self.now = now
        self.save = save
        _measuredAt = State(initialValue: now)
    }

    private var unit: String { BodyLogFormat.unitLabel(system) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    LooprCard(density: .flush) {
                        VStack(spacing: 0) {
                            LooprTextFieldRow(title: "Weight (\(unit))", placeholder: "Required", text: $weightText)
                                .bodyDecimalKeyboard()
                                .accessibilityIdentifier("body-entry-weight")
                            LooprHairline()
                            LooprTextFieldRow(title: "Body fat (%)", placeholder: "Optional", text: $bodyFatText)
                                .bodyDecimalKeyboard()
                                .accessibilityIdentifier("body-entry-body-fat")
                            LooprHairline()
                            LooprTextFieldRow(title: "Lean mass (\(unit))", placeholder: "Optional", text: $leanMassText)
                                .bodyDecimalKeyboard()
                                .accessibilityIdentifier("body-entry-lean-mass")
                            LooprHairline()
                            DatePicker("Date and time", selection: $measuredAt, in: ...now)
                                .looprTypography(.settingsRow)
                                .padding(.horizontal, LooprSpacing.formCardPadding)
                                .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                                .accessibilityIdentifier("body-entry-date")
                        }
                    }
                    if let error {
                        LooprText(error.message(system: system), style: .body, color: .critical)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("body-entry-error")
                    } else if saveFailed {
                        LooprText("Loopr could not save this entry. Try again.", style: .body, color: .critical)
                            .accessibilityIdentifier("body-entry-error")
                    }
                    LooprText("Entries stay on this iPhone. Loopr does not write them to Apple Health.",
                              style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(LooprSpacing.screenGutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.loopr(.background))
            .safeAreaInset(edge: .bottom) {
                Button(saving ? "Saving" : "Save", action: submit)
                    .buttonStyle(LooprButtonStyle(accent: .strain))
                    .disabled(saving)
                    .accessibilityIdentifier("body-entry-save")
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.sm)
                    .padding(.bottom, LooprSpacing.xs)
                    .background(Color.loopr(.background).opacity(0.94))
            }
            .navigationTitle("Log weight")
            .bodyInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("body-entry-cancel")
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .presentationDetents([.large])
        .accessibilityIdentifier("body-entry-sheet")
    }

    private func submit() {
        error = nil
        saveFailed = false
        switch BodyLogDraft.validate(weightText: weightText, bodyFatText: bodyFatText, leanMassText: leanMassText,
                                     measuredAt: measuredAt, now: now, system: system) {
        case .failure(let problem):
            error = problem
        case .success(let input):
            saving = true
            Task { @MainActor in
                defer { saving = false }
                if await save(input) { dismiss() } else { saveFailed = true }
            }
        }
    }
}
