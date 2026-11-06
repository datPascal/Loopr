import Combine
import DesignSystem
import FoodKit
import SwiftUI
import UIKit

/// Loads the Food tab's longevity objects beside the day summary: the protocol's kitchen and fibre targets, this
/// week's plants and lens, today's stack, and the camera's sticker for each of the day's meal photos. A tick on a
/// capsule draws at once and is saved behind it.
@MainActor
final class FoodLongevityModel: ObservableObject {
    @Published private(set) var state = FoodLongevity()
    /// This week's meals, the ones the plants screen can add a plant to.
    @Published private(set) var weekMeals: [FoodMeal] = []
    /// Rail stickers already cut, by photo id, so a revisit does not run Vision again.
    private var stickerCache: [UUID: Image] = [:]
    private var generation = 0

    /// - Parameters:
    ///   - day: the day summary the screen shows; its meals' photos become rail stickers.
    ///   - bodyWeightKilograms: the weight trend, or the latest day's weight before it counts (`FoodWeightTrend.current`).
    func load(repository: AppFoodRepository, date: Date, calendar: Calendar, day: FoodDaySummary?, bodyWeightKilograms: Double?) async {
        generation += 1
        let token = generation
        do {
            let snapshot = try await repository.longevity(date: date, calendar: calendar, bodyWeightKilograms: bodyWeightKilograms)
            guard token == generation else { return }
            let stickers = await stickers(for: day?.meals ?? [], repository: repository)
            guard token == generation else { return }
            state = FoodLongevity(isLoaded: true, targets: snapshot.targets, plants: snapshot.plants, newPlants: snapshot.newPlants,
                hasEarlierWeeks: snapshot.hasEarlierWeeks, lens: snapshot.lens, bodyWeightKilograms: bodyWeightKilograms,
                barcodedItems: snapshot.barcodedItems, stack: snapshot.stack, stickers: stickers, settleToken: state.settleToken)
            weekMeals = snapshot.weekMeals
        } catch is CancellationError {
        } catch {
            guard token == generation else { return }
            // The rings and rail still draw; the sections below show their absent states.
            var failed = FoodLongevity(isLoaded: true, settleToken: state.settleToken)
            failed.stickers = state.stickers
            state = failed
        }
    }

    /// The camera's finish handed back to the tab: the ring dots settle once more.
    func settle() { state.settleToken += 1 }

    /// Ticks or clears one dose. The capsule changes at once; a failed save puts it back and throws.
    /// - Returns: true when the dose is now taken.
    func toggle(_ capsule: FoodCapsule, repository: AppFoodRepository, at date: Date) async throws -> Bool {
        guard let shelf = state.stack else { return false }
        let takes = FoodStackTap.action(for: capsule.dose.state) == .take
        state.stack = shelf.toggling(capsule, at: date)
        do {
            try await repository.toggleDose(capsule, day: shelf.localDay, at: date)
            state.stack = try await repository.stackShelf(localDay: shelf.localDay)
            return takes
        } catch {
            state.stack = shelf
            throw error
        }
    }

    /// Reads the stack again after the editor changed it.
    func reloadStack(repository: AppFoodRepository) async {
        guard let day = state.stack?.localDay else { return }
        if let shelf = try? await repository.stackShelf(localDay: day) { state.stack = shelf }
    }

    private func stickers(for meals: [FoodMeal], repository: AppFoodRepository) async -> [UUID: Image] {
        let photoByMeal = Dictionary(meals.compactMap { meal in meal.photos.first.map { (meal.id, $0.id) } }, uniquingKeysWith: { first, _ in first })
        let missing = Set(photoByMeal.values).subtracting(stickerCache.keys)
        if !missing.isEmpty, let bytes = try? await repository.photoBytes(ids: Array(missing)) {
            for (id, data) in bytes {
                let cut = await Task.detached(priority: .userInitiated) { FoodRailStickerImage(FoodLensArt.railSticker(photo: data)) }.value
                if let image = cut.image { stickerCache[id] = Image(uiImage: image) }
            }
        }
        return photoByMeal.compactMapValues { stickerCache[$0] }
    }
}

/// Carries a cut sticker from the background task that made it. The image is not touched again off the main actor.
nonisolated struct FoodRailStickerImage: @unchecked Sendable {
    let image: UIImage?
    init(_ image: UIImage?) { self.image = image }
}
