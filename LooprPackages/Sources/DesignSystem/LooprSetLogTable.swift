import SwiftUI

/// Where a set stands in the log.
public enum LooprSetLogStatus: Sendable, Equatable {
    /// Done and recorded. Shows a check.
    case logged
    /// The set being worked on now. Its number is in the accent.
    case current
    /// Not reached yet.
    case planned
    /// The person skipped it. It counts for nothing, shows no load or reps, and can be logged later.
    case skipped
}

/// One row in a `LooprSetLogTable`.
public struct LooprSetLogRow: Identifiable, Equatable, Sendable {
    public let number: Int
    /// The load as text, without the unit: "80".
    public let weight: String
    public let reps: String
    /// RPE as text: "7" or "8.5". Nil when none was recorded.
    public let rpe: String?
    public let status: LooprSetLogStatus
    /// One letter shown in place of the set number, such as "W" for a warm-up. Nil for a working set.
    public let tag: String?
    /// What the tag letter means, for VoiceOver: "warm-up".
    public let spokenTag: String?
    /// A short mark after the values, such as "PR" once the set beat a best.
    public let badge: String?
    /// What VoiceOver reads for the load and reps, when the columns hold something other than kilograms
    /// and reps: "45 seconds" or "20 kilograms of assistance, 8 reps".
    public let spokenValues: String?

    public var id: Int { number }

    public init(number: Int, weight: String, reps: String, rpe: String? = nil, status: LooprSetLogStatus,
                tag: String? = nil, spokenTag: String? = nil, badge: String? = nil, spokenValues: String? = nil) {
        self.number = number
        self.weight = weight
        self.reps = reps
        self.rpe = rpe
        self.status = status
        self.tag = tag
        self.spokenTag = spokenTag
        self.badge = badge
        self.spokenValues = spokenValues
    }
}

/// A tag the set table offers in a logged row's menu.
public struct LooprSetTagOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// The sets of one exercise: SET, KG, REPS, RPE and a check. The current row
/// is in the accent, and logged rows show a check. A logged row's RPE cell
/// opens the caller's picker. When the caller passes `onEdit`, a logged or
/// skipped row is also a button that opens the caller's editor, and a skipped
/// row reads "Skipped" instead of a load and reps.
///
/// Row identifiers are `<rowIdentifierPrefix>-<set number>` (the set, load and
/// reps read as one VoiceOver element that also says "logged"). RPE buttons
/// are `<rpeIdentifierPrefix>-<set number>`.
///
/// At accessibility text sizes the columns would not fit, so each set becomes
/// a stacked block with the labels written out.
public struct LooprSetLogTable: View {
    public static let minimumRowHeight: CGFloat = LooprSpacing.interactiveRowHeight
    private static let setColumn: CGFloat = LooprSpacing.hero
    private static let weightColumn: CGFloat = LooprSpacing.hero + LooprSpacing.lg
    /// Wide enough for "17.5 kg assist" or "+10 kg" without touching the reps.
    private static let wideWeightColumn: CGFloat = LooprSpacing.hero * 2 + LooprSpacing.lg
    private static let repsColumn: CGFloat = LooprSpacing.xxl + LooprSpacing.xl

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let rows: [LooprSetLogRow]
    private let accent: LooprColorToken
    private let weightUnit: String
    private let spokenWeightUnit: String
    private let repsTitle: String
    private let wideLoad: Bool
    private let tagOptions: [LooprSetTagOption]
    private let onSelectTag: ((LooprSetLogRow, String?) -> Void)?
    private let rowIdentifierPrefix: String
    private let rpeIdentifierPrefix: String
    private let identifier: String?
    private let onSelectRPE: ((LooprSetLogRow) -> Void)?
    private let onEdit: ((LooprSetLogRow) -> Void)?

    /// - Parameters:
    ///   - repsTitle: The second value column's header: "Reps", or "Time" and "Metres" for other kinds of set.
    ///   - wideLoad: Widens the first value column for loads written with their unit, such as "20 kg assist".
    ///   - tagOptions: Tags a logged row's menu offers. The menu also offers "Working set", which clears the tag.
    ///   - onSelectTag: Called with the row and the chosen tag id, or nil for a working set.
    public init(rows: [LooprSetLogRow], accent: LooprColorToken = .movement,
                weightUnit: String = "kg", spokenWeightUnit: String = "kilograms", repsTitle: String = "Reps",
                wideLoad: Bool = false, rowIdentifierPrefix: String, rpeIdentifierPrefix: String, identifier: String? = nil,
                tagOptions: [LooprSetTagOption] = [],
                onSelectRPE: ((LooprSetLogRow) -> Void)? = nil,
                onEdit: ((LooprSetLogRow) -> Void)? = nil,
                onSelectTag: ((LooprSetLogRow, String?) -> Void)? = nil) {
        self.rows = rows
        self.accent = accent
        self.weightUnit = weightUnit
        self.spokenWeightUnit = spokenWeightUnit
        self.repsTitle = repsTitle
        self.wideLoad = wideLoad
        self.tagOptions = tagOptions
        self.onSelectTag = onSelectTag
        self.rowIdentifierPrefix = rowIdentifierPrefix
        self.rpeIdentifierPrefix = rpeIdentifierPrefix
        self.identifier = identifier
        self.onSelectRPE = onSelectRPE
        self.onEdit = onEdit
    }

    /// What VoiceOver reads for a row: "Set 1, 80 kilograms, 8 reps, RPE 7, logged".
    public static func spokenSummary(_ row: LooprSetLogRow, spokenWeightUnit: String = "kilograms") -> String {
        if row.status == .skipped { return "Set \(row.number), skipped" }
        var parts = ["Set \(row.number)"]
        if let spokenTag = row.spokenTag { parts.append(spokenTag) }
        if let spoken = row.spokenValues { parts.append(spoken) }
        else { parts += ["\(row.weight) \(spokenWeightUnit)", "\(row.reps) reps"] }
        if let rpe = row.rpe { parts.append("RPE \(rpe)") }
        if row.badge == "PR" { parts.append("personal record") } else if let badge = row.badge { parts.append(badge) }
        switch row.status {
        case .logged: parts.append("logged")
        case .current: parts.append("current set")
        case .planned: parts.append("planned")
        case .skipped: break
        }
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver says a double tap on an editable row does.
    public static func editHint(_ row: LooprSetLogRow) -> String {
        row.status == .skipped ? "Log this set" : "Edit this set"
    }

    /// Logged and skipped rows can be edited. The current and planned rows are the steppers' business.
    public static func isEditable(_ row: LooprSetLogRow) -> Bool {
        row.status == .logged || row.status == .skipped
    }

    /// What VoiceOver reads for the RPE button.
    public static func rpeAccessibilityLabel(_ row: LooprSetLogRow) -> String {
        row.rpe.map { "RPE for set \(row.number), \($0)" } ?? "Add RPE for set \(row.number)"
    }

    private var weightColumn: CGFloat { wideLoad ? Self.wideWeightColumn : Self.weightColumn }

    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    public var body: some View {
        LooprCard {
            VStack(spacing: LooprSpacing.none) {
                if !isStacked {
                    headerRow
                    hairline
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { hairline }
                    if isStacked { stackedRow(row) } else { columnRow(row) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .modifier(LooprOptionalIdentifier(identifier))
    }

    private var hairline: some View {
        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline).accessibilityHidden(true)
    }

    private func headerText(_ title: String, width: CGFloat?) -> some View {
        Text(title.looprLabelCased)
            .looprTypography(.sectionLabel)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var headerRow: some View {
        HStack(spacing: LooprSpacing.none) {
            headerText("Set", width: Self.setColumn)
            headerText(weightUnit, width: weightColumn)
            headerText(repsTitle, width: Self.repsColumn)
            headerText("RPE", width: nil)
            Color.clear.frame(width: LooprSpacing.hero, height: LooprSpacing.hairline)
        }
        .padding(.bottom, LooprSpacing.xs)
        .accessibilityHidden(true)
    }

    private func numberColor(_ row: LooprSetLogRow) -> LooprColorToken {
        row.status == .current ? accent.textInk : .ink
    }

    private func valueColor(_ row: LooprSetLogRow) -> LooprColorToken {
        switch row.status {
        case .planned: .inkSecondary
        case .skipped: .inkMuted
        case .logged, .current: .ink
        }
    }

    private func cell(_ text: String, color: LooprColorToken, width: CGFloat) -> some View {
        Text(text)
            .looprTypography(.metricValue)
            .monospacedDigit()
            .foregroundStyle(Color.loopr(color))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: width, alignment: .leading)
    }

    private func columnRow(_ row: LooprSetLogRow) -> some View {
        HStack(spacing: LooprSpacing.none) {
            summaryElement(row) {
                HStack(spacing: LooprSpacing.none) {
                    Text(row.tag ?? "\(row.number)")
                        .looprTypography(.metricValue)
                        .monospacedDigit()
                        .foregroundStyle(Color.loopr(row.tag == nil ? numberColor(row) : accent.textInk))
                        .frame(width: Self.setColumn, alignment: .leading)
                    cell(row.weight, color: valueColor(row), width: weightColumn)
                    cell(row.reps, color: valueColor(row), width: Self.repsColumn)
                }
                .frame(minHeight: Self.minimumRowHeight)
            }
            rpeCell(row)
            checkCell(row)
        }
    }

    /// The set, load and reps as one element. It is a button when the row can be edited.
    @ViewBuilder
    private func summaryElement<Content: View>(_ row: LooprSetLogRow, @ViewBuilder content: () -> Content) -> some View {
        if let onEdit, Self.isEditable(row) {
            Button { onEdit(row) } label: { content().contentShape(Rectangle()) }
                .buttonStyle(.looprPressableRow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spokenSummary(row, spokenWeightUnit: spokenWeightUnit))
                .accessibilityHint(Self.editHint(row))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("\(rowIdentifierPrefix)-\(row.number)")
                .modifier(TagMenu(row: row, options: tagOptions, onSelect: onSelectTag))
        } else {
            content()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spokenSummary(row, spokenWeightUnit: spokenWeightUnit))
                .accessibilityIdentifier("\(rowIdentifierPrefix)-\(row.number)")
        }
    }

    @ViewBuilder
    private func stackedRow(_ row: LooprSetLogRow) -> some View {
        if let onEdit, Self.isEditable(row) {
            VStack(alignment: .leading, spacing: LooprSpacing.none) {
                Button { onEdit(row) } label: { stackedSummary(row).contentShape(Rectangle()) }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spokenSummary(row, spokenWeightUnit: spokenWeightUnit))
                    .accessibilityHint(Self.editHint(row))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("\(rowIdentifierPrefix)-\(row.number)")
                    .modifier(TagMenu(row: row, options: tagOptions, onSelect: onSelectTag))
                rpeCell(row)
            }
            .padding(.vertical, LooprSpacing.xs)
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                stackedSummary(row)
                rpeCell(row)
            }
            .padding(.vertical, LooprSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: Self.minimumRowHeight, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.spokenSummary(row, spokenWeightUnit: spokenWeightUnit))
            .accessibilityIdentifier("\(rowIdentifierPrefix)-\(row.number)")
        }
    }

    private func stackedSummary(_ row: LooprSetLogRow) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack {
                Text(["Set \(row.number)", row.spokenTag.map { $0.prefix(1).uppercased() + $0.dropFirst() }].compactMap { $0 }.joined(separator: " · "))
                    .looprTypography(.metricValue)
                    .foregroundStyle(Color.loopr(numberColor(row)))
                Spacer(minLength: LooprSpacing.sm)
                if let badge = row.badge { badgeText(badge) }
                if row.status == .logged {
                    Image(systemName: "checkmark").looprTypography(.metricValue)
                        .foregroundStyle(Color.loopr(accent.textInk))
                }
            }
            Text(row.status == .skipped ? "Skipped" : stackedValues(row))
                .looprTypography(.metricValue)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(valueColor(row)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, LooprSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: Self.minimumRowHeight, alignment: .leading)
    }

    @ViewBuilder
    private func rpeCell(_ row: LooprSetLogRow) -> some View {
        let text = Text(row.rpe ?? "·")
            .looprTypography(.metricValue)
            .monospacedDigit()
            .foregroundStyle(Color.loopr(row.rpe == nil ? .inkMuted : .ink))
        if row.status == .logged, let onSelectRPE {
            Button { onSelectRPE(row) } label: {
                HStack(spacing: LooprSpacing.xxs) {
                    text
                    if isStacked { LooprChevron() }
                }
                .frame(maxWidth: .infinity, minHeight: Self.minimumRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.rpeAccessibilityLabel(row))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("\(rpeIdentifierPrefix)-\(row.number)")
        } else if !isStacked {
            Group {
                if row.status == .skipped {
                    Text("Skipped")
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkMuted))
                } else {
                    text
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.minimumRowHeight, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    /// "80 KG × 8" for a lift. Other measures carry their unit in the text, so "20 kg assist × 8" or "0:45 · –".
    private func stackedValues(_ row: LooprSetLogRow) -> String {
        if repsTitle == "Reps" {
            let unit = weightUnit.lowercased() == "kg" && !wideLoad ? " \(weightUnit.looprLabelCased)" : ""
            return "\(row.weight)\(unit) × \(row.reps)"
        }
        return "\(row.reps) · \(row.weight)"
    }

    private func badgeText(_ badge: String) -> some View {
        Text(badge)
            .looprTypography(.confidence)
            .foregroundStyle(Color.loopr(.recoveryHigh))
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private func checkCell(_ row: LooprSetLogRow) -> some View {
        HStack(spacing: LooprSpacing.xxs) {
            if let badge = row.badge, row.status == .logged { badgeText(badge) }
            if row.status == .logged {
                Image(systemName: "checkmark")
                    .looprTypography(.metricValue)
                    .foregroundStyle(Color.loopr(accent.textInk))
            }
        }
        .frame(minWidth: LooprSpacing.hero, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// The long-press menu of a logged row: each tag, then "Working set" to clear it. VoiceOver gets the same
/// choices as actions.
private struct TagMenu: ViewModifier {
    let row: LooprSetLogRow
    let options: [LooprSetTagOption]
    let onSelect: ((LooprSetLogRow, String?) -> Void)?

    func body(content: Content) -> some View {
        if let onSelect, !options.isEmpty, row.status == .logged {
            content
                .contextMenu {
                    ForEach(options) { option in
                        Button(option.title) { onSelect(row, option.id) }
                    }
                    if row.tag != nil { Button("Working set") { onSelect(row, nil) } }
                }
                .accessibilityActions {
                    ForEach(options) { option in
                        Button("Mark as \(option.title.lowercased())") { onSelect(row, option.id) }
                    }
                    if row.tag != nil { Button("Mark as working set") { onSelect(row, nil) } }
                }
        } else {
            content
        }
    }
}

#Preview("Set log") {
    LooprSetLogTable(rows: [
        .init(number: 1, weight: "80", reps: "8", rpe: "7", status: .logged),
        .init(number: 2, weight: "–", reps: "–", status: .skipped),
        .init(number: 3, weight: "80", reps: "8", status: .current),
        .init(number: 4, weight: "80", reps: "8", status: .planned)
    ], rowIdentifierPrefix: "preview-set-row", rpeIdentifierPrefix: "preview-set-rpe",
       onSelectRPE: { _ in }, onEdit: { _ in })
        .padding(LooprSpacing.screenGutter)
        .background(Color.loopr(.background))
}
