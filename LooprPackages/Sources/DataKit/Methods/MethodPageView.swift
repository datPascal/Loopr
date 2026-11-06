import DesignSystem
import SwiftUI

/// The method page for one number family (contract p-method, DEC-12.20): the value, the plain sentence, what moved it,
/// how it works, the formula, the code, the tests, the inputs, the limits and the paper.
///
/// `howItWorks` replaces the catalog's rule when the app has its own text for a metric (the metric catalog), so the
/// words are written once. `furtherReading` adds that catalog's short citations under the paper.
public struct MethodPageView: View {
    @Environment(\.openURL) private var openURL
    private let entry: MethodEntry
    private let value: MethodPageValue?
    private let howItWorks: [String]
    private let furtherReading: [String]
    private let accent: LooprColorToken

    public init(entry: MethodEntry, value: MethodPageValue? = nil, howItWorks: [String]? = nil, furtherReading: [String] = [],
                accent: LooprColorToken = .brand) {
        self.entry = entry
        self.value = value
        self.howItWorks = howItWorks ?? entry.rule
        self.furtherReading = furtherReading
        self.accent = accent
    }

    public var body: some View {
        ZStack {
            LooprColorField(accent: accent)
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                    hero
                    if let waterfall = value?.waterfall { section("What moved it", detail: waterfall.detail) { waterfallView(waterfall) } }
                    if !howItWorks.isEmpty { section("How it works") { paragraphs(howItWorks, identifier: "method-rule") } }
                    if let formula = entry.formula {
                        section("The formula") {
                            LooprFormula(lines: formula.lines, caption: formula.caption, accent: accent, identifier: "method-formula")
                        }
                    }
                    if let readings = value?.inputs {
                        section("Inputs", detail: "The values this result used") { inputReadings(readings) }
                    } else {
                        section("Inputs") { inputs }
                    }
                    // The plain parts first, the code and its tests last, for whoever wants to check them (ICP R2-LAB-21).
                    section("Limits") { paragraphs(entry.limits, identifier: "method-limits") }
                    section(entry.isLooprOwnMethod ? "The method" : "The paper") { paper }
                    if let primary = entry.sources.first { section("The code", detail: "For checking · MIT licence") { code(primary) } }
                    section("Test cases", detail: "The suites that check this method") { tests }
                    if entry.showsMedicalLine {
                        LooprCard(style: .sunk) {
                            LooprText(MethodCatalog.medicalLine, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("method-medical")
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.tabBarClearance)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("method-\(entry.id.rawValue)")
            }
            .accessibilityIdentifier("method-screen")
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Method")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(eyebrow, style: .sectionLabel, color: accent.textInk)
            if let value {
                LooprHeroNumber(value.value, unit: entry.unit, fractionDigits: value.fractionDigits, style: .heroNumeralXXL,
                                color: accent)
                    .accessibilityIdentifier("method-value")
                ProvenanceChip(value.provenance, qualifier: value.qualifier, identifier: "method-value-source")
            } else {
                LooprText(entry.title, style: .titleLarge)
                    .accessibilityAddTraits(.isHeader)
            }
            LooprText(entry.summary, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("method-summary")
        }
    }

    private var eyebrow: String {
        guard let version = entry.version else { return entry.eyebrow }
        return entry.eyebrow + " · " + version.value
    }

    private func waterfallView(_ waterfall: MethodWaterfall) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            let digits = waterfall.fractionDigits
            // How to read the bars comes before them, so no bar is read as years gained or lost on its own.
            LooprText(waterfall.note, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("method-waterfall-note")
            LooprWaterfall(model: waterfall.model, startLabel: waterfall.startLabel,
                           increaseLabel: waterfall.increaseLabel, decreaseLabel: waterfall.decreaseLabel,
                           valueFormat: { LooprSignedNumber.text($0, fractionDigits: digits, plus: false) },
                           identifier: "method-waterfall")
        }
    }

    private var inputs: some View {
        LooprCard(density: .flush) {
            VStack(alignment: .leading, spacing: LooprSpacing.none) {
                ForEach(Array(entry.inputs.enumerated()), id: \.offset) { index, input in
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            LooprText(input.name, style: .rowTitle)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: LooprSpacing.xs)
                            if let unit = input.unit {
                                Text(unit)
                                    .looprTypography(.caption)
                                    .foregroundStyle(Color.loopr(.inkSecondary))
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: LooprSpacing.xxs) { chips(input) }
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) { chips(input) }
                        }
                    }
                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                    .padding(.vertical, LooprSpacing.sm)
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    if index < entry.inputs.count - 1 {
                        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                            .padding(.leading, LooprSpacing.cardHorizontal)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityIdentifier("method-inputs")
    }

    /// The person's own inputs: value and unit, the one source it came from, and the day (ICP R1-LAB-9).
    private func inputReadings(_ readings: [MethodInputReading]) -> some View {
        LooprCard(density: .flush) {
            VStack(alignment: .leading, spacing: LooprSpacing.none) {
                ForEach(Array(readings.enumerated()), id: \.offset) { index, reading in
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(reading.name, style: .rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: reading.value)
                            .looprTypography(.label)
                            .monospacedDigit()
                            .foregroundStyle(Color.loopr(.ink))
                            .fixedSize(horizontal: false, vertical: true)
                        if let provenance = reading.provenance {
                            ProvenanceChip(provenance, qualifier: reading.note)
                        } else if let note = reading.note {
                            LooprText(note, style: .caption, color: .inkSecondary)
                        }
                    }
                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                    .padding(.vertical, LooprSpacing.sm)
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("method-input-\(index + 1)")
                    if index < readings.count - 1 {
                        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                            .padding(.leading, LooprSpacing.cardHorizontal)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityIdentifier("method-inputs")
    }

    private func chips(_ input: MethodInput) -> some View {
        ForEach(Array(input.sources.enumerated()), id: \.offset) { _, source in
            ProvenanceChip(source.provenance, qualifier: chipQualifier(source))
        }
    }

    /// The chip already names band, Apple Health, Food and typed sources. Other sources say what they are.
    private func chipQualifier(_ source: MethodInputSource) -> String? {
        switch source {
        case .phoneTimer: "timer"
        case .protocolRules: "your protocol"
        case .computed(let from): from
        default: nil
        }
    }

    private func code(_ primary: MethodSourceFile) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprCodeCard(path: primary.path, lines: primary.lines, rows: codeRows(primary), actionTitle: "View on GitHub",
                          identifier: "method-code", actionIdentifier: "method-github") { openURL(primary.gitHubURL) }
            if entry.sources.count > 1 {
                LooprCard(density: .flush) {
                    VStack(alignment: .leading, spacing: LooprSpacing.none) {
                        ForEach(Array(entry.sources.dropFirst().enumerated()), id: \.offset) { index, source in
                            LooprNavigationRow(title: source.symbol,
                                               caption: "\(source.fileName) · \(LooprCodeCardFormat.lineLabel(source.lines))",
                                               accessibilityLabel: "\(source.symbol), \(source.fileName), \(LooprCodeCardFormat.lineLabel(source.lines)). Opens GitHub.",
                                               identifier: "method-github-\(index + 2)",
                                               showsDivider: index < entry.sources.count - 2) { openURL(source.gitHubURL) }
                        }
                    }
                }
            }
        }
    }

    private func codeRows(_ primary: MethodSourceFile) -> [LooprCodeCardRow] {
        var rows = [LooprCodeCardRow("Function", primary.symbol)]
        if let version = entry.version {
            rows.append(LooprCodeCardRow("Version", version.value))
            rows.append(LooprCodeCardRow("Version constant", version.symbol))
        } else {
            rows.append(LooprCodeCardRow("Version", "No version constant yet"))
        }
        return rows
    }

    private var tests: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                if entry.testSuites.isEmpty {
                    LooprText("No test suite names this method yet.", style: .body, color: .inkSecondary)
                } else {
                    ForEach(entry.testSuites, id: \.self) { suite in
                        VStack(alignment: .leading, spacing: LooprSpacing.none) {
                            Text(suite.name)
                                .looprTypography(.label)
                                .foregroundStyle(Color.loopr(.ink))
                            LooprText((suite.path as NSString).lastPathComponent, style: .caption, color: .inkSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityIdentifier("method-tests")
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            if entry.isLooprOwnMethod {
                LooprCard {
                    LooprText(MethodCatalog.ownMethodLine, style: .body, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(entry.references.enumerated()), id: \.offset) { index, reference in
                referenceCard(reference, index: index)
            }
            if !furtherReading.isEmpty {
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText("Also cited on the metric page", style: .label)
                        ForEach(furtherReading, id: \.self) { LooprText($0, style: .caption, color: .inkSecondary) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("method-paper")
    }

    private func referenceCard(_ reference: MethodReference, index: Int) -> some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprText(kindLabel(reference.kind), style: .overline, color: accent.textInk)
                LooprText(reference.title, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText([reference.citation, reference.venue].joined(separator: ". "), style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(reference.use, style: .body)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = reference.link {
                    LooprGlassButton("Open", symbol: "arrow.up.right", identifier: "method-paper-link-\(index + 1)") { openURL(link) }
                }
            }
        }
    }

    private func kindLabel(_ kind: MethodReference.Kind) -> String {
        switch kind {
        case .paper: "Paper"
        case .background: "Background"
        case .implementation: "Open-source code"
        case .data: "Data source"
        }
    }

    private func paragraphs(_ lines: [String], identifier: String) -> some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                ForEach(lines, id: \.self) { line in
                    LooprText(line, style: .body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func section<Content: View>(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: detail, accent: accent)
            content()
        }
    }
}
