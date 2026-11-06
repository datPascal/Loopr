import DesignSystem
import FoodKit
import SwiftUI

struct FoodRepeatPicker: View {
    @Environment(\.dismiss) private var dismiss
    let repository: AppFoodRepository
    let recent: [FoodMeal]
    /// The slot a favourite logs into: the one the person is logging now.
    let slot: FoodMealSlot
    let now: Date
    let timeZoneIdentifier: String
    let choose: @MainActor @Sendable (FoodMealDraft) -> Void
    @State private var favorites: [FoodFavorite] = []
    @State private var delete: FoodFavorite?
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprSectionHeader("Favourites")
                if favorites.isEmpty { LooprText("Save a favourite from meal review to use it here.", style: .body, color: .inkSecondary) }
                else {
                    LooprCard(density: .flush) {
                        VStack(spacing: 0) {
                            ForEach(favorites) { favorite in
                                let energy = FoodNutrientTotal(.energy, items: favorite.items).knownValue
                                HairlineMetricRow(id: "food-favorite-\(favorite.id)", title: favorite.name,
                                    confidence: [favorite.items.count == 1 ? "1 food" : "\(favorite.items.count) foods", protein(favorite.items)]
                                        .compactMap { $0 }.joined(separator: " · "),
                                    value: energy.map(kcal) ?? "", unit: energy == nil ? nil : "kcal", isNavigable: true) {
                                        do { choose(try favorite.draft(slot: slot, at: now, timeZoneIdentifier: timeZoneIdentifier)) }
                                        catch { message = error.localizedDescription }
                                    }
                                    // The flush card has no inset of its own; this matches the dividers'.
                                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                                    .contextMenu {
                                        Button("Delete favourite", role: .destructive) { delete = favorite }.accessibilityIdentifier("food-delete-favorite-\(favorite.id)")
                                    }
                                if favorite.id != favorites.last?.id { Divider().padding(.horizontal, LooprSpacing.cardHorizontal) }
                            }
                        }
                    }
                }
                LooprSectionHeader("Recent meals")
                if recent.isEmpty { LooprText("Your saved meals will appear here.", style: .body, color: .inkSecondary) }
                else {
                    LooprCard(density: .flush) {
                        VStack(spacing: 0) {
                            ForEach(distinctRecent) { meal in
                                let energy = FoodNutrientTotal(.energy, items: meal.items).knownValue
                                HairlineMetricRow(id: "food-repeat-\(meal.id)", title: meal.items.map(\.name).joined(separator: ", "),
                                    confidence: ["\(meal.slot.title), \(meal.occurredAt.formatted(.dateTime.weekday(.wide)))", protein(meal.items)]
                                        .compactMap { $0 }.joined(separator: " · "),
                                    value: energy.map(kcal) ?? "", unit: energy == nil ? nil : "kcal", isNavigable: true) {
                                        // The copy keeps the Open Food Facts group, ingredients and plants, so the lens still counts them.
                                        choose(.repeating(meal, at: now, timeZoneIdentifier: timeZoneIdentifier))
                                    }
                                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                                if meal.id != distinctRecent.last?.id { Divider().padding(.horizontal, LooprSpacing.cardHorizontal) }
                            }
                        }
                    }
                }
                if let message { LooprText(message, style: .body, color: .critical) }
            }.padding(LooprSpacing.screenGutter)
        }.background(Color.loopr(.background)).navigationTitle("Repeat a meal")
            .toolbar(.visible, for: .navigationBar).navigationBarBackButtonHidden()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("food-repeat-cancel") } }
            .task { await reload() }
            .confirmationDialog("Delete this favourite?", isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } }), titleVisibility: .visible) {
                if let delete {
                    Button("Delete favourite", role: .destructive) {
                        Task {
                            do { try await repository.deleteFavorite(id: delete.id); await reload() }
                            catch { message = error.localizedDescription }
                            self.delete = nil
                        }
                    }.accessibilityIdentifier("food-confirm-delete-favorite")
                }
            }
    }
    /// The newest of each meal: eating the same breakfast every day lists it once.
    private var distinctRecent: [FoodMeal] {
        var seen = Set<String>()
        return recent.sorted { $0.occurredAt > $1.occurredAt }.filter { meal in
            seen.insert(meal.items.map { $0.name.lowercased() }.sorted().joined(separator: "|")).inserted
        }
    }
    private func kcal(_ value: Double) -> String { Int(value.rounded()).formatted(.number.locale(LooprUnitFormatter.displayLocale)) }
    /// "32 g protein", or nil when no item reports protein.
    private func protein(_ items: [FoodItem]) -> String? {
        FoodNutrientTotal(.protein, items: items).knownValue.map { "\(kcal($0)) g protein" }
    }
    private func reload() async {
        do { favorites = try await repository.favorites() }
        catch { message = error.localizedDescription }
    }
}
