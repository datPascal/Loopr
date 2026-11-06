import AnalyticsKit
import DesignSystem
import SwiftUI

/// What a report page can do. Each closure returns an error message, or nil when it worked.
public struct LabReportActions {
    public var saveValue: @MainActor (LabValue) async -> String?
    public var markChecked: @MainActor (UUID) async -> String?
    public var deleteReport: @MainActor () async -> String?
    /// Opens the method page for blood age. Nil hides the link until that route exists.
    public var openBloodAgeMethod: (@MainActor () -> Void)?
    /// Opens the Ranges method page from a marker page. Nil hides the link.
    public var openRangesMethod: (@MainActor () -> Void)?

    public init(
        saveValue: @escaping @MainActor (LabValue) async -> String?,
        markChecked: @escaping @MainActor (UUID) async -> String?,
        deleteReport: @escaping @MainActor () async -> String?,
        openBloodAgeMethod: (@MainActor () -> Void)? = nil,
        openRangesMethod: (@MainActor () -> Void)? = nil
    ) {
        self.saveValue = saveValue
        self.markChecked = markChecked
        self.deleteReport = deleteReport
        self.openBloodAgeMethod = openBloodAgeMethod
        self.openRangesMethod = openRangesMethod
    }
}

/// One report opened (`labs-report-screen`): a hero with the draw's day, the lab and how many values it holds (and blood
/// age when this draw feeds it), then the values by body system with the lab's own range and flag. A value opens its
/// marker page with every draw of it. Loopr never calls a value normal or abnormal here.
public struct LabReportScreen: View {
    @Environment(\.dismiss) private var dismiss
    private let detail: LabReportDetail?
    private let missing: Bool
    private let actions: LabReportActions
    @State private var editing: LabValue?
    @State private var opened: UUID?
    @State private var confirmingDelete = false
    @State private var message: String?
    @State private var working = false

    public init(detail: LabReportDetail?, missing: Bool = false, actions: LabReportActions) {
        self.detail = detail
        self.missing = missing
        self.actions = actions
    }

    public var body: some View {
        LabsPage {
            if let message { LooprInlineMessage(message, tone: .warning).accessibilityIdentifier("labs-report-message") }
            if let detail {
                content(detail)
            } else if missing {
                LooprInlineMessage("This report is no longer saved on this iPhone.", tone: .neutral)
            } else {
                LooprSkeleton(height: 120)
            }
        }
        .navigationTitle("Lab report")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { id in
            LabMarkerScreen(row: detail?.rows.first { $0.id == id }, labName: detail.map { LabsDisplay.labName($0.report) },
                            save: actions.saveValue, openRangesMethod: actions.openRangesMethod,
                            openBloodAgeMethod: actions.openBloodAgeMethod)
        }
        .sheet(item: $editing) { value in
            LabValueEditor(value: value) { updated in
                let failure = await actions.saveValue(updated)
                if failure == nil { editing = nil }
                return failure
            }
        }
        // An alert, not a popover: it always shows Cancel (ICP R3-LAB-4).
        .alert("Delete this report?", isPresented: $confirmingDelete) {
            Button("Delete report", role: .destructive) {
                working = true
                Task {
                    if let failure = await actions.deleteReport() { message = failure } else { dismiss() }
                    working = false
                }
            }
            .accessibilityIdentifier("labs-report-delete-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(detail.map(LabReportScreen.deleteMessage) ?? "")
        }
        .accessibilityIdentifier("labs-report-screen")
    }

    /// "This deletes the report and its 1 value from this iPhone." Blood age is named only when this draw feeds it.
    static func deleteMessage(_ detail: LabReportDetail) -> String {
        let base = "This deletes the report and its \(LabsDisplay.valueCount(detail.valueCount)) from this iPhone."
        return detail.usedForBloodAge ? base + " Your blood age comes from this draw, so it changes or goes away." : base
    }

    @ViewBuilder
    private func content(_ detail: LabReportDetail) -> some View {
        header(detail)
        ForEach(detail.groups) { group in
            LabsSection(group.title) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    valueRow(row, report: detail.report)
                    if index < group.rows.count - 1 { LooprHairline() }
                }
            }
        }
        footer(detail)
    }

    /// The report's lead card: the day, the lab once for every value under it, the count, and blood age when it fed it.
    private func header(_ detail: LabReportDetail) -> some View {
        let report = detail.report
        return LooprCard(style: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LabsEyebrow(text: LabsDisplay.reportEyebrow(report))
                LooprText(LabsDisplay.day(report.collectedAt, timeZoneIdentifier: report.timeZoneIdentifier), style: .titleLarge)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(LabsDisplay.reportHeader(report))
                ProvenanceChip(.lab(name: report.labName ?? "Lab not named"), qualifier: LabsDisplay.sourceText(report.source),
                               identifier: "labs-report-source")
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.md) {
                    LooprHeroNumber(Double(detail.valueCount), unit: detail.valueCount == 1 ? "value" : "values",
                                    style: .heroNumeralLarge, color: .brand)
                    if let blood = detail.bloodAge { bloodAgePin(blood) }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("labs-report-count")
                if detail.needsReviewCount > 0 {
                    StatusChip(detail.needsReviewCount == 1 ? "1 needs a look" : "\(detail.needsReviewCount) need a look",
                               symbol: "eye", tone: .warning)
                }
                if let note = detail.bloodAgeNote {
                    LooprText(note, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("labs-report-blood-age-note")
                }
                if let note = report.note { LooprText(note, style: .prose, color: .inkSecondary) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("labs-report-header")
    }

    /// Blood age from this draw, small beside the count. It opens the method page when that route exists.
    @ViewBuilder
    private func bloodAgePin(_ reading: DataBloodAgeReading) -> some View {
        let text = "Blood age \(DataText.oneDecimal(reading.estimate.phenotypicAgeYears))"
        let pin = HStack(spacing: LooprSpacing.xxs) {
            Circle().fill(Color.loopr(.brand)).frame(width: 7, height: 7)
                .shadow(color: Color.loopr(.brand).opacity(0.7), radius: 4)
                .accessibilityHidden(true)
            LooprText(text, style: .label, color: .ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.loopr(.brand).opacity(0.14), in: Capsule())
        if let open = actions.openBloodAgeMethod {
            Button(action: open) { pin }
                .buttonStyle(.looprPressableCard)
                .accessibilityHint("Opens the method page")
                .accessibilityIdentifier("labs-report-blood-age-pin")
        } else {
            pin.accessibilityIdentifier("labs-report-blood-age-pin")
        }
    }

    private func valueRow(_ row: LabValueRow, report: LabReport) -> some View {
        let value = row.value
        let range = LabsDisplay.rangeText(value.referenceRange)
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            Button { opened = value.id } label: {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                        VStack(alignment: .leading, spacing: 0) {
                            LooprText(row.name, style: .rowTitle)
                            if let assay = value.assay { LooprText(assay, style: .caption, color: .inkSecondary) }
                        }
                        Spacer(minLength: LooprSpacing.sm)
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                            Text(LabsDisplay.valueText(value))
                                .looprTypography(.metricValue)
                                .foregroundStyle(Color.loopr(.ink))
                            if let unit = value.unit {
                                Text(unit).looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                            }
                            if let flag = LabsDisplay.flagText(value) { LabFlagBadge(flag: flag) }
                        }
                        .multilineTextAlignment(.trailing)
                        LooprChevron()
                    }
                    HStack(spacing: LooprSpacing.sm) {
                        // Outside the range reads in full ink, still without a verdict, so it stands out in the list
                        // (ICP R3-LAB-14).
                        LooprText([range.map { "Lab range \($0)" } ?? "No range printed", LabsDisplay.rangePosition(value)?.lowercasedFirst]
                                    .compactMap { $0 }.joined(separator: " · "), style: .caption,
                                  color: LabsDisplay.isOutsideRange(value) ? .ink : .inkSecondary)
                        Spacer(minLength: LooprSpacing.sm)
                        if row.history.count >= 2 { sparkline(row) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .contextMenu {
                Button("Edit value", systemImage: "pencil") { editing = value }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(row, report: report, range: range))
            .accessibilityHint("Opens every draw of \(row.name)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Edit value") { editing = value }
            .accessibilityIdentifier("labs-value-\(value.id.uuidString)")
            if value.needsReview {
                HStack(spacing: LooprSpacing.sm) {
                    LooprText("Scanned values wait for a look until you check them against the report.", style: .caption,
                              color: .warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: LooprSpacing.sm)
                    Button("Mark checked") { check(value) }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .brand))
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(working)
                        .accessibilityLabel("Mark \(row.name) checked")
                        .accessibilityIdentifier("labs-value-check-\(value.id.uuidString)")
                }
            }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }

    /// The draws as dots joined by a line, placed by date. The daily sparkline drew two draws months apart as two
    /// loose specks with no line (ICP R3-LAB-8).
    private func sparkline(_ row: LabValueRow) -> some View {
        let points = row.history
        return Canvas { context, size in
            guard let first = points.first?.date, let last = points.last?.date else { return }
            let span = max(last.timeIntervalSince(first), 1)
            let values = points.map(\.value)
            let low = values.min() ?? 0, high = values.max() ?? 1
            let range = high - low
            let inset: CGFloat = 3
            let spots = points.map { point in
                CGPoint(x: inset + CGFloat(point.date.timeIntervalSince(first) / span) * (size.width - 2 * inset),
                        y: range == 0 ? size.height / 2 : inset + CGFloat((high - point.value) / range) * (size.height - 2 * inset))
            }
            var line = Path()
            line.addLines(spots)
            context.stroke(line, with: .color(Color.loopr(.brand).opacity(0.55)), lineWidth: 1.4)
            for spot in spots {
                context.fill(Path(ellipseIn: CGRect(x: spot.x - 2.5, y: spot.y - 2.5, width: 5, height: 5)),
                             with: .color(Color.loopr(.brand)))
            }
        }
        .frame(width: 72, height: 22)
        .accessibilityHidden(true)
    }

    private func spoken(_ row: LabValueRow, report: LabReport, range: String?) -> String {
        let value = row.value
        var parts = ["\(row.name) \(LabsDisplay.valueText(value))\(value.unit.map { " \($0)" } ?? "")"]
        if value.isLimit { parts.append(LabsDisplay.spokenValue(value)) }
        if let range { parts.append("lab range \(range)") }
        if let flag = LabsDisplay.flagText(value) { parts.append("lab flag \(flag)") }
        parts.append("from \(LabsDisplay.labName(report))")
        if row.history.count >= 2 {
            let earlier = row.history.count - 1
            parts.append(earlier == 1 ? "1 earlier value" : "\(earlier) earlier values")
        }
        if value.needsReview { parts.append("needs a look") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func footer(_ detail: LabReportDetail) -> some View {
        if detail.usedForBloodAge {
            bloodAgeLine
        }
        LooprText(LabsDisplay.notAMedicalDevice, style: .caption, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xxs)
            .accessibilityIdentifier("labs-report-disclaimer")
        // A quiet row, not a slab: deleting is rare and asks again before anything goes.
        Button(role: .destructive) { confirmingDelete = true } label: {
            Label("Delete report", systemImage: "trash")
        }
        .buttonStyle(LooprButtonStyle(prominent: false, accent: .critical, quiet: true))
        .disabled(working)
        .accessibilityIdentifier("labs-report-delete")
    }

    @ViewBuilder
    private var bloodAgeLine: some View {
        if let open = actions.openBloodAgeMethod {
            Button(action: open) {
                HStack {
                    LooprText("Used for blood age", style: .settingsRow)
                    Spacer(minLength: LooprSpacing.sm)
                    LooprChevron()
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                .looprCardBackground()
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityHint("Opens the method page")
            .accessibilityIdentifier("labs-report-blood-age")
        } else {
            LooprText("Used for blood age", style: .caption, color: .inkSecondary)
                .padding(.horizontal, LooprSpacing.xxs)
                .accessibilityIdentifier("labs-report-blood-age")
        }
    }

    private func check(_ value: LabValue) {
        working = true
        message = nil
        Task {
            message = await actions.markChecked(value.id)
            working = false
        }
    }
}

/// Edit one stored value in a sheet (`labs-value-edit-screen`). The digits stay as typed, and saving checks the value.
struct LabValueEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LabValueDraft
    @State private var error: String?
    @State private var saving = false
    private let reportID: UUID
    private let save: @MainActor (LabValue) async -> String?

    init(value: LabValue, save: @escaping @MainActor (LabValue) async -> String?) {
        _draft = State(initialValue: LabValueDraft(editing: value))
        reportID = value.reportID
        self.save = save
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    LabValueFields(draft: $draft, idPrefix: "labs-value-edit")
                    if let error { LooprInlineMessage(error, tone: .critical).accessibilityIdentifier("labs-value-edit-error") }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.vertical, LooprSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Edit value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("labs-value-edit-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }.disabled(saving).accessibilityIdentifier("labs-value-edit-save")
                }
            }
        }
        .accessibilityIdentifier("labs-value-edit-screen")
    }

    private func submit() {
        labsDismissKeyboard()
        let built: LabValue
        do { built = try draft.build(reportID: reportID) } catch {
            self.error = LabsEntryCopy.message(for: error)
            return
        }
        saving = true
        Task {
            error = await save(built)
            saving = false
        }
    }
}
