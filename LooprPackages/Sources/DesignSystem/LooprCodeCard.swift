import SwiftUI

/// One labelled line inside a code card, such as "Function" and `evaluate`.
public struct LooprCodeCardRow: Hashable, Sendable, Identifiable {
    public let label: String
    public let value: String

    public var id: String { label + value }

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// How a code card writes a line range.
public enum LooprCodeCardFormat {
    /// "Lines 187 to 215", or "Line 12" for a single line.
    public static func lineLabel(_ lines: ClosedRange<Int>) -> String {
        (lines.count == 1 ? "Line " : "Lines ") + rangeText(lines)
    }

    /// "187 to 215", or "12" for a single line.
    public static func rangeText(_ lines: ClosedRange<Int>) -> String {
        lines.lowerBound == lines.upperBound ? "\(lines.lowerBound)" : "\(lines.lowerBound) to \(lines.upperBound)"
    }

    /// The GitHub fragment for the range: `#L187-L215`, or `#L12` for a single line.
    public static func fragment(_ lines: ClosedRange<Int>) -> String {
        lines.lowerBound == lines.upperBound ? "#L\(lines.lowerBound)" : "#L\(lines.lowerBound)-L\(lines.upperBound)"
    }
}

/// A source file shown as a card: the path in a title bar, a few labelled lines (the line range,
/// the function, the version) and one action that opens the file on GitHub.
///
/// The card names the code; it does not copy it. Someone who never reads Swift can see which file
/// and which lines make the number, and open them.
///
/// ```swift
/// LooprCodeCard(path: "LooprPackages/Sources/AnalyticsKit/Age/PhenoAge.swift", lines: 187...215,
///               rows: [.init("Function", "evaluate"), .init("Version", "loopr.phenoage.1")],
///               actionTitle: "View on GitHub", identifier: "method-code",
///               actionIdentifier: "method-github") { openURL(url) }
/// ```
///
/// - The path wraps at its slashes rather than truncating, so the file name is always visible.
/// - The action is a 56 pt glass pill; Reduce Transparency gives it a solid fill.
public struct LooprCodeCard: View {
    private let path: String
    private let lines: ClosedRange<Int>
    private let rows: [LooprCodeCardRow]
    private let actionTitle: String
    private let identifier: String
    private let actionIdentifier: String
    private let action: () -> Void

    public init(path: String, lines: ClosedRange<Int>, rows: [LooprCodeCardRow] = [], actionTitle: String,
                identifier: String, actionIdentifier: String, action: @escaping () -> Void) {
        self.path = path
        self.lines = lines
        self.rows = rows
        self.actionTitle = actionTitle
        self.identifier = identifier
        self.actionIdentifier = actionIdentifier
        self.action = action
    }

    public var body: some View {
        LooprCard(density: .flush) {
            VStack(alignment: .leading, spacing: LooprSpacing.none) {
                titleBar
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(height: LooprSpacing.hairline)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    row(LooprCodeCardRow(lines.count == 1 ? "Line" : "Lines", LooprCodeCardFormat.rangeText(lines)))
                    ForEach(rows) { row($0) }
                }
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.vertical, LooprSpacing.md)
                LooprGlassButton(actionTitle, symbol: "arrow.up.right", identifier: actionIdentifier, action: action)
                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                    .padding(.bottom, LooprSpacing.md)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var titleBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            HStack(spacing: LooprSpacing.xxs) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.loopr(.inkMuted))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Text(Self.breakable(path))
                .looprTypography(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(.ink))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Source file \(path)")
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.loopr(.surfaceSunk).opacity(0.6))
    }

    private func row(_ row: LooprCodeCardRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                label(row)
                Spacer(minLength: LooprSpacing.sm)
                value(row)
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                label(row)
                value(row)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func label(_ row: LooprCodeCardRow) -> some View {
        LooprText(row.label, style: .caption, color: .inkSecondary)
    }

    private func value(_ row: LooprCodeCardRow) -> some View {
        Text(row.value)
            .looprTypography(.label)
            .monospacedDigit()
            .foregroundStyle(Color.loopr(.ink))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The path with a zero-width space after each slash, so it wraps between folders.
    static func breakable(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "/\u{200B}")
    }
}
