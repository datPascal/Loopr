import DesignSystem
import FoodKit
import SwiftUI

struct FoodMealMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var slot: FoodMealSlot
    @State private var time: Date
    @State private var note: String
    let photoExplanation: String?
    let providerName: String?
    let revoke: @MainActor @Sendable () async -> Void
    let apply: @MainActor @Sendable (FoodMealSlot, Date, String) -> Void
    init(draft: FoodMealDraft, providerName: String?, revoke: @escaping @MainActor @Sendable () async -> Void,
         apply: @escaping @MainActor @Sendable (FoodMealSlot, Date, String) -> Void) {
        _slot = State(initialValue: draft.slot); _time = State(initialValue: draft.occurredAt)
        _note = State(initialValue: draft.note); photoExplanation = draft.photoTime?.explanation
        self.providerName = providerName; self.revoke = revoke; self.apply = apply
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        LooprPickerRow(title: "Meal", selection: $slot, options: FoodMealSlot.allCases, label: { $0.title })
                            .accessibilityIdentifier("food-meal-slot")
                        DatePicker("Time", selection: $time).padding(LooprSpacing.md)
                            .frame(minHeight: LooprSpacing.interactiveRowHeight).accessibilityIdentifier("food-meal-time")
                        LooprTextFieldRow(title: "Note", placeholder: "Optional", text: $note)
                            .accessibilityIdentifier("food-review-note")
                    }
                }
                if let photoExplanation { LooprText(photoExplanation, style: .caption, color: .inkSecondary) }
                Button("Apply") { apply(slot, time, note); dismiss() }
                    .buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-apply-metadata")
                if let providerName {
                    Button("Revoke \(providerName) photo access") { Task { await revoke() } }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy)).accessibilityIdentifier("food-revoke-photo-consent")
                }
            }.padding(LooprSpacing.screenGutter)
        }.background(Color.loopr(.background)).navigationTitle("Meal time and note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.accessibilityIdentifier("food-cancel-metadata")
            } }
    }
}
