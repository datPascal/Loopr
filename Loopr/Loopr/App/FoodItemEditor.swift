import DesignSystem
import FoodKit
import SwiftUI

struct FoodItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: FoodItem
    let now: Date
    let apply: @MainActor @Sendable (FoodItem) -> Void
    @State private var name: String
    @State private var amount: String
    @State private var unit: FoodUnit
    @State private var nutrients: [FoodNutrient: String]
    @State private var issue: String?
    @State private var previousAmount: Double
    init(item: FoodItem, now: Date, apply: @escaping @MainActor @Sendable (FoodItem) -> Void) {
        original = item; self.now = now; self.apply = apply
        _name = State(initialValue: item.name); _amount = State(initialValue: FoodInput.text(item.amount)); _unit = State(initialValue: item.unit)
        _nutrients = State(initialValue: Dictionary(uniqueKeysWithValues: FoodNutrient.allCases.map { ($0, FoodInput.text(item.nutrients[$0])) }))
        _previousAmount = State(initialValue: item.amount)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        LooprTextFieldRow(title: "Food", placeholder: "Name", text: $name).accessibilityIdentifier("food-item-name")
                        LooprTextFieldRow(title: "Amount", placeholder: "Amount", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("food-item-amount")
                        LooprPickerRow(title: "Unit", selection: $unit, options: FoodUnit.allCases, label: { $0.title }).accessibilityIdentifier("food-item-unit-\(original.id)")
                    }
                }
                LooprSectionHeader("Nutrients", detail: "Totals for this amount. Leave unknown values blank.")
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        ForEach(FoodNutrient.allCases, id: \.self) { nutrient in
                            LooprTextFieldRow(title: title(nutrient), placeholder: "Unknown",
                                text: Binding(get: { nutrients[nutrient] ?? "" }, set: { nutrients[nutrient] = $0 }))
                                .keyboardType(.decimalPad).accessibilityIdentifier(nutrient == .energy ? "food-item-energy" : "food-item-\(nutrient.rawValue)-\(original.id)")
                            if nutrient != .alcoholUnits { Divider() }
                        }
                    }
                }
                if let product = original.provenance.compactMap(\.product).last {
                    if let decoded = try? FoodProductDecoder.decode(product.rawResponse, barcode: product.barcode, fetchedAt: product.fetchedAt) {
                        LooprText("Source values are per 100 \(decoded.basis.title), \(decoded.preparation == "prepared" ? "as prepared" : "as sold"). Check the current label.", style: .caption, color: .inkSecondary)
                    }
                    Link("View product source", destination: product.sourceURL).accessibilityIdentifier("food-item-product-source")
                }
                if let source = original.provenance.compactMap(\.reference).last { usdaSource(source) }
                if let label = original.provenance.compactMap(\.labelText).last {
                    DisclosureGroup("Recognized label text") { LooprText(label, style: .body, color: .inkSecondary) }
                        .accessibilityIdentifier("food-item-label-text")
                }
                if let issue { LooprText(issue, style: .body, color: .critical).accessibilityIdentifier("food-item-error") }
                Button("Apply to draft") {
                    do {
                        var item = original
                        item.name = name; item.amount = try FoodInput.number(amount)!; item.unit = unit
                        for nutrient in FoodNutrient.allCases { item.nutrients[nutrient] = try FoodInput.number(nutrients[nutrient] ?? "", optional: true) }
                        try item.validate()
                        if item != original { try item.recordEdit(at: now) }
                        apply(item); dismiss()
                    } catch { issue = error.localizedDescription }
                }.buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-apply-item")
            }.padding(LooprSpacing.screenGutter)
        }.background(Color.loopr(.background)).navigationTitle("Edit food")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("food-cancel-item") } }
            .onChange(of: amount) { _, value in
                guard let number = FoodInput.parse(value), number.isFinite, number > 0, previousAmount > 0 else { return }
                let factor = number / previousAmount
                for nutrient in FoodNutrient.allCases {
                    if let old = FoodInput.parse(nutrients[nutrient] ?? ""), old.isFinite, (old * factor).isFinite { nutrients[nutrient] = FoodInput.text(old * factor) }
                }
                previousAmount = number
            }
            .onChange(of: unit) { _, _ in
                nutrients = [:]
                issue = "The unit changed. Enter nutrients for the new amount and unit."
            }
    }
    /// Where a typed food's values came from, so a person can check the match: USDA's description, the FoodData
    /// Central id, the portion it was read as, and the per-100 g values (R2-VET-02, R3-VET-01).
    private func usdaSource(_ source: FoodReferenceSource) -> some View {
        let food = FoodReference.shared?.foods.first { $0.id == source.fdcID }
        let per100 = food.map { food in
            [(FoodNutrient.energy, "kcal"), (.protein, "g protein"), (.carbs, "g carbs"), (.fat, "g fat"), (.fibre, "g fibre")]
                .compactMap { nutrient, unit in food.per100g[nutrient].map { "\(FoodInput.text($0)) \(unit)" } }.joined(separator: ", ")
        }
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Source", detail: "USDA FoodData Central, SR Legacy")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(source.description, style: .rowTitle)
                    if let portion = source.portion { LooprText("Read as \(portion) each", style: .body, color: .inkSecondary) }
                    if let per100, !per100.isEmpty { LooprText("Per 100 g: \(per100)", style: .body, color: .inkSecondary) }
                    LooprText("FoodData Central ID \(source.fdcID)", style: .caption, color: .inkSecondary).textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("food-item-usda-source")
    }
    private func title(_ nutrient: FoodNutrient) -> String {
        switch nutrient {
        case .energy: "Energy, kcal"
        case .protein: "Protein, g"
        case .carbs: "Carbs, g"
        case .fat: "Fat, g"
        case .fibre: "Fibre, g"
        case .sugar: "Sugar, g"
        case .salt: "Salt, g"
        case .caffeine: "Caffeine, mg"
        case .alcoholUnits: "Alcohol units, 10 g"
        }
    }
}
