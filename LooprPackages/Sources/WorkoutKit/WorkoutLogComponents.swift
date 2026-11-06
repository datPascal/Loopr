import DesignSystem
import SwiftUI

// Shared parts of the quick log and the WOD log: chips, a wrapping chip layout, the day and duration section,
// typed number rows and the effort chips.

/// A capsule that can be picked. Selected chips take the Fitness accent with an outline, so the state does not
/// rest on colour alone.
struct WorkoutChip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    var spoken: String?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.xxs) {
                if let symbol { Image(systemName: symbol).imageScale(.small).accessibilityHidden(true) }
                LooprText(title, style: .label,
                          color: selected ? LooprColorToken.workoutAccent.spectralChipLabel : .ink)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.loopr(LooprColorToken.workoutAccent.spectralChipLabel) : Color.loopr(.ink))
            .padding(.horizontal, LooprSpacing.sm)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .background(selected ? Color.loopr(.workoutAccent).opacity(0.16) : Color.loopr(.surfaceElevated),
                        in: Capsule(style: .continuous))
            .overlay {
                if selected {
                    Capsule(style: .continuous).stroke(Color.loopr(.workoutAccent), lineWidth: LooprSpacing.hairline)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel(spoken ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct WorkoutChipFlow: Layout {
    var spacing: CGFloat = LooprSpacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                let y = row.y + row.height + spacing
                rows.append(Row(indices: [index], y: y, width: size.width, height: size.height))
                continue
            }
            row.indices.append(index)
            row.width = needed
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// Day chips, duration chips with a stepper, and the end time: "Ended now" until the person changes it.
struct WorkoutLogWhenSection: View {
    @Binding var day: WorkoutLogDay
    @Binding var pickedDay: Date
    @Binding var durationMinutes: Int
    @Binding var endsNow: Bool
    @Binding var endTime: Date
    let now: Date
    let identifier: String

    var body: some View {
        LooprSectionGroup(title: "When") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    WorkoutChipFlow {
                        ForEach(WorkoutLogDay.allCases, id: \.self) { option in
                            WorkoutChip(title: option.title, selected: day == option,
                                        identifier: "\(identifier)-day-\(option.rawValue)") { day = option }
                        }
                    }
                    if day == .pick {
                        DatePicker("Day", selection: $pickedDay, in: ...now, displayedComponents: [.date])
                            .looprTypography(.settingsRow)
                            .tint(Color.loopr(.workoutAccent))
                            .accessibilityIdentifier("\(identifier)-picked-day")
                    }
                    LooprHairline()
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        HStack {
                            LooprText("How long", style: .settingsRow)
                            Spacer(minLength: LooprSpacing.sm)
                            durationStepper
                        }
                        WorkoutChipFlow {
                            ForEach(WorkoutLogTiming.durationChips, id: \.self) { minutes in
                                WorkoutChip(title: "\(minutes) min", selected: durationMinutes == minutes,
                                            spoken: "\(minutes) minutes",
                                            identifier: "\(identifier)-duration-\(minutes)") { durationMinutes = minutes }
                            }
                        }
                    }
                    LooprHairline()
                    if endsNow {
                        HStack {
                            LooprText(day == .today ? "Ended now" : "Ended at \(now.formatted(.dateTime.hour().minute()))", style: .settingsRow)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: LooprSpacing.sm)
                            Button("Change time") {
                                endTime = now
                                endsNow = false
                            }
                            .looprTypography(.label)
                            .tint(Color.loopr(LooprColorToken.workoutAccent.spectralChipLabel))
                            .frame(minHeight: LooprSpacing.interactiveRowHeight)
                            .accessibilityIdentifier("\(identifier)-change-time")
                        }
                    } else {
                        DatePicker("Ended at", selection: $endTime, displayedComponents: [.hourAndMinute])
                            .looprTypography(.settingsRow)
                            .tint(Color.loopr(.workoutAccent))
                            .accessibilityIdentifier("\(identifier)-end-time")
                    }
                }
            }
        }
    }

    private var durationStepper: some View {
        HStack(spacing: LooprSpacing.xs) {
            stepButton("minus", spoken: "Five minutes less", direction: -1)
            LooprText(LooprUnitFormatter.duration(minutes: Double(durationMinutes)) ?? "\(durationMinutes) min", style: .metricValue)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 64)
                .accessibilityLabel("Duration, \(durationMinutes) minutes")
                .accessibilityIdentifier("\(identifier)-duration-value")
            stepButton("plus", spoken: "Five minutes more", direction: 1)
        }
    }

    private func stepButton(_ symbol: String, spoken: String, direction: Int) -> some View {
        Button { durationMinutes = WorkoutLogTiming.stepped(durationMinutes, direction: direction) } label: {
            Image(systemName: symbol)
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("\(identifier)-duration-\(direction > 0 ? "plus" : "minus")")
    }
}

/// A row with a label, a typed number and its unit. `caption` says where the number comes from.
struct WorkoutNumberFieldRow: View {
    let title: String
    let placeholder: String
    let unit: String?
    var caption: String?
    var decimal = false
    @Binding var text: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                LooprText(title, style: .settingsRow)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: LooprSpacing.sm)
                TextField(text: $text, prompt: Text(placeholder).foregroundStyle(Color.loopr(.inkSecondary))) { Text(title) }
                    .keyboardType(decimal ? .decimalPad : .numberPad)
                    .multilineTextAlignment(.trailing)
                    .looprTypography(.settingsRow)
                    .monospacedDigit()
                    .frame(maxWidth: 120)
                    .accessibilityIdentifier(identifier)
                if let unit { LooprText(unit, style: .metricUnit, color: .inkSecondary) }
            }
            if let caption {
                LooprText(caption, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }

    /// The typed number, nil when the field is empty or not a number. Accepts a comma as the decimal mark.
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}

/// "How hard was it?" with chips 1 to 10, the ends labelled "1 very easy" and "10 all out" (R2-NEW-09). Tapping
/// the chosen one again clears it.
struct WorkoutEffortPicker: View {
    @Binding var effort: Int?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack {
                LooprText("How hard was it?", style: .settingsRow)
                Spacer()
                LooprText(effort.map { "\($0) of 10, \(Self.word(for: $0))" } ?? "Optional", style: .caption, color: .inkSecondary)
            }
            WorkoutChipFlow(spacing: LooprSpacing.xxs) {
                ForEach(WorkoutLogEntry.effortRange, id: \.self) { value in
                    WorkoutChip(title: Self.chipTitle(for: value), selected: effort == value, spoken: "Effort \(value) of 10",
                                identifier: "\(identifier)-\(value)") { effort = effort == value ? nil : value }
                }
            }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// The chip's label: the number, with its word at the two ends of the scale.
    static func chipTitle(for effort: Int) -> String {
        effort == WorkoutLogEntry.effortRange.lowerBound || effort == WorkoutLogEntry.effortRange.upperBound
            ? "\(effort) \(word(for: effort))" : "\(effort)"
    }

    /// A plain word for an effort value.
    static func word(for effort: Int) -> String {
        switch effort {
        case ...2: "very easy"
        case 3...4: "easy"
        case 5...6: "moderate"
        case 7...8: "hard"
        default: "all out"
        }
    }
}

/// The save button pinned under a form. Its bar is opaque, so chips scrolled under it never print through the
/// label (R2-DES-03, R2-NEW-08); a short fade above it marks the edge.
struct WorkoutPinnedSaveButton: View {
    let title: String
    let enabled: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.sm)
        .padding(.bottom, LooprSpacing.xs)
        .background {
            Color.loopr(.background)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Color.loopr(.background).opacity(0), Color.loopr(.background)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: LooprSpacing.md)
                        .offset(y: -LooprSpacing.md)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}
