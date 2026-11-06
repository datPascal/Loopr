import AIKit
import DesignSystem
import SwiftUI

/// Shows exactly what a chat sends to the provider and asks for a yes. Nothing leaves the phone
/// before Allow. Cancel puts the toggles back to what the chat last approved.
struct CoachConsentSheet: View {
    @ObservedObject var model: CoachChatViewModel
    @State private var showsFullSummary = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var compactLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private var provider: CoachProvider? { model.conversation?.configuration.provider }
    private var providerName: String { provider?.name ?? "your provider" }
    private var canAllow: Bool { !model.previewLoading && !model.preview.isEmpty && !model.confirming }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        Text("Share with \(providerName)?")
                            .looprTypography(.cardTitle)
                            .foregroundStyle(Color.loopr(.ink))
                            .accessibilityAddTraits(.isHeader)
                        Text("Your messages and the summary below go straight to \(providerName). Follow-ups reuse this summary. Changing what is shared starts a new chat, so earlier replies cannot carry removed data into the next request.")
                            .looprTypography(.prose)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reason = model.consentReason { LooprInlineMessage(reason, tone: .warning) }

                    LooprSectionGroup(title: "What to share") {
                        LooprFormCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(CoachConsentDomain.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { LooprHairline().padding(.leading, LooprSpacing.formCardPadding) }
                                    LooprToggleRow(title: row.title, subtitle: row.detail, isOn: binding(row.keyPath))
                                        .accessibilityIdentifier("coach-share-" + row.id)
                                }
                            }
                        }
                    }

                    if model.sharing.metrics, model.previewDaysWithData == 0, !model.previewLoading {
                        LooprInlineMessage("Loopr found no saved measurements for the last 30 days. Ask can still answer general questions.", tone: .warning)
                    }

                    LooprSectionGroup(title: "Summary that will be sent") { summaryCard }

                    if !model.preferences.instructions.isEmpty {
                        LooprSectionGroup(title: "Your coach instructions") {
                            Text(model.preferences.instructions)
                                .looprTypography(.settingsRow)
                                .foregroundStyle(Color.loopr(.ink))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(LooprSpacing.formCardPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .looprCardBackground()
                        }
                    }
                    if let message = model.consentError { LooprInlineMessage(message, tone: .critical) }
                    if compactLayout { actionBar }
                    else { disclosure }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.lg)
            }
            .scrollIndicators(.hidden)
            .background(Color.loopr(.settingsBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { if !compactLayout { actionBar } }
            .navigationTitle("Review shared data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelConsent() }
                        .disabled(model.confirming)
                        .accessibilityIdentifier("coach-cancel-consent")
                }
                // Centred, like the other coach sheets. With a leading button the system title sits beside it.
                ToolbarItem(placement: .principal) {
                    Text("Review shared data")
                        .font(.headline)
                        .foregroundStyle(Color.loopr(.ink))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .tint(Color.loopr(.brand))
        .interactiveDismissDisabled(model.confirming)
        .presentationDetents([.large])
        .presentationBackground(Color.loopr(.settingsBackground))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            Text("Loopr builds this from your saved data. Read it before you allow.")
                .looprTypography(.prose)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
            if model.previewLoading {
                HStack(spacing: LooprSpacing.sm) {
                    ProgressView()
                    Text("Preparing summary…")
                        .looprTypography(.settingsRow)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                CoachSummaryText(text: model.preview, expanded: showsFullSummary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("coach-consent-summary")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LooprSpacing.xs) { summaryButtons }
                VStack(alignment: .leading, spacing: LooprSpacing.xs) { summaryButtons }
            }
        }
        .padding(LooprSpacing.formCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground(.sunk)
    }

    @ViewBuilder private var summaryButtons: some View {
        if !model.previewLoading, CoachSummaryText.hidesLines(in: model.preview) {
            Button(showsFullSummary ? "Show less" : "Show all") { showsFullSummary.toggle() }
                .buttonStyle(CoachCardButtonStyle())
        }
        Button("Rebuild from latest data") { Task { await model.refreshPreview() } }
            .buttonStyle(CoachCardButtonStyle())
            .disabled(model.previewLoading)
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            Text("API charges apply. \(providerName) handles submitted data under its own privacy policy.")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
            if let provider {
                Link("Read the \(provider.name) privacy policy", destination: provider.privacyURL)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.brandInk))
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    /// The primary button. Pinned under the content at normal text sizes. At accessibility sizes it
    /// follows the content instead, so the toggles are on screen before Allow.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            Button("Allow for this chat") { Task { await model.confirmConsent() } }
                .buttonStyle(LooprPrimaryButtonStyle())
                .disabled(!canAllow)
                .accessibilityIdentifier("coach-confirm-consent")
            if compactLayout { disclosure }
            else {
                Text("API charges apply.")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, compactLayout ? 0 : LooprSpacing.screenGutter)
        .padding(.top, compactLayout ? 0 : LooprSpacing.sm)
        .padding(.bottom, compactLayout ? 0 : LooprSpacing.xs)
        .background { if !compactLayout { Color.loopr(.settingsBackground).ignoresSafeArea() } }
        .overlay(alignment: .top) { if !compactLayout { LooprHairline() } }
    }

    private func binding(_ keyPath: WritableKeyPath<CoachSharing, Bool>) -> Binding<Bool> {
        Binding(get: { model.sharing[keyPath: keyPath] }, set: { model.setShare(keyPath, $0) })
    }
}

/// The summary as headed groups. A line that ends in a colon starts a group; the lines after it
/// are its rows. It reads like a short report, not a log.
struct CoachSummaryText: View {
    let text: String
    let expanded: Bool
    private struct Group: Identifiable {
        let id: Int
        var title: String?
        var rows: [String]
    }

    private static let visibleGroups = 3
    private static let visibleRows = 3

    /// True when the collapsed summary leaves some of the text out, so "Show all" has something to show.
    static func hidesLines(in text: String) -> Bool {
        let all = groups(in: text)
        return all.count > visibleGroups || all.contains { $0.rows.count > visibleRows }
    }

    private var groups: [Group] { Self.groups(in: text) }

    private static func groups(in text: String) -> [Group] {
        var result: [Group] = []
        for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.hasSuffix(":") {
                result.append(.init(id: result.count, title: String(line.dropLast()), rows: []))
            } else if result.isEmpty {
                result.append(.init(id: 0, title: nil, rows: [line]))
            } else {
                result[result.count - 1].rows.append(line)
            }
        }
        return result
    }

    var body: some View {
        let shown = expanded ? groups : Array(groups.prefix(Self.visibleGroups))
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            ForEach(shown) { group in
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    if let title = group.title {
                        Text(title)
                            .looprTypography(.rowTitle)
                            .foregroundStyle(Color.loopr(.ink))
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array((expanded ? group.rows : Array(group.rows.prefix(Self.visibleRows))).enumerated()), id: \.offset) { _, row in
                        Text(row)
                            .looprTypography(.prose)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }
}
