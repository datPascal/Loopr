import CoreTransferable
import DesignSystem
import DomainKit
import RoutineKit
import SwiftUI
import UniformTypeIdentifiers

/// The result file as the share sheet sees it: JSON, named after the experiment.
public struct ProtocolExperimentResultDocument: Transferable, Sendable {
    public let data: Data

    public init(file: ExperimentResultFile) throws {
        data = try ExperimentResultFileCodec.encode(file)
    }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { document in document.data }
            .suggestedFileName("Loopr experiment result.json")
    }
}

/// One experiment's result (contract phone p-result): the label, the result in words, the effect as the hero number with
/// its 95% range and nights on each side, the two groups with every counted night as a dot against the noise band, the design and the outcome, what else moved
/// (shown, never claimed), Keep and Share.
public struct ProtocolExperimentResultScreen: View {
    @ObservedObject private var model: ProtocolTabModel
    private let id: ExperimentID

    public init(model: ProtocolTabModel, id: ExperimentID) {
        self.model = model
        self.id = id
    }

    public var body: some View {
        Group {
            if let item = model.experiment(id) {
                ProtocolExperimentResultContent(model: model, item: item)
            } else {
                LooprText(ExperimentError.missingExperiment.errorDescription ?? "", style: .prose, color: .inkSecondary)
                    .padding(LooprSpacing.screenGutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityIdentifier("experiment-result-missing")
            }
        }
        .background {
            ZStack {
                Color.loopr(.background)
                LooprColorField(accent: .protocol)
            }
            .ignoresSafeArea()
        }
        .navigationTitle("Experiment")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.loopr(.protocol))
    }
}

private struct ProtocolExperimentResultContent: View {
    @ObservedObject var model: ProtocolTabModel
    let item: ProtocolExperimentItem
    @State private var revealed: Int?
    @State private var haptic: LooprHaptic?

    var body: some View {
        let presentation = ProtocolExperimentPresentation.make(item)
        let strip = ProtocolExperimentStrip.make(item, showsRange: true)
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(presentation.resultHeader, style: .label, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText(presentation.title, style: .titleLarge)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                hero(presentation, strip: strip)
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprText(presentation.measuresLine, style: .label, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ProtocolExperimentStripView(strip: strip, entranceKey: ProtocolExperimentEntrance.result,
                                                    revealed: $revealed)
                        // The band, the bracket and the statistics behind them, for the person who wants them
                        // (ICP R1-VET-12).
                        ProtocolExperimentHowItWorks(lines: [strip.likelyRangeCaption].compactMap { $0 } + presentation.howItWorks,
                                                     identifier: "experiment-result-how")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("experiment-result-groups")
                details(presentation)
                actions(presentation)
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .looprHaptic(haptic)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("experiment-result-screen")
    }

    private func hero(_ presentation: ProtocolExperimentPresentation, strip: ProtocolExperimentStrip) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            ProtocolExperimentLabelChip(presentation: presentation)
                .accessibilityIdentifier("experiment-result-label")
            // The result in words comes before the number and its unit (ICP R2-SEN-13).
            if let headline = presentation.headline {
                LooprText(headline, style: .cardTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("experiment-result-headline")
            }
            LooprHeroNumber(presentation.effect.map(Self.rounded), unit: presentation.unit.isEmpty ? nil : presentation.unit,
                            spokenUnit: presentation.unit == "min" ? "minutes" : nil,
                            prefix: (presentation.effect.map(Self.rounded) ?? 0) > 0 ? "+" : nil,
                            fractionDigits: Self.fractionDigits(presentation.effect), color: .protocol,
                            countUp: countUp(presentation, strip: strip), absentText: "No result")
                .accessibilityIdentifier("experiment-result-effect")
            if let range = presentation.rangeLine {
                // The effect never shows without its range and the nights behind it (ICP R1-VET-11).
                LooprText(range, style: .label, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(LooprSignedNumber.spoken(text: range))
                    .accessibilityIdentifier("experiment-result-range")
            }
            ProtocolExperimentCallText(call: presentation.resultCall)
                .accessibilityIdentifier("experiment-result-call")
            ProvenanceChip(.onThisPhone, qualifier: "your own nights", identifier: "experiment-result-source")
        }
    }

    private func details(_ presentation: ProtocolExperimentPresentation) -> some View {
        LooprCard(density: .flush) {
            VStack(spacing: LooprSpacing.none) {
                detailRow("Design", [presentation.designLine, presentation.washoutLine].compactMap { $0 }.joined(separator: ". "),
                          identifier: "experiment-result-design")
                LooprHairline()
                detailRow("Outcome", presentation.outcomeLine, identifier: "experiment-result-outcome")
                if let excluded = presentation.exclusionsLine {
                    LooprHairline()
                    detailRow("Left out", excluded, identifier: "experiment-result-left-out")
                }
                LooprHairline()
                detailRow("Also moved", alsoMovedText(presentation), identifier: "experiment-result-also-moved")
            }
        }
    }

    private func alsoMovedText(_ presentation: ProtocolExperimentPresentation) -> String {
        guard let moved = presentation.alsoMoved else { return ProtocolExperimentText.notChecked }
        return moved.isEmpty ? ProtocolExperimentText.nothingElseMoved : moved.joined(separator: " ")
    }

    private func detailRow(_ title: String, _ detail: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
            LooprText(title, style: .rowTitle)
            LooprText(detail, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func actions(_ presentation: ProtocolExperimentPresentation) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            if let version = presentation.keptVersion {
                HStack(spacing: LooprSpacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.loopr(.protocol))
                        .accessibilityHidden(true)
                    LooprText(ProtocolExperimentText.kept(version: version), style: .label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("experiment-result-kept")
            } else if presentation.canKeep {
                Button(ProtocolExperimentText.keep) { keep() }
                    .buttonStyle(LooprButtonStyle(accent: .protocol))
                    .disabled(model.isSaving)
                    .accessibilityHint("Adds this rule to the next version of your protocol.")
                    .accessibilityIdentifier("experiment-result-keep")
            } else if item.experiment.status != .running {
                LooprText(ProtocolExperimentText.notKeepable, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("experiment-result-keep-unavailable")
            }
            if let message = model.errorMessage {
                LooprInlineMessage(message, tone: .warning)
                    .accessibilityIdentifier("experiment-result-message")
            }
            if let file = item.resultFile, let document = try? ProtocolExperimentResultDocument(file: file) {
                ShareLink(item: document, preview: SharePreview("\(file.title) result")) {
                    Label(ProtocolExperimentText.share, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .protocol))
                .accessibilityIdentifier("experiment-result-share")
            }
        }
    }

    private func keep() {
        Task {
            if await model.keep(item.id) { haptic = .ruleKept }
        }
    }

    private func countUp(_ presentation: ProtocolExperimentPresentation, strip: ProtocolExperimentStrip) -> LooprCountUp? {
        guard let revealed, let effect = presentation.effect else { return nil }
        return LooprCountUp(from: 0, to: Self.rounded(effect), total: strip.dots.count, landed: revealed)
    }

    /// One decimal at most, as `ExperimentCopy.amount` writes it.
    static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    static func fractionDigits(_ value: Double?) -> Int {
        guard let value else { return 0 }
        let shown = rounded(value)
        return shown == shown.rounded() ? 0 : 1
    }
}
