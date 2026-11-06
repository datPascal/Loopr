import AIKit
import DesignSystem
import DomainKit
import JournalKit
import SwiftUI

/// Mockup 17. Segments for Testing, Found and Dismissed over one scrolling page. Everything here is composed
/// from existing DesignSystem parts.
struct PatternsScreen: View {
    @ObservedObject var model: PatternsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprChoiceControl(
                    "Patterns view", choices: PatternsSegment.allCases.map { LooprChoice($0.rawValue, title: $0.title) },
                    selection: model.segment.rawValue, accent: .brand, identifier: "patterns-segments",
                    onSelect: { @MainActor @Sendable id in
                        if let id, let segment = PatternsSegment(rawValue: id) { model.segment = segment }
                    })
                if let message = model.message {
                    LooprInlineMessage(message, tone: .warning).accessibilityIdentifier("patterns-message")
                }
                if model.isLoading {
                    LooprSkeleton(height: 160).accessibilityIdentifier("patterns-loading")
                } else {
                    switch model.segment {
                    case .testing: testing
                    case .found: found
                    case .dismissed: dismissed
                    }
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(PatternsCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("patterns-screen")
        .task { await model.load() }
        .sheet(item: $model.selected) { pattern in
            PatternDetailSheet(pattern: pattern, model: model)
        }
        .sheet(item: $model.consentModel, onDismiss: { Task { await model.consentClosed() } }) { consent in
            NavigationStack {
                CoachPreferencesScreen(model: consent, startsMorningReview: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { model.consentModel = nil }.accessibilityIdentifier("patterns-consent-close")
                        }
                    }
            }
            .accessibilityIdentifier("patterns-consent-sheet")
        }
    }

    // MARK: Testing

    @ViewBuilder private var testing: some View {
        // A protocol experiment runs on the same nights, so the tab names it instead of saying nothing runs (R3-OPT-8).
        if let experiment = model.runningExperiment { runningExperimentCard(experiment) }
        if model.snapshot.tests.isEmpty {
            if model.runningExperiment == nil { emptyCard(PatternCopy.testingEmpty, identifier: "patterns-testing-empty") }
        } else {
            ForEach(model.snapshot.tests.prefix(3)) { test in
                PatternTestCard(test: test, progress: model.progress(of: test), verdict: model.verdicts[test.id], model: model)
            }
        }
        if !model.snapshot.found.isEmpty {
            foundSection
        }
        if let review = model.snapshot.review { reviewSection(review) }
        settingsCard
    }

    // MARK: Found

    @ViewBuilder private var found: some View {
        if model.snapshot.found.isEmpty {
            emptyCard(PatternCopy.foundEmpty, identifier: "patterns-found-empty")
        } else {
            foundSection
        }
        LooprText(PatternCopy.footnote, style: .prose, color: .inkSecondary)
            .padding(.horizontal, LooprSpacing.xxs)
            .accessibilityIdentifier("patterns-footnote")
    }

    private var foundSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(PatternsCopy.foundHeader, detail: PatternsCopy.foundDetail, identifier: "patterns-found-header")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    ForEach(Array(model.snapshot.found.enumerated()), id: \.element.key) { index, pattern in
                        Button { model.selected = pattern } label: {
                            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                    LooprText(PatternsCopy.headline(pattern), style: .rowTitle)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                    LooprText(PatternsCopy.caption(pattern).looprLabelCased, style: .headerMeta, color: .inkMuted)
                                }
                                Spacer(minLength: LooprSpacing.sm)
                                LooprChevron()
                            }
                            .padding(.horizontal, LooprSpacing.cardHorizontal)
                            .padding(.vertical, LooprSpacing.metricRowVertical)
                            .frame(minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityLabel("\(PatternsCopy.headline(pattern)), \(PatternsCopy.caption(pattern))")
                        .accessibilityHint("Opens the pattern")
                        .accessibilityIdentifier("patterns-found-row-\(index)")
                        if index < model.snapshot.found.count - 1 {
                            LooprHairline().padding(.horizontal, LooprSpacing.cardHorizontal)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("patterns-found-list")
            if model.snapshot.found.contains(where: { ProtocolExperimentText.mentionsHRV(PatternsCopy.headline($0)) }) {
                LooprText(ProtocolExperimentText.hrvGloss, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LooprSpacing.xxs)
                    .accessibilityIdentifier("patterns-hrv-gloss")
            }
        }
    }

    // MARK: Dismissed

    @ViewBuilder private var dismissed: some View {
        if model.snapshot.dismissed.isEmpty {
            emptyCard(PatternCopy.dismissedEmpty, identifier: "patterns-dismissed-empty")
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader(PatternsCopy.dismissedHeader, detail: PatternsCopy.dismissedNote, identifier: "patterns-dismissed-header")
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.snapshot.dismissed.enumerated()), id: \.element.key) { index, item in
                            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                    LooprText(PatternsCopy.headline(item.evidence), style: .rowTitle)
                                        .fixedSize(horizontal: false, vertical: true)
                                    LooprText(PatternsCopy.dismissedCaption(item, timeZone: model.timeZone).looprLabelCased, style: .headerMeta, color: .inkMuted)
                                }
                                Spacer(minLength: LooprSpacing.sm)
                                Button(PatternsCopy.restore) { Task { await model.restore(key: item.key) } }
                                    .buttonStyle(LooprButtonStyle(prominent: false))
                                    .frame(width: 104)
                                    .accessibilityLabel("Show again: \(PatternsCopy.headline(item.evidence))")
                                    .accessibilityIdentifier("patterns-restore-\(index)")
                            }
                            .padding(.horizontal, LooprSpacing.cardHorizontal)
                            .padding(.vertical, LooprSpacing.metricRowVertical)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("patterns-dismissed-row-\(index)")
                            if index < model.snapshot.dismissed.count - 1 {
                                LooprHairline().padding(.horizontal, LooprSpacing.cardHorizontal)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func runningExperimentCard(_ experiment: PatternsRunningExperiment) -> some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                if let night = experiment.nightLine {
                    StatusChip(night, symbol: "flask", tone: .brand)
                }
                LooprText(experiment.title, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(experiment.testingLine, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("patterns-testing-experiment")
    }

    private func emptyCard(_ text: String, identifier: String) -> some View {
        LooprCard {
            LooprText(text, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(identifier)
    }

    private func reviewSection(_ review: WeeklyReview) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(PatternsCopy.reviewHeader, identifier: "patterns-review-header")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText(PatternsCopy.reviewDate(review).looprLabelCased, style: .headerMeta, color: .inkSecondary)
                    LooprText(PatternsCopy.display(review.text), style: .settingsRow)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("patterns-weekly-review")
        }
    }

    private var settingsCard: some View {
        LooprCard(density: .flush) {
            VStack(spacing: 0) {
                LooprToggleRow(
                    title: PatternsCopy.morningTitle, subtitle: PatternsCopy.morningSubtitle, accent: .brand,
                    identifier: "patterns-morning-toggle",
                    isOn: Binding(get: { @MainActor @Sendable in model.morningOn },
                                  set: { @MainActor @Sendable on in Task { await model.setMorning(on) } }))
                LooprHairline().padding(.horizontal, LooprSpacing.formCardPadding)
                LooprToggleRow(
                    title: PatternsCopy.discoveryTitle, subtitle: PatternsCopy.discoverySubtitle, accent: .brand,
                    identifier: "patterns-discovery-toggle",
                    isOn: Binding(get: { @MainActor @Sendable in model.snapshot.settings.lookForNewPatterns },
                                  set: { @MainActor @Sendable on in Task { await model.setDiscovery(on) } }))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("patterns-settings-card")
    }
}

/// The tinted card that leads the Testing segment.
struct PatternTestCard: View {
    let test: PatternTest
    let progress: PatternTestProgress
    let verdict: PatternTestVerdict?
    @ObservedObject var model: PatternsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        LooprCard(style: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                HStack {
                    StatusChip(PatternsCopy.dayChip(progress, test: test), symbol: "flask", tone: .brand)
                        .accessibilityIdentifier("patterns-test-day")
                    Spacer(minLength: LooprSpacing.sm)
                    StatusChip(PatternsCopy.onDevice, symbol: "iphone", tone: .brand)
                        .accessibilityIdentifier("patterns-test-device")
                }
                LooprText(PatternsCopy.title(test), style: .titleLarge)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("patterns-test-title")
                HStack(alignment: .top, spacing: LooprSpacing.xl) {
                    metric(PatternsCopy.nowLabel(test.outcomeMetric), value: verdict?.nowMean, color: .ink)
                    metric("Before", value: verdict?.beforeMean, color: .inkSecondary)
                }
                LooprLinearProgress(value: Double(progress.dayNumber), target: Double(test.testDays), accent: .brand)
                    .accessibilityIdentifier("patterns-test-progress")
                LooprText(PatternsCopy.status(test: test, progress: progress, verdict: verdict), style: .settingsRow, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("patterns-test-status")
                if test.state == .running, test.reminderProblem == .notAllowed {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .accessibilityIdentifier("patterns-open-ios-settings")
                }
                if test.state == .running {
                    actions
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("patterns-test-card")
    }

    private func metric(_ label: String, value: Double?, color: LooprColorToken) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(label.looprLabelCased, style: .headerMeta, color: .inkMuted)
            if let value {
                LooprValueText(PatternCopy.amount(value), unit: PatternsCopy.unit(test.outcomeMetric.unit),
                               valueStyle: .metric, color: color)
            } else {
                LooprText("Not enough nights", style: .prose, color: .inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        let today = test.today(at: model.now).flatMap { progress.days[$0] }
        VStack(spacing: LooprSpacing.xs) {
            if today == .pending {
                Button(PatternsCopy.keepToday) { Task { await model.keepToday(test) } }
                    .buttonStyle(LooprButtonStyle(accent: .brandInk))
                    .accessibilityIdentifier("patterns-keep-today")
            }
            Button(PatternsCopy.stopTest) { Task { await model.stop(test) } }
                .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                .accessibilityIdentifier("patterns-stop-test")
        }
    }
}

/// One found pattern in detail, with the two things a person can do with it. The nights on each side and the likely
/// range stand where "Strong" stood (ICP R1-VET-13). Try says why it cannot start while another experiment runs, and
/// Not now says what it does (ICP R1-DES-11, R1-SEN-20).
struct PatternDetailSheet: View {
    let pattern: FoundPattern
    @ObservedObject var model: PatternsModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    LooprText(PatternsCopy.headline(pattern), style: .titleLarge)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("patterns-detail-title")
                    if ProtocolExperimentText.mentionsHRV(PatternsCopy.headline(pattern)) {
                        LooprText(ProtocolExperimentText.hrvGloss, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("patterns-detail-hrv-gloss")
                    }
                    LooprText(PatternsCopy.display(pattern.summary), style: .settingsRow)
                        .fixedSize(horizontal: false, vertical: true)
                    // The rule the check-in's pattern line is about, which the line itself leaves out (ICP R4 Q7).
                    if let rule = model.ruleLine(for: pattern) {
                        LooprText(rule, style: .label, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("patterns-detail-rule")
                    }
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(pattern.nightsLabel, style: .label)
                            .fixedSize(horizontal: false, vertical: true)
                        if let range = PatternsCopy.likelyRange(pattern) {
                            LooprText(range, style: .label, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let spread = PatternsCopy.usualSpread(pattern) {
                            LooprText(spread, style: .label, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("patterns-detail-spread")
                        }
                        if let threshold = PatternsCopy.threshold(pattern) {
                            LooprText(threshold, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("patterns-detail-evidence")
                    LooprText(PatternCopy.footnote, style: .prose, color: .inkSecondary)
                    if let reason = model.blockingReason {
                        LooprInlineMessage(reason, tone: .neutral)
                            .accessibilityIdentifier("patterns-detail-busy")
                    }
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        Button(PatternsCopy.tryFor14Days) {
                            Task { await model.start(pattern) }
                        }
                        // A darker teal carries white text, which reads at 4.5:1 or better (ICP R1-SEN-20). While
                        // another test runs, the button is the quiet tinted style, so it does not look like it acts
                        // (ICP R2-DES-13).
                        .buttonStyle(LooprButtonStyle(prominent: model.blockingReason == nil, accent: .brandInk))
                        .disabled(model.blockingReason != nil)
                        .accessibilityHint(model.blockingReason ?? "Starts a 14-day test of this habit.")
                        .accessibilityIdentifier("patterns-detail-try")
                        Button(PatternsCopy.dismiss) { Task { await model.dismiss(pattern) } }
                            .buttonStyle(LooprButtonStyle(prominent: false, accent: .brandInk))
                            .accessibilityHint(PatternsCopy.dismissNote)
                            .accessibilityIdentifier("patterns-detail-dismiss")
                        LooprText(PatternsCopy.dismissNote, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                    }
                    .padding(.top, LooprSpacing.sm)
                }
                .padding(LooprSpacing.screenGutter)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Pattern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { model.selected = nil }.accessibilityIdentifier("patterns-detail-close")
                }
            }
        }
        .presentationDetents([.large])  // Opens full height, so Try for 14 days is on screen (ICP R2-OPT-15).
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("patterns-detail")
    }
}

extension CoachChatViewModel: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}
