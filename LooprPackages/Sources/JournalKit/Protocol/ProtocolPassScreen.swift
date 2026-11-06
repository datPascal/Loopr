import DesignSystem
import RoutineKit
import SwiftUI

// MARK: - Pass screen

/// Share protocol (contract phone p-share): the pass card, then "Share file" with the encoded file and "Open a pull
/// request on GitHub", which opens the community folder in Safari. The app makes no network request.
public struct ProtocolPassScreen: View {
    @ObservedObject private var model: ProtocolTabModel
    @State private var content: ProtocolPassContent?
    @State private var failed = false
    @Environment(\.openURL) private var openURL

    public init(model: ProtocolTabModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                if let content {
                    ProtocolPassCard(pass: content.pass)
                        .looprPressTilt()
                    VStack(spacing: LooprSpacing.sm) {
                        ShareLink(item: content.document, preview: SharePreview(content.pass.fileName)) {
                            Label(ProtocolRulesText.shareFile, systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LooprButtonStyle(accent: .protocol))
                        .accessibilityHint("Shares \(content.pass.fileName), \(ProtocolPass.sizeText(content.pass.byteCount)).")
                        .accessibilityIdentifier("protocol-pass-share")
                        Button {
                            openURL(ProtocolCommunity.repositoryURL)
                        } label: {
                            Label(ProtocolRulesText.openPullRequest, systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .protocol))
                        .accessibilityHint("Opens the community folder in Safari. Add your file there with a pull request.")
                        .accessibilityIdentifier("protocol-pass-github")
                    }
                } else if failed {
                    LooprInlineMessage(model.rulesErrorMessage ?? "Loopr could not make the file.", tone: .warning)
                } else {
                    LooprSkeleton(height: 420).accessibilityLabel("Making the file")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.vertical, LooprSpacing.md)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-pass")
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack {
                Color.loopr(.background)
                LooprColorField(accent: .protocol)
            }
            .ignoresSafeArea()
        }
        .navigationTitle(ProtocolRulesText.shareTitle)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.loopr(.protocol))
        .task {
            content = await model.passContent()
            failed = content == nil
        }
    }
}

/// The pass: header, name, byline, the rosette of its rules, the counts, a perforation, the file line and its
/// fingerprint. The rosette is the card's one object.
struct ProtocolPassCard: View {
    let pass: ProtocolPass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            HStack(spacing: LooprSpacing.xs) {
                ProtocolRosetteOutline(count: 6, size: 22)
                LooprText(pass.header, style: .label, color: .inkSecondary)
                Spacer(minLength: LooprSpacing.xs)
                LooprText(pass.versionText, style: .metricValue, color: .protocolChip)
                    .accessibilityLabel("Version \(pass.version)")
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(pass.name, style: .titleLarge)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let byline = pass.byline {
                    LooprText(byline, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ProtocolPassRosette(groups: pass.groups)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(pass.rosetteAccessibilityLabel)
                .accessibilityIdentifier("protocol-pass-rosette")
            counts
            Line()
                .stroke(Color.loopr(.divider), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                LooprText(pass.fileName, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(pass.fileDetail, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("protocol-pass-file")
            fingerprint
        }
        .padding(LooprSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground(.hero(.protocol))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-pass-card")
    }

    /// The fingerprint as text, with a row of dots beside it and a caption under it.
    private var fingerprint: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
                : AnyLayout(HStackLayout(alignment: .center, spacing: LooprSpacing.md))
            layout {
                LooprText(pass.fingerprint.text, style: .metricValue)
                    .monospaced()
                    .fixedSize()
                ProtocolPassFingerprintDots(levels: pass.fingerprint.levels)
            }
            LooprText(ProtocolPassFingerprint.caption, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pass.fingerprint.accessibilityLabel)
        .accessibilityHint(ProtocolPassFingerprint.caption)
        .accessibilityIdentifier("protocol-pass-fingerprint")
    }

    private var counts: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: LooprSpacing.md))
        return VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            layout {
                count("Rules", "\(pass.ruleCount)")
                count("Experiments", "\(pass.experimentCount)")
            }
            // One sentence with its week and its checks, so nobody reads the share as a record (ICP R2-VET-11).
            LooprText(pass.keptLine, style: .rowTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("protocol-pass-kept")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pass.countsAccessibilityLabel)
        .accessibilityIdentifier("protocol-pass-counts")
    }

    private func count(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
            LooprText(title, style: .caption, color: .inkSecondary)
            LooprText(value, style: .metricValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// One dot per rule (16 at most), in the Protocol accent with a shade per group, on the tab's rosette layout.
struct ProtocolPassRosette: View {
    let groups: [RuleGroup]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.36
            let shown = Array(groups.prefix(ProtocolRosetteRules.maximumDots))
            let ring = Path(ellipseIn: CGRect(x: center.x - radius * 1.32, y: center.y - radius * 1.32,
                                              width: radius * 2.64, height: radius * 2.64))
            context.stroke(ring, with: .color(Color.loopr(.protocol).opacity(0.25)), lineWidth: 1)
            guard !shown.isEmpty else {
                for point in ProtocolRosetteLayout.positions(count: 8, center: center, radius: radius) {
                    let dot = ProtocolRosetteLayout.dotRadius(count: 8, radius: radius)
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)),
                                   with: .color(Color.loopr(.inkMuted)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                return
            }
            let dot = ProtocolRosetteLayout.dotRadius(count: shown.count, radius: radius)
            let dark = LooprAppearance.isDark(colorScheme)
            for (group, point) in zip(shown, ProtocolRosetteLayout.positions(count: shown.count, center: center, radius: radius)) {
                let rect = CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)
                let color = Color.loopr(.protocol).opacity(Self.shade(group))
                if dark {
                    var glow = context
                    glow.addFilter(.blur(radius: 4))
                    glow.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.5)))
                }
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: 168, height: 168)
    }

    static func shade(_ group: RuleGroup) -> Double {
        switch group {
        case .sleep: 1
        case .food: 0.82
        case .fitness: 0.68
        case .supplements: 0.56
        case .tests: 0.46
        case .custom: 0.38
        }
    }
}

/// The fingerprint's dots: one round dot per hex pair on a single line, in four sizes and the Protocol accent. One row of
/// circles with no finder squares or grid, so nobody mistakes it for a code to scan.
struct ProtocolPassFingerprintDots: View {
    let levels: [Int]
    static let pitch: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            for (index, level) in levels.enumerated() {
                let radius = 2.5 + CGFloat(min(max(level, 0), 3)) * 1.25
                let x = Self.pitch / 2 + CGFloat(index) * Self.pitch
                let rect = CGRect(x: x - radius, y: midY - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Color.loopr(.protocol).opacity(0.45 + Double(level) * 0.18)))
            }
        }
        .frame(width: Self.pitch * CGFloat(max(levels.count, 1)), height: Self.pitch)
        .accessibilityHidden(true)
    }
}

// MARK: - Import review

/// A valid file before it is used: its name, author and rules, and what it changes against the newest version.
/// "Use this protocol" saves the next version; Cancel saves nothing.
struct ProtocolImportReviewSheet: View {
    @ObservedObject var model: ProtocolTabModel
    let review: ProtocolImportReview
    let used: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(review.name, style: .titleLarge)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        if let byline = review.byline {
                            LooprText(byline, style: .caption, color: .inkSecondary)
                        }
                        LooprText("Version \(review.preview.file.version) of the file", style: .caption, color: .inkSecondary)
                    }
                    LooprText(review.headline, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("protocol-import-headline")
                    if !review.changeLines.isEmpty {
                        LooprSectionGroup(title: "What changes") {
                            LooprCard {
                                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                                    ForEach(review.changeLines, id: \.self) { line in
                                        LooprText(line, style: .prose)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("protocol-import-changes")
                        }
                    }
                    LooprSectionGroup(title: "\(review.rows.count) \(review.rows.count == 1 ? "rule" : "rules")") {
                        LooprCard(density: .flush) {
                            VStack(spacing: LooprSpacing.none) {
                                ForEach(Array(review.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { LooprHairline() }
                                    ProtocolReadOnlyRuleRow(row: row)
                                }
                            }
                        }
                    }
                    LooprText("Files carry rules and experiment designs only. Your check history and your own reasons stay as they are.",
                              style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = model.importError {
                        LooprInlineMessage(message, tone: .warning)
                    }
                    Button(ProtocolRulesText.useFile) {
                        Task {
                            if await model.useImport() { used(); dismiss() }
                        }
                    }
                    .buttonStyle(LooprButtonStyle(accent: .protocol))
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("protocol-import-use")
                }
                .padding(LooprSpacing.screenGutter)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("protocol-import-review")
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Open protocol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.dismissImport(); dismiss() }
                        .accessibilityIdentifier("protocol-import-cancel")
                }
            }
        }
        .tint(Color.loopr(.protocol))
    }
}

extension ProtocolPass {
    /// "Kept 92% this week, 13 checks". Before the share shows (day 3), "2 checks this week"; with none, "No answers
    /// this week yet".
    var keptLine: String {
        let checks = checkCount.map { "\($0) \($0 == 1 ? "check" : "checks")" }
        switch (keptPercent, checks) {
        case let (percent?, checks?): return "Kept \(percent)% this week, \(checks)"
        case let (percent?, nil): return "Kept \(percent)% this week"
        case let (nil, checks?) where checkCount ?? 0 > 0: return "\(checks) this week"
        default: return "No answers this week yet"
        }
    }
}
