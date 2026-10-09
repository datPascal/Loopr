import Foundation
import SwiftUI

/// Shared display precision for overnight readings and their personal comparisons.
public enum LooprSignalFormatting {
    public static func temperatureChange(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        return (abs(value) * 10).rounded() == 0 ? "0.0" : LooprUnitFormatter.signed(value, digits: 1)
    }

    public static func outsideRangeHeadline(count: Int) -> String {
        let word = [1: "One", 2: "Two", 3: "Three", 4: "Four"][count] ?? String(count)
        return "\(word) \(count == 1 ? "signal" : "signals") outside your usual range"
    }

    public static func comparison(change: Double?, unit: String, digits: Int) -> String? {
        guard let change, change.isFinite else { return nil }
        if (abs(change) * pow(10, Double(digits))).rounded() == 0 { return "Same as usual" }
        guard let signed = LooprUnitFormatter.signed(change, digits: digits) else { return nil }
        return "\(signed) \(unit) vs usual"
    }
}

/// The row's display model rejects incomplete numeric comparisons.
public struct LooprOvernightSignalRowModel: Equatable, Sendable {
    public let comparison: String?
    public init(comparison: String?) {
        let text = comparison?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.comparison = text.flatMap {
            guard !$0.isEmpty, !$0.lowercased().contains("vs usual") || $0.contains(where: \.isNumber) else { return nil }
            return $0
        }
    }
}

/// A metric link with its reading, comparison, usual-range marker and learning count.
/// Callers own their card padding; compact density fits Today's contributor card.
public struct LooprOvernightSignalRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var rangeWidth: CGFloat = 76
    private let title: String
    private let value: String?
    private let unit: String?
    private let comparison: String?
    private let range: LooprContributorRange?
    private let status: String?
    private let accent: LooprColorToken
    private let compact: Bool
    private let identifier: String
    private let action: (() -> Void)?

    public init(title: String, value: String?, unit: String?, comparison: String?,
                range: LooprContributorRange?, status: String?, accent: LooprColorToken,
                compact: Bool = false, identifier: String, action: (() -> Void)? = nil) {
        self.title = title; self.value = value; self.unit = unit; self.comparison = LooprOvernightSignalRowModel(comparison: comparison).comparison
        self.range = range; self.status = status; self.accent = accent
        self.compact = compact; self.identifier = identifier; self.action = action
    }

    public var accessibilitySummary: String {
        let reading = value.map { value in
            unit.map { "\(value) \(LooprUnitFormatter.spokenUnit($0))" } ?? value
        } ?? "No reading"
        return [title, reading, comparison, status].compactMap { $0 }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { content }.buttonStyle(.looprPressableRow)
            } else { content }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier(identifier)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            if dynamicTypeSize.isAccessibilitySize {
                titleView
                HStack(alignment: .firstTextBaseline) {
                    valueView
                    Spacer(minLength: LooprSpacing.xs)
                    if comparison == nil, let range {
                        rangeBar(range).frame(width: min(rangeWidth, 114))
                    }
                    if action != nil { LooprChevron() }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                    titleView
                    Spacer(minLength: LooprSpacing.xs)
                    valueView
                    if action != nil { LooprChevron() }
                }
            }
            if comparison != nil, dynamicTypeSize.isAccessibilitySize {
                comparisonView
                if let range { rangeBar(range) }
            } else if comparison != nil {
                HStack(spacing: LooprSpacing.sm) {
                    comparisonView
                    Spacer(minLength: LooprSpacing.xs)
                    if let range { rangeBar(range).frame(width: rangeWidth) }
                }
            }
            if comparison == nil, !dynamicTypeSize.isAccessibilitySize, let range {
                // Without a comparison line the bar sits under the value, on the status line.
                HStack(spacing: LooprSpacing.sm) {
                    statusView
                    Spacer(minLength: LooprSpacing.xs)
                    rangeBar(range).frame(width: rangeWidth)
                }
            } else {
                statusView
            }
        }
        .padding(.vertical, compact ? LooprSpacing.xs : LooprSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleView: some View {
        LooprText(title, style: compact ? .label : .rowTitle)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }
    private var valueView: some View {
        LooprText(value.map { $0 + (unit.map { " " + $0 } ?? "") } ?? "No reading",
                  style: .label, color: value == nil ? .inkSecondary : .ink)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var comparisonView: some View {
        if let comparison, !comparison.isEmpty {
            LooprText(comparison, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }
    @ViewBuilder private var statusView: some View {
        if let status, !status.isEmpty {
            LooprText(status, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }
    private func rangeBar(_ range: LooprContributorRange) -> some View {
        LooprTypicalRangeBar(value: range.value, typical: range.usual, domain: range.domain, accent: accent)
    }
}
