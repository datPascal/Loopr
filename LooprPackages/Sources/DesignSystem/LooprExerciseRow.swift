import SwiftUI

/// One exercise in a template, or a superset of several, as a row in a flush
/// card: grip, name, mono spec line, chevron.
///
/// A superset passes its members together. It gets a leading accent bar and a
/// "Superset" chip, and shows its rest on the last member only, because rest
/// comes after the round, not after each exercise.
///
/// ```swift
/// LooprCard(density: .flush) {
///     LooprExerciseRow(name: "Bench press", spec: "4 × 6–8 · 80 KG", rest: "2:30",
///                      identifier: "template-exercise-0",
///                      accessibilityLabel: "Bench press, 4 sets of 6 to 8 reps at 80 kilograms, rest 2 minutes 30 seconds") {
///         edit(0)
///     }
///     LooprExerciseRow(members: [incline, row], identifier: "template-exercise-group-2") { member in edit(member.id) }
/// }
/// ```
///
/// Reordering belongs to the caller: apply `draggable` and `dropDestination`
/// to the row, and pass `onMoveUp` and `onMoveDown` so VoiceOver users get
/// "Move up" and "Move down" actions. For a superset the actions move the
/// whole group.
public struct LooprExerciseRow: View {
    public static let minimumRowHeight: CGFloat = LooprSpacing.interactiveRowHeight

    /// One exercise inside the row.
    public struct Member: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// Sets, reps and load, for example "4 × 6–8 · 80 KG". No rest.
        public let spec: String
        /// Rest between sets, for example "2:30". A superset shows only the
        /// last member's rest.
        public let rest: String?
        public let identifier: String
        public let accessibilityLabel: String

        public init(id: String, name: String, spec: String, rest: String? = nil,
                    identifier: String, accessibilityLabel: String) {
            self.id = id
            self.name = name
            self.spec = spec
            self.rest = rest
            self.identifier = identifier
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// The mono spec line: "4 × 6–8 · 80 kg · Rest 2:30".
    public static func specLine(spec: String, rest: String?) -> String {
        guard let rest, !rest.isEmpty else { return spec }
        return "\(spec) · Rest \(rest)"
    }

    /// The rest text a member shows: always its own for a single exercise,
    /// and for a superset only on the last member.
    public static func visibleRest(of members: [Member], at index: Int) -> String? {
        guard members.indices.contains(index) else { return nil }
        if members.count > 1, index != members.count - 1 { return nil }
        return members[index].rest
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let members: [Member]
    private let accent: LooprColorToken
    private let supersetTitle: String
    private let identifier: String?
    private let showsDivider: Bool
    private let onSelect: (Member) -> Void
    private let onMoveUp: (() -> Void)?
    private let onMoveDown: (() -> Void)?

    /// A superset, or a single exercise when `members` has one element.
    public init(members: [Member], accent: LooprColorToken = .movement, supersetTitle: String = "Superset",
                identifier: String, showsDivider: Bool = true,
                onSelect: @escaping (Member) -> Void,
                onMoveUp: (() -> Void)? = nil, onMoveDown: (() -> Void)? = nil) {
        self.members = members
        self.accent = accent
        self.supersetTitle = supersetTitle
        self.identifier = identifier
        self.showsDivider = showsDivider
        self.onSelect = onSelect
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
    }

    /// A single exercise. `identifier` is the row's own identifier.
    public init(name: String, spec: String, rest: String? = nil, identifier: String,
                accessibilityLabel: String, showsDivider: Bool = true,
                onMoveUp: (() -> Void)? = nil, onMoveDown: (() -> Void)? = nil,
                onSelect: @escaping () -> Void) {
        self.init(
            members: [Member(id: identifier, name: name, spec: spec, rest: rest,
                             identifier: identifier, accessibilityLabel: accessibilityLabel)],
            identifier: identifier, showsDivider: showsDivider,
            onSelect: { _ in onSelect() }, onMoveUp: onMoveUp, onMoveDown: onMoveDown)
    }

    private var isSuperset: Bool { members.count > 1 }

    public var body: some View {
        VStack(spacing: LooprSpacing.none) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                // Drawn, not an SF Symbol: there is no two-column six-dot grip, and an unknown symbol name draws nothing.
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        GridRow {
                            Circle().frame(width: 3, height: 3)
                            Circle().frame(width: 3, height: 3)
                        }
                    }
                }
                .foregroundStyle(Color.loopr(.inkTertiary))
                .frame(width: LooprSpacing.lg)
                .accessibilityHidden(true)
                if isSuperset { group } else { memberButton(members[0], index: 0) }
            }
            .padding(.leading, LooprSpacing.cardHorizontal)
            .padding(.trailing, LooprSpacing.cardHorizontal)
            if showsDivider {
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(height: LooprSpacing.hairline)
                    .padding(.leading, LooprSpacing.cardHorizontal + LooprSpacing.lg + LooprSpacing.sm)
                    .padding(.trailing, LooprSpacing.cardHorizontal)
                    .accessibilityHidden(true)
            }
        }
        .modifier(LooprGroupContainer(isGroup: isSuperset, identifier: identifier))
    }

    private var group: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            StatusChip(supersetTitle, symbol: nil, accent: accent)
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                memberButton(member, index: index)
            }
        }
        .padding(.leading, LooprSpacing.sm)
        .padding(.vertical, LooprSpacing.sm)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.loopr(accent))
                .frame(width: LooprSpacing.xxs - 1)
                .padding(.vertical, LooprSpacing.sm)
                .accessibilityHidden(true)
        }
    }

    private func memberButton(_ member: Member, index: Int) -> some View {
        let spec = Self.specLine(spec: member.spec, rest: Self.visibleRest(of: members, at: index))
        return Button { onSelect(member) } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Text(member.name)
                        .looprTypography(.settingsRow)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(spec)
                        .looprTypography(.metricUnit)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.vertical, isSuperset ? LooprSpacing.xxs : LooprSpacing.metricRowVertical)
            .frame(minHeight: isSuperset ? nil : Self.minimumRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(member.accessibilityLabel)
        .accessibilityValue(isSuperset ? supersetTitle : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(member.identifier)
        .modifier(LooprMoveActions(isGroup: isSuperset, onMoveUp: onMoveUp, onMoveDown: onMoveDown))
    }
}

/// Makes a superset one container with its own identifier, so its members stay separate elements inside it.
private struct LooprGroupContainer: ViewModifier {
    let isGroup: Bool
    let identifier: String?

    func body(content: Content) -> some View {
        if isGroup {
            content
                .accessibilityElement(children: .contain)
                .modifier(LooprOptionalIdentifier(identifier))
        } else {
            content
        }
    }
}

/// VoiceOver actions that reorder a row, added only for the directions the caller supports.
private struct LooprMoveActions: ViewModifier {
    let isGroup: Bool
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .modifier(OptionalAction(name: isGroup ? "Move superset up" : "Move up", action: onMoveUp))
            .modifier(OptionalAction(name: isGroup ? "Move superset down" : "Move down", action: onMoveDown))
    }

    private struct OptionalAction: ViewModifier {
        let name: String
        let action: (() -> Void)?
        func body(content: Content) -> some View {
            if let action {
                content.accessibilityAction(named: Text(name), action)
            } else {
                content
            }
        }
    }
}

#Preview("Exercise rows") {
    LooprCard(density: .flush) {
        VStack(spacing: LooprSpacing.none) {
            LooprExerciseRow(name: "Bench press", spec: "4 × 6–8 · 80 KG", rest: "2:30", identifier: "preview-ex-0",
                             accessibilityLabel: "Bench press, 4 sets of 6 to 8 reps at 80 kilograms, rest 2 minutes 30 seconds",
                             onMoveDown: {}) {}
            LooprExerciseRow(members: [
                .init(id: "a", name: "Incline dumbbell press", spec: "3 × 10 · 28 KG", rest: "1:30",
                      identifier: "preview-ex-1a", accessibilityLabel: "Incline dumbbell press, 3 sets of 10 reps at 28 kilograms"),
                .init(id: "b", name: "Chest-supported row", spec: "3 × 10 · 30 KG", rest: "1:30",
                      identifier: "preview-ex-1b", accessibilityLabel: "Chest-supported row, 3 sets of 10 reps at 30 kilograms, rest 1 minute 30 seconds")
            ], identifier: "preview-group", onSelect: { _ in }, onMoveUp: {}, onMoveDown: {})
            LooprInlineActionRow("Add exercise", symbol: "plus", identifier: "preview-add") {}
        }
    }
    .padding(LooprSpacing.screenGutter)
    .background(Color.loopr(.background))
}
