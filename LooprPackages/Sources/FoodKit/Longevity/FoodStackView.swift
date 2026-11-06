import DesignSystem
import SwiftUI

/// "Supplements and medication" (contract p-food, which calls it the stack): today's due doses as flat chips that name
/// the dose, "D3 2,000 IU", with a tick once taken (UX R2-DES-09, R2-VET-12, R1-VET-10). Morning and evening supplements
/// come first; medication has its own lane under them (DEC-12.10). A tap ticks a dose, a second tap takes the tick back.
/// "Edit" opens the stack editor.
struct FoodStackView: View {
    let shelf: FoodStackShelf?
    let tick: (FoodCapsule) -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Supplements and medication", detail: shelf?.supplementsHeadline, actionTitle: "Edit", accent: .energy,
                               actionIdentifier: "food-stack-edit", action: edit)
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                if let shelf, !shelf.isEmpty {
                    if !shelf.morning.isEmpty { lane("Morning", shelf.morning) }
                    if !shelf.evening.isEmpty { lane("Evening", shelf.evening) }
                    if !shelf.medication.isEmpty {
                        if !shelf.supplements.isEmpty { Divider().overlay(Color.loopr(.divider)) }
                        lane("Medication" + (shelf.medicationHeadline.map { " · \($0)" } ?? ""), shelf.medication)
                    }
                } else {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprText(shelf == nil ? "Supplements and medication could not be loaded." : "Nothing due today. If you take any, add them here and tick them off.",
                                  style: .body, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if shelf != nil {
                            Button(action: edit) { Text("Add supplements or medication").frame(maxWidth: .infinity) }
                                .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy))
                                .accessibilityIdentifier("food-stack-add")
                        }
                    }
                }
            }
            .padding(LooprSpacing.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .looprCardBackground()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("food-stack")
        }
    }

    private func lane(_ title: String, _ capsules: [FoodCapsule]) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(title, style: .label, color: .inkSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: LooprSpacing.xs)], alignment: .leading, spacing: LooprSpacing.xs) {
                ForEach(capsules) { capsule in
                    Button { tick(capsule) } label: { FoodDoseChip(capsule: capsule) }
                        .buttonStyle(.looprPressableCard)
                        .accessibilityLabel(capsule.accessibilityLabel)
                        .accessibilityHint(capsule.isTaken ? "Takes the tick back" : "Marks it taken")
                        .accessibilityAddTraits(capsule.isTaken ? .isSelected : [])
                        .accessibilityIdentifier(capsule.identifier)
                }
            }
        }
    }
}

/// One due dose as a flat chip: a dot in the item's colour, its name over its dose, and a tick. Taken doses fill with
/// a faint tint of that colour; skipped ones fade.
struct FoodDoseChip: View {
    let capsule: FoodCapsule

    var body: some View {
        let colour = Color(foodHex: capsule.colors.second) ?? Color.loopr(.energy)
        let shape = RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
        HStack(spacing: LooprSpacing.xs) {
            Circle().fill(colour).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                LooprText(capsule.name, style: .rowTitle, color: capsule.isTaken ? .inkSecondary : .ink)
                    .lineLimit(2).minimumScaleFactor(0.85)
                LooprText(Self.dose(capsule.dose.dose), style: .caption, color: .inkSecondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: capsule.isTaken ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(capsule.isTaken ? Color.loopr(.brand) : Color.loopr(.divider))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, LooprSpacing.sm).padding(.vertical, LooprSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .background(capsule.isTaken ? colour.opacity(0.12) : Color.clear, in: shape)
        .overlay { shape.strokeBorder(Color.loopr(.divider), lineWidth: 1) }
        .opacity(capsule.dose.state.isSkipped ? 0.45 : 1)
        .contentShape(shape)
        .animation(LooprMotion.stateChange, value: capsule.isTaken)
    }

    /// "2,000 IU" or "2.5 g", in the app's number style.
    static func dose(_ dose: DoseAmount) -> String {
        dose.amount.formatted(.number.precision(.fractionLength(0...2)).locale(LooprUnitFormatter.displayLocale)) + " " + dose.unit.title
    }
}
