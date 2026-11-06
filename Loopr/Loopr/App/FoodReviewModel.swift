import AIKit
import Combine
import FoodKit
import Foundation

@MainActor final class FoodReviewModel: ObservableObject {
    @Published var draft: FoodMealDraft
    @Published var provider: CoachProviderConfiguration?
    @Published var consent = false
    @Published var available = false
    @Published var busy = false
    @Published var message: String?
    @Published var uncertainty = ""
    @Published var correction = ""
    @Published var favorites: [FoodFavorite] = []
    @Published var favoriteSaved = false
    let runtime: LooprAISettingsRuntime
    let repository: AppFoodRepository
    let now: Date
    private var revision = UUID()
    private var requestTask: Task<Void, Never>?
    init(draft: FoodMealDraft, repository: AppFoodRepository, runtime: LooprAISettingsRuntime = .shared, now: Date, message: String? = nil, fixture: Bool = false) {
        self.draft = draft; self.repository = repository; self.now = now; self.message = message
        #if DEBUG
        self.runtime = fixture ? FoodProviderFixtures.runtime() : runtime
        #else
        self.runtime = runtime
        #endif
    }
    func load() async {
        do {
            provider = try await runtime.selectedConfiguration()
            if let provider {
                available = await runtime.credentialAvailable(provider)
                consent = try await runtime.hasFoodPhotoConsent(provider)
            } else { available = false; consent = false }
            favorites = try await repository.favorites()
        } catch { message = error.localizedDescription }
    }
    func stop() { revision = UUID(); requestTask?.cancel(); requestTask = nil; busy = false }
    func revoke() async {
        stop()
        if let provider { await runtime.revokeFoodPhotoConsent(provider.provider) }
        consent = false
    }
    func approveAndEstimate() async {
        guard let provider else { return }
        do { try await runtime.grantFoodPhotoConsent(provider); consent = true; estimate() }
        catch { message = error.localizedDescription }
    }
    func estimate() {
        guard !busy else { return }
        guard let provider, available else { message = "Add an API key in Your data, or edit the foods yourself."; return }
        guard consent else { message = "Review photo access before sending."; return }
        let id = UUID(); revision = id
        let draft = self.draft, correction = self.correction.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; message = nil
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == id { busy = false; requestTask = nil } }
            do {
                let image: Data?
                let text: String
                if !correction.isEmpty && !draft.items.isEmpty {
                    image = nil
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    // Only reviewed food fields go to the provider. Photo time and provenance stay local.
                    let values = draft.items.enumerated().map { index, item in CorrectionItem(index: index, name: item.name, amount: item.amount, unit: item.unit, nutrients: Dictionary(uniqueKeysWithValues: item.nutrients.values.map { ($0.key.rawValue, $0.value) })) }
                    text = "Current food draft:\n" + String(decoding: try encoder.encode(values), as: UTF8.self) + "\nCorrection:\n" + correction
                } else {
                    guard let photo = draft.photos.first else { throw FoodError.invalidPhoto }
                    image = try await Task.detached(priority: .userInitiated) { try FoodProviderImage.jpeg(photo) }.value
                    text = "Estimate the food in this photo. Food note:\n" + draft.note
                }
                try Task.checkCancellation()
                let request = try CoachStructuredRequest(configuration: provider, instructions: FoodEstimate.instructions,
                    text: text, imageJPEG: image, schema: FoodEstimate.schema)
                let result = try await runtime.structured(request)
                try Task.checkCancellation()
                let estimate = try FoodEstimate.decode(result, provider: provider.provider == .openAI ? "openai" : "anthropic", model: provider.model, at: now, previousItems: correction.isEmpty ? [] : draft.items)
                guard revision == id else { return }
                self.draft.items = estimate.items; uncertainty = estimate.uncertainty
                self.correction = ""; favoriteSaved = false
                if estimate.items.isEmpty { message = "No food could be estimated. Add the items yourself." }
            } catch {
                guard revision == id, !Task.isCancelled else { return }
                message = error.localizedDescription
                if (error as? CoachStructuredError) == .consentRequired || (error as? CoachProviderError) == .configurationChanged { await load() }
            }
        }
    }
    func scale(id: UUID, amount: Double) {
        guard !busy, let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
        do { try draft.items[index].changeAmount(to: amount, at: now); favoriteSaved = false }
        catch { message = error.localizedDescription }
    }
    func replace(_ item: FoodItem) {
        guard !busy else { return }
        if let index = draft.items.firstIndex(where: { $0.id == item.id }) { draft.items[index] = item }
        else { draft.items.append(item) }
        favoriteSaved = false
    }
    func remove(id: UUID) {
        guard !busy else { return }
        draft.items.removeAll { $0.id == id }
        favoriteSaved = false
    }
    func swap(id: UUID, with replacement: FoodItem) {
        guard !busy, let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
        let old = draft.items[index]
        draft.items[index] = .init(id: old.id, name: replacement.name, amount: replacement.amount, unit: replacement.unit,
            nutrients: replacement.nutrients, provenance: old.provenance + replacement.provenance + [.init(source: .manualEdit, recordedAt: now)])
        favoriteSaved = false
    }
    func swapRice(id: UUID, type: String) {
        guard !busy, let item = draft.items.first(where: { $0.id == id }), item.name.lowercased().contains("rice") else { return }
        guard ["White", "Brown", "Jasmine"].contains(type), item.name.lowercased() != type.lowercased() + " rice" else { return }
        swap(id: id, with: .init(name: type + " rice", amount: item.amount, unit: item.unit, nutrients: .init(),
            provenance: [.init(source: .manualEdit, recordedAt: now)]))
        message = "The rice changed. Enter its nutrients or send a correction to estimate them."
    }
    func saveFavorite() async {
        guard !busy, !draft.items.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let name = String(draft.items.map(\.name).joined(separator: ", ").prefix(500))
            try await repository.confirmFavorite(.init(name: name, items: draft.items, note: draft.note, confirmedAt: now))
            favoriteSaved = true; favorites = try await repository.favorites()
        } catch { message = error.localizedDescription }
    }
    private struct CorrectionItem: Codable { let index: Int; let name: String; let amount: Double; let unit: FoodUnit; let nutrients: [String: Double] }
}
