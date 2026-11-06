import DesignSystem
import SwiftUI

/// Make a report file: pick metrics, a period and whether blood test values go in, preview the page, then save
/// the HTML and JSON files through the share sheet. Both files are built on this iPhone and nothing is uploaded.
/// The top of the screen says who sees the file: whoever the person sends it to (ICP R2-LAB-12).
public struct PublishDashboardScreen: View {
    @State private var model: PublishDashboardModel

    /// - Parameters:
    ///   - loadCandidates: every metric the picker lists, with `hasData` set from what is stored.
    ///   - loadSeries: the daily values of the picked metric keys for a period.
    public init(timeZone: TimeZone = .current,
                now: @escaping @Sendable () -> Date = { Date() },
                loadCandidates: @escaping @Sendable () async -> [PublishMetricDescriptor],
                loadSeries: @escaping @Sendable ([String], PublishPeriod) async -> [PublishMetricSeries]) {
        _model = State(initialValue: PublishDashboardModel(timeZone: timeZone, now: now,
                                                           loadCandidates: loadCandidates, loadSeries: loadSeries))
    }

    public var body: some View {
        LooprDetailScaffold(spacing: LooprSpacing.lg) {
            LooprText(PublishCopy.intro, style: .prose, color: .inkSecondary)
            // Who sees it, before anything is picked (ICP R2-LAB-12).
            LooprCard {
                Label {
                    LooprText(PublishCopy.audience, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "person.2").foregroundStyle(Color.loopr(.brand))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("publish-audience")
            if model.isLoading {
                ProgressView("Reading your data")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LooprSpacing.lg)
            } else {
                options
                if model.hasAnyData {
                    LooprSectionHeader("Metrics", detail: PublishCopy.pickedCount(model.picked.count), identifier: "publish-picked-count")
                    ForEach(model.groups(), id: \.group) { entry in
                        group(entry.group, metrics: entry.metrics)
                    }
                } else {
                    LooprCard {
                        LooprText("Nothing to publish yet. A metric shows up here once Loopr has stored readings for it, from your band or from Apple Health.",
                                  style: .prose, color: .inkSecondary)
                    }
                    .accessibilityIdentifier("publish-empty")
                }
                if !model.picked.isEmpty { previewSection }
                if let error = model.error {
                    LooprCard(style: .warning) { LooprText(error, style: .prose) }
                }
            }
        }
        .tint(Color.loopr(.brand))
        .navigationTitle(PublishCopy.title)
        .toolbarTitleDisplayMode(.inline)
        .accessibilityIdentifier("publish-screen")
        .task { await model.load() }
        .task(id: model.previewKey) { await model.refreshPreview() }
        .onDisappear { model.discardFiles() }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Period")
            Picker("Period", selection: $model.period) {
                Text("30 days").tag(PublishPeriod.days30)
                Text("90 days").tag(PublishPeriod.days90)
                Text("12 months").tag(PublishPeriod.months12)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("publish-period")
            LooprCard(density: .flush) {
                LooprToggleRow(title: "Include blood test values",
                               subtitle: PublishCopy.bloodSwitch(hasBloodTests: model.hasBloodTests, isOn: model.includeBloodTests),
                               identifier: "publish-include-labs", isOn: $model.includeBloodTests)
                    .disabled(!model.hasBloodTests && !model.includeBloodTests)
            }
            .padding(.top, LooprSpacing.xs)
        }
    }

    private func group(_ group: PublishGroup, metrics: [PublishMetricDescriptor]) -> some View {
        let pickable = model.canPickAny(group)
        let toggleAll: (() -> Void)? = pickable ? { model.toggleAll(group) } : nil
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(group.title,
                               detail: group == .bloodTests && !model.includeBloodTests ? "Switch on blood test values to pick these" : nil,
                               actionTitle: pickable ? (model.allPicked(group) ? "Clear" : "Pick all") : nil,
                               identifier: "publish-group-\(group.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                               action: toggleAll)
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.element.key) { index, metric in
                        row(metric)
                        if index < metrics.count - 1 { LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding) }
                    }
                }
            }
        }
    }

    private func row(_ metric: PublishMetricDescriptor) -> some View {
        let enabled = model.canPick(metric)
        let picked = model.isPicked(metric)
        return Button { model.toggle(metric) } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(metric.name, style: .rowTitle, color: enabled ? .ink : .inkSecondary)
                    if !metric.hasData {
                        // The picker looks back 12 months; say so, so an empty row is not read as "never" (ICP R3-UPG-7).
                        LooprText("No data in the last 12 months", style: .prose, color: .inkSecondary)
                    } else if !metric.unit.isEmpty {
                        LooprText(metric.unit, style: .prose, color: .inkSecondary)
                    }
                }
                Spacer(minLength: LooprSpacing.sm)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.loopr(picked ? .brand : .inkSecondary))
                    .opacity(enabled ? 1 : 0.4)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(metric.hasData ? "" : "No data in the last 12 months")
        .accessibilityIdentifier("publish-metric-\(metric.key)")
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Preview")
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                if let preview = model.preview {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        PublishPreviewWebView(html: preview.html)
                            .frame(height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityIdentifier("publish-preview-web")
                    }
                    LooprText("HTML \(Self.size(preview.htmlBytes)) and JSON \(Self.size(preview.jsonBytes))",
                              style: .prose, color: .inkSecondary)
                        .accessibilityIdentifier("publish-size")
                    if let blood = PublishCopy.previewBlood(hasBloodTests: model.hasBloodTests, isOn: model.includeBloodTests,
                                                            pickedNames: model.pickedBloodNames) {
                        LooprText(blood, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("publish-blood-line")
                    }
                    LooprText("Only the metrics you picked are in this file. Nothing is uploaded.", style: .prose, color: .inkSecondary)
                    ShareLink(items: preview.files.urls) {
                        Label("Save or share the files", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("publish-save")
                } else {
                    ProgressView("Building the page")
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("publish-preview")
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The screen's words, kept here so tests read the same strings the screen shows.
enum PublishCopy {
    static let title = "Make a report file"
    static let intro = "Pick the numbers to put in a report. Loopr builds it on this iPhone as a web page and a data file. Look it over here, then send it or save it."
    static let audience = "It stays on this iPhone until you send it. Whoever you send it to sees every number on it."

    static func pickedCount(_ count: Int) -> String { count == 0 ? "None picked" : "\(count) picked" }

    /// Under the blood test switch. It changes with the switch and says what goes on the page: for each picked
    /// marker, its values from your reports in the period with the unit. The renderer adds no lab name or range.
    static func bloodSwitch(hasBloodTests: Bool, isOn: Bool) -> String {
        if !hasBloodTests { return "You have no blood tests saved, so there is nothing to add." }
        return isOn
            ? "On. Each blood marker you pick shows its values from your reports in this period, with its unit. The lab's name and range are left out."
            : "Off by default. Blood test results are some of the most personal numbers in Loopr."
    }

    /// Above the share button: whether blood test values are on the page, and which. Nil without blood tests.
    static func previewBlood(hasBloodTests: Bool, isOn: Bool, pickedNames: [String]) -> String? {
        guard hasBloodTests else { return nil }
        guard isOn else { return "No blood test values are on this page." }
        guard !pickedNames.isEmpty else { return "No blood marker is picked, so the page has no blood test values." }
        return "Blood test values on this page: \(pickedNames.formatted(.list(type: .and)))."
    }
}
