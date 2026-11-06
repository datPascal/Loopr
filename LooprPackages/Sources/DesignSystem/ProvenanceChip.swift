import SwiftUI

/// Where a number came from (DESIGN_LANGUAGE premium check 8). Every number on screen carries one.
public enum LooprProvenance: Equatable, Sendable {
    /// How a food number was made.
    public enum Food: Equatable, Sendable {
        /// Logged by the person, from their own food or a saved meal.
        case logged
        /// A scanned barcode, read from Open Food Facts.
        case barcode
        /// Estimated from a photo.
        case photoEstimate
    }

    /// Measured by the band. `device` is the band's name as the app shows it.
    case band(device: String)
    /// Read from Apple Health. `source` is the writing app or device, such as "Apple Watch".
    /// `typedIn` is true when the person typed the sample into Health.
    case appleHealth(source: String, typedIn: Bool = false)
    case food(Food)
    /// From a lab report. `name` is the lab's name.
    case lab(name: String)
    /// Typed in by the person in Loopr.
    case typedIn
    /// Estimated by Loopr with a named method, such as "PhenoAge".
    case estimated(method: String)
    /// Worked out on this iPhone from the person's own data.
    case onThisPhone
    /// No value. The chip shows nothing, or "Not measured" when the caller asks for it.
    case absent

    /// True for a number the band measured, the default source on Today.
    public var isBand: Bool {
        if case .band = self { return true }
        return false
    }

    /// The words on the chip. Nil for `absent`.
    public var label: String? {
        switch self {
        case let .band(device): Self.named(device, or: "Band")
        case let .appleHealth(source, typedIn): typedIn ? "Typed into Apple Health" : Self.named(source, or: "Apple Health")
        case .food(.logged): "Food log"
        case .food(.barcode): "Open Food Facts"
        case .food(.photoEstimate): "Photo estimate"
        case let .lab(name): Self.named(name, or: "Lab report")
        case .typedIn: "Typed in"
        case let .estimated(method): method.trimmingCharacters(in: .whitespaces).isEmpty ? "Loopr estimate" : "\(method) estimate"
        case .onThisPhone: "On this iPhone"
        case .absent: nil
        }
    }

    /// A shorter label for a compact chip in a narrow cell, where the full one wraps (R1-UPG-17): "iPhone" for "On this
    /// iPhone". Nil keeps `label`.
    public var compactLabel: String? {
        switch self {
        case .onThisPhone: "iPhone"
        default: nil
        }
    }

    /// The source as VoiceOver says it after "From". Nil for `absent`.
    public var spokenSource: String? {
        switch self {
        case let .band(device): Self.named(device, or: "the band")
        case let .appleHealth(source, typedIn):
            typedIn ? "Apple Health, typed in" : source.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Apple Health" : "\(source) through Apple Health"
        case .food(.logged): "your food log"
        case .food(.barcode): "Open Food Facts"
        case .food(.photoEstimate): "a photo estimate"
        case let .lab(name): Self.named(name, or: "a lab report")
        case .typedIn: "what you typed in"
        case let .estimated(method): method.trimmingCharacters(in: .whitespaces).isEmpty ? "a Loopr estimate" : "a \(method) estimate"
        case .onThisPhone: "this iPhone"
        case .absent: nil
        }
    }

    /// The colour of the chip's dot.
    public var tint: LooprColorToken {
        switch self {
        case .band, .onThisPhone, .estimated: .brand
        case .appleHealth: .heart
        case .food: .energy
        case .lab: .sleep
        case .typedIn, .absent: .inkSecondary
        }
    }

    /// "From <source>, <qualifier>", or "Not measured" for `absent`.
    public func accessibilityLabel(qualifier: String? = nil) -> String {
        guard let spokenSource else { return LooprHeroNumberAbsent.defaultText }
        let qualifier = qualifier?.trimmingCharacters(in: .whitespaces)
        guard let qualifier, !qualifier.isEmpty else { return "From \(spokenSource)" }
        return "From \(spokenSource), \(qualifier)"
    }

    /// The chip's text: the label and the qualifier, as in "Apple Watch · 42-day median".
    public func text(qualifier: String? = nil) -> String? {
        guard let label else { return nil }
        let qualifier = qualifier?.trimmingCharacters(in: .whitespaces)
        guard let qualifier, !qualifier.isEmpty else { return label }
        return "\(label) · \(qualifier)"
    }

    private static func named(_ name: String, or fallback: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : name
    }
}

/// The small capsule under a number that says where it came from (the contract's `.chipp`): a dot
/// in the source's colour, the source and an optional qualifier such as "42-day median" or
/// "2 min ago". VoiceOver reads "From <source>, <qualifier>". With an action it is a button with a
/// 44 pt hit area; screens link it to the number's method page.
///
/// ```swift
/// ProvenanceChip(.appleHealth(source: "Apple Watch"), qualifier: "42-day median", identifier: "fitness-vo2-source")
/// ProvenanceChip(.onThisPhone, identifier: "today-note-source") { showMethod = true }
/// ```
public struct ProvenanceChip: View {
    /// What an absent value shows.
    public enum AbsentStyle: Equatable, Sendable {
        /// Nothing: the number's own absent state says it.
        case hidden
        /// A chip that reads "Not measured".
        case notMeasured
    }

    /// How much the chip says.
    public enum Style: Equatable, Sendable {
        /// The source and the qualifier on one line: "Apple Watch · 42-day median".
        case standard
        /// The source only, wrapping to a second line when the space is narrow, for a small cell such as Today's three
        /// readouts. The qualifier stays in the VoiceOver label, so nothing is lost and no word is cut in half.
        case compact
    }

    /// The smallest tappable height of a chip with an action.
    public nonisolated static let minimumHitTarget: CGFloat = 44
    /// The dot's diameter.
    public nonisolated static let dotDiameter: CGFloat = 6
    /// A one-line chip reads as a capsule; a compact chip that wraps keeps the same corners.
    nonisolated static let cornerRadius: CGFloat = 11

    private let provenance: LooprProvenance
    private let qualifier: String?
    private let tint: LooprColorToken?
    private let absentStyle: AbsentStyle
    private let style: Style
    private let identifier: String?
    private let action: (() -> Void)?

    public init(_ provenance: LooprProvenance, qualifier: String? = nil, tint: LooprColorToken? = nil,
                absent: AbsentStyle = .hidden, style: Style = .standard, identifier: String? = nil, action: (() -> Void)? = nil) {
        self.provenance = provenance
        self.qualifier = qualifier
        self.tint = tint
        absentStyle = absent
        self.style = style
        self.identifier = identifier
        self.action = action
    }

    /// The text the chip shows, or nil when it draws nothing.
    public var displayedText: String? {
        if style == .compact, let short = provenance.compactLabel { return short }
        if let text = provenance.text(qualifier: style == .compact ? nil : qualifier) { return text }
        return absentStyle == .notMeasured ? LooprHeroNumberAbsent.defaultText : nil
    }

    /// Whether the chip is a button.
    public var isInteractive: Bool { action != nil && displayedText != nil }

    /// The height the chip claims for touches: 44 pt with an action, its own height without one.
    public var hitHeight: CGFloat? { isInteractive ? Self.minimumHitTarget : nil }

    public var accessibilityText: String { provenance.accessibilityLabel(qualifier: qualifier) }

    public var body: some View {
        if let text = displayedText {
            if let action {
                Button(action: action) { capsule(text) }
                    .buttonStyle(.plain)
                    .frame(minHeight: Self.minimumHitTarget)
                    .contentShape(.interaction, Rectangle())
                    .accessibilityLabel(accessibilityText)
                    .looprOptionalIdentifier(identifier)
            } else {
                capsule(text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
                    .looprOptionalIdentifier(identifier)
            }
        }
    }

    private func capsule(_ text: String) -> some View {
        let dot = Color.loopr(provenance == .absent ? .inkMuted : tint ?? provenance.tint)
        return HStack(spacing: LooprSpacing.xxs + 2) {
            Circle()
                .fill(dot)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                .shadow(color: dot, radius: 4)
            Text(text)
                .looprTypography(.chip)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .lineLimit(style == .compact ? 2 : 1)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: style == .compact)
        }
        .padding(.vertical, LooprSpacing.xxs)
        .padding(.horizontal, LooprSpacing.xs + 2)
        .background(Color.loopr(.divider), in: style == .compact
            ? AnyShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)) : AnyShape(Capsule(style: .continuous)))
    }
}

extension View {
    /// Sets an accessibility identifier only when the caller gave one.
    @ViewBuilder func looprOptionalIdentifier(_ identifier: String?) -> some View {
        if let identifier { accessibilityIdentifier(identifier) } else { self }
    }
}
