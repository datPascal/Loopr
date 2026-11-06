import AIKit
import DesignSystem
import FoodKit
import SwiftUI

struct FoodReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var size
    @StateObject private var model: FoodReviewModel
    @StateObject private var dictation = CoachDictation()
    @State private var expanded: UUID?
    @State private var expandedRange: ClosedRange<Double> = 1...500
    @State private var expandedUnit: FoodUnit?
    @State private var showMetadata = false
    @State private var editing: FoodItem?
    @State private var showConsent = false
    @State private var saving = false
    @State private var confirmDelete = false
    /// While the keyboard is up the pinned Save steps aside, so it never covers the correction field and its send button.
    @State private var keyboardUp = false
    /// The food without calories whose USDA matches are open.
    @State private var matching: FoodItem?
    let save: @MainActor @Sendable (FoodMealDraft) async throws -> Void
    /// Set for a meal that is already in the log, so it can be deleted.
    let delete: (@MainActor @Sendable () async throws -> Void)?
    /// Leaves through the owner's state. The environment dismiss can fail to resolve once the
    /// destination's content was swapped in place, as when a repeated meal opens from Manual.
    let cancel: (@MainActor @Sendable () -> Void)?
    init(draft: FoodMealDraft, repository: AppFoodRepository, runtime: LooprAISettingsRuntime = .shared,
         now: Date, fixture: Bool = false, captureMessage: String? = nil,
         delete: (@MainActor @Sendable () async throws -> Void)? = nil,
         cancel: (@MainActor @Sendable () -> Void)? = nil,
         save: @escaping @MainActor @Sendable (FoodMealDraft) async throws -> Void) {
        _model = StateObject(wrappedValue: .init(draft: draft, repository: repository, runtime: runtime, now: now, message: captureMessage, fixture: fixture))
        self.save = save
        self.delete = delete
        self.cancel = cancel
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                Button { showMetadata = true } label: { hero }
                    .buttonStyle(.looprPressableRow).accessibilityIdentifier("food-review-metadata")
                    .accessibilityHint("Edit meal time and note")
                if model.draft.items.isEmpty { estimateControls }
                LooprSectionHeader("Items", detail: "Tap a food to change its amount")
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        ForEach(model.draft.items) { item in
                            itemRow(item)
                            Divider().padding(.horizontal, LooprSpacing.cardHorizontal)
                        }
                        LooprInlineActionRow("Add something it missed", symbol: "plus", identifier: "food-add-item") {
                            editing = .init(name: "", amount: 1, unit: .serving, provenance: [.init(source: .typed, recordedAt: model.now)])
                        }
                    }
                }
                if model.draft.items.contains(where: { $0.confidence != nil }) {
                    LooprText("Sure, Check and Guess are how confident the estimate was. Weigh a food to be certain.", style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("food-review-confidence-note")
                }
                if model.draft.items.contains(where: \.isEstimated) { correction }
                if model.busy { LooprText("Estimating food", style: .body, color: .inkSecondary).accessibilityIdentifier("food-estimate-progress") }
                if let message = model.message, !message.isEmpty { LooprText(message, style: .body, color: .critical).accessibilityIdentifier("food-review-message") }
                provenance
            }.padding(LooprSpacing.screenGutter)
                .disabled(model.busy || saving)
        }.background(Color.loopr(.background))
            .accessibilityIdentifier("food-review-scroll")
            // One Save, pinned where the thumb is, on every meal that ends here: typed, spoken, repeated, edited (R3-DES-02).
            // The tab bar steps aside so it covers nothing (ICP R3-NEW-15).
            .safeAreaInset(edge: .bottom) {
                if !model.draft.items.isEmpty && !keyboardUp {
                    saveControls
                        .padding(.horizontal, LooprSpacing.screenGutter).padding(.vertical, LooprSpacing.sm)
                        .background(.bar)
                        .disabled(model.busy)
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
            // A logged meal is named by its slot; a new one asks to be checked before it is saved.
            .navigationTitle(delete == nil ? "Check your \(model.draft.slot.rawValue)" : model.draft.slot.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", systemImage: "chevron.left") { model.stop(); dictation.stop(); if let cancel { cancel() } else { dismiss() } }
                        .labelStyle(.iconOnly).tint(Color.loopr(.ink)).accessibilityIdentifier("food-cancel-meal")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(model.favoriteSaved ? "Favourite saved" : "Save as favourite", systemImage: model.favoriteSaved ? "star.fill" : "star") {
                        Task { await model.saveFavorite() }
                    }
                    .labelStyle(.iconOnly).tint(Color.loopr(.energy))
                    .disabled(model.favoriteSaved || model.draft.items.isEmpty)
                    .accessibilityIdentifier("food-save-favorite")
                }
                // Delete sits in a menu, not as a full-width button as loud as Save (ICP R1-DES, R1-NEW-13).
                if delete != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Delete \(model.draft.slot.rawValue)", systemImage: "trash", role: .destructive) { confirmDelete = true }
                                .accessibilityIdentifier("food-delete-meal")
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                        .tint(Color.loopr(.ink)).accessibilityIdentifier("food-meal-menu")
                    }
                }
            }
            .confirmationDialog("Delete this \(model.draft.slot.rawValue)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    dictation.stop()
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await delete?() }
                        catch { model.message = error.localizedDescription }
                    }
                }.accessibilityIdentifier("food-confirm-delete-meal")
                Button("Cancel", role: .cancel) {}
            } message: { Text("Its foods and photos leave your food log. This can't be undone.") }
            .task { await model.load() }
            .onDisappear { model.stop(); dictation.stop() }
            .interactiveDismissDisabled(saving)
            .sensoryFeedback(trigger: model.favoriteSaved) { _, saved in saved ? .success : nil }
            .sensoryFeedback(.impact(weight: .light), trigger: expanded)
            .sensoryFeedback(trigger: model.draft.items.count) { old, new in new < old ? .impact(weight: .medium) : nil }
            .animation(LooprMotion.stateChange, value: model.draft.items.map(\.id))
            .animation(LooprMotion.stateChange, value: expanded)
            .sheet(item: $matching) { item in
                NavigationStack {
                    FoodMatchPicker(item: item) { food in
                        guard let reference = FoodReference.shared else { return }
                        let name = reference.shortName(food)
                        let replacement = (try? reference.item(food, name: name, amount: item.amount, unit: item.unit, at: model.now))
                            ?? (try? reference.item(food, name: name, amount: 100, unit: .grams, at: model.now))
                        if let replacement { model.swap(id: item.id, with: replacement) }
                        matching = nil
                    }
                }.presentationDetents([.medium, .large])
            }
            .sheet(item: $editing) { item in
                NavigationStack { FoodItemEditor(item: item, now: model.now) { value in model.replace(value) } }
            }
            .sheet(isPresented: $showConsent) { consentSheet }
            .sheet(isPresented: $showMetadata) {
                NavigationStack {
                    FoodMealMetadataEditor(draft: model.draft, providerName: model.consent ? model.provider?.provider.name : nil,
                        revoke: { @MainActor @Sendable in await model.revoke() },
                        apply: { @MainActor @Sendable slot, time, note in
                            if model.draft.note != note { model.favoriteSaved = false }
                            model.draft.slot = slot; model.draft.occurredAt = time; model.draft.note = note
                        })
                }
            }
            .onChange(of: model.draft.items) { _, items in
                guard let id = expanded else { return }
                guard let item = items.first(where: { $0.id == id }) else { expanded = nil; return }
                if item.unit != expandedUnit || !expandedRange.contains(item.amount) {
                    expandedRange = amountRange(item); expandedUnit = item.unit
                }
            }
    }
    private var hero: some View {
        LooprCard(style: .hero(.energy)) {
            HStack(spacing: LooprSpacing.md) {
                if let photo = model.draft.photos.first, let image = UIImage(data: photo.bytes) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: LooprSpacing.foodReviewThumbnail, height: LooprSpacing.foodReviewThumbnail)
                        .clipShape(RoundedRectangle(cornerRadius: LooprRadius.control)).accessibilityLabel("Your food photo")
                }
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    if model.draft.items.isEmpty {
                        LooprText("Nothing added yet", style: .cardTitle)
                        LooprText(model.draft.photos.isEmpty ? "Add foods below." : "Estimate the photo, or add foods below.", style: .body, color: .inkSecondary)
                    } else {
                        StatusChip(model.draft.items.count == 1 ? "1 item" : "\(model.draft.items.count) items", symbol: nil, accent: .energy)
                        Text(total(.energy, suffix: "kcal"))
                            .looprTypography(.cardTitle).foregroundStyle(Color.loopr(.ink))
                            .contentTransition(.numericText())
                            .accessibilityLabel(FoodNutrientTotal(.energy, items: model.draft.items).knownValue == nil ? "Calories not known" : total(.energy, suffix: "kilocalories"))
                        HStack(spacing: LooprSpacing.sm) {
                            macro(.protein, "P"); macro(.carbs, "C"); macro(.fat, "F"); macro(.fibre, "Fibre")
                        }
                        if model.draft.items.contains(where: { $0.nutrients.values.isEmpty == false }),
                           [FoodNutrient.energy, .protein, .carbs, .fat, .fibre].contains(where: { !FoodNutrientTotal($0, items: model.draft.items).isComplete }) {
                            LooprText("Totals count only the foods with values.", style: .caption, color: .inkSecondary)
                        }
                        if model.draft.items.contains(where: { $0.nutrients[.energy] == nil && ($0.valueSource == .typed || $0.valueSource == .voice) }) {
                            // A typed or spoken food Loopr could not match has no values until the person adds them or
                            // picks a match on the Type screen. Says so and points at the button on each row (ICP R3-NEW-5).
                            LooprText("Some foods have no calories yet. You can save them as they are, pick a match where there is one, or type the numbers from the pack.",
                                      style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("food-review-no-energy")
                        }
                    }
                }
                .animation(LooprMotion.stateChange, value: model.draft.items)
            }
        }
    }
    /// One macro in its own colour, so the three read at a glance.
    private func macro(_ nutrient: FoodNutrient, _ letter: String) -> some View {
        HStack(spacing: LooprSpacing.xxs) {
            Circle().fill(Color.loopr(nutrient.accent)).frame(width: 7, height: 7)
            Text("\(letter) \(total(nutrient, suffix: "g"))")
                .looprTypography(.body).foregroundStyle(Color.loopr(.inkSecondary))
                .contentTransition(.numericText())
        }
    }
    private func total(_ nutrient: FoodNutrient, suffix: String) -> String {
        let total = FoodNutrientTotal(nutrient, items: model.draft.items)
        // A dash, as everywhere in Food, not a large "Unknown".
        guard let value = total.knownValue else { return "– \(suffix)" }
        // "Known" is said once, under the totals, not after each number (R2-DES-14).
        return "\(FoodInput.text(value.rounded())) \(suffix)"
    }
    private func itemRow(_ item: FoodItem) -> some View {
        VStack(spacing: 0) {
            LooprReviewRow(title: item.name, detail: detail(item),
                value: item.nutrients[.energy].map { FoodInput.text($0.rounded()) } ?? "Unknown", state: item.provenance.last?.source == .manualEdit ? "Edited" : item.valueSource == .reference ? "USDA" : item.confidence?.title,
                accent: item.confidence == .guess ? .critical : item.confidence == .check ? .energy : .brand,
                expanded: expanded == item.id, identifier: "food-review-item-\(item.id)") {
                    if expanded == item.id { expanded = nil }
                    else { expandedRange = amountRange(item); expandedUnit = item.unit; expanded = item.id }
                }
                .contextMenu {
                    Button("Edit food and nutrients") { editing = item }.accessibilityIdentifier("food-edit-item")
                    if !model.favorites.isEmpty {
                        Menu("Swap from favourites") {
                            ForEach(model.favorites) { favorite in
                                ForEach(favorite.items) { replacement in
                                    Button(replacement.name) { model.swap(id: item.id, with: replacement) }
                                }
                            }
                        }.accessibilityIdentifier("food-swap-favorite")
                    }
                    Button("Remove item", role: .destructive) { model.remove(id: item.id) }
                        .accessibilityIdentifier("food-remove-item")
                }
                .accessibilityAction(named: "Edit food and nutrients") { editing = item }
            // A typed food has no calories until the person adds them: a visible button, not only press and hold
            // (ICP R3-NEW-5, R3-UPG-17).
            if item.valueSource == .reference {
                // A USDA match can be wrong ("chicken" read as roasted breast); swapping it is one tap (R3-VET-02).
                Button { matching = item } label: { Label("Change match", systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy, quiet: true))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LooprSpacing.cardHorizontal).padding(.bottom, LooprSpacing.xs)
                    .accessibilityLabel("Change the match for \(item.name)")
                    .accessibilityIdentifier("food-change-match-\(item.id)")
            }
            if item.nutrients[.energy] == nil {
                // A match first: most people do not know the number, the USDA table often does (R2-NEW-02, R2-MAC-04).
                HStack(spacing: LooprSpacing.md) {
                    if FoodReference.shared.map({ !$0.search(item.name, limit: 1).isEmpty }) == true {
                        Button { matching = item } label: { Label("Find a match", systemImage: "magnifyingglass") }
                            .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy, quiet: true))
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("Find a match for \(item.name)")
                            .accessibilityIdentifier("food-find-match-\(item.id)")
                    }
                    Button { editing = item } label: {
                        Label("Add calories", systemImage: "plus.circle")
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy, quiet: true))
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Add calories to \(item.name)")
                    .accessibilityIdentifier("food-add-calories-\(item.id)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.bottom, LooprSpacing.xs)
            }
            if expanded == item.id {
                VStack(spacing: LooprSpacing.sm) {
                    amountStepper(item)
                    LooprAmountSlider("\(item.name) amount in \(item.unit.title)",
                        value: Binding(get: { model.draft.items.first(where: { $0.id == item.id })?.amount ?? item.amount },
                            set: { model.scale(id: item.id, amount: $0) }), range: expandedRange,
                        step: item.unit == .grams || item.unit == .millilitres ? 1 : 0.25, identifier: "food-item-slider")
                    if item.name.lowercased().contains("rice") {
                        LooprChoiceControl("Rice", choices: ["White", "Brown", "Jasmine"].map { .init($0) },
                            selection: ["White", "Brown", "Jasmine"].first(where: { item.name.lowercased().hasPrefix($0.lowercased()) }),
                            accent: .energy, identifier: "food-rice-swap") { value in
                                if let value { model.swapRice(id: item.id, type: value) }
                            }
                    }
                }.padding(.horizontal, LooprSpacing.cardHorizontal).padding(.bottom, LooprSpacing.sm)
            }
        }
    }
    /// The amount, and for a USDA match the portion and the food Loopr assumed: "1 serving · 1 large · Egg, whole,
    /// cooked, hard-boiled" (R2-VET-02, R2-VET-03).
    private func detail(_ item: FoodItem) -> String {
        let amount = "\(FoodInput.text(item.amount)) \(item.unit.title(for: item.amount))"
        guard item.valueSource == .reference, let source = item.provenance.last(where: { $0.source == .reference })?.reference else { return amount }
        return [amount, source.portion.map { "each \($0)" }, source.description].compactMap { $0 }.joined(separator: " · ")
    }
    /// The amount as a number with a nudge either side: 10 g, 10 ml or a quarter serving (R3-MAC-04).
    private func amountStepper(_ item: FoodItem) -> some View {
        let current = model.draft.items.first(where: { $0.id == item.id })?.amount ?? item.amount
        let step = item.unit == .grams || item.unit == .millilitres ? 10.0 : 0.25
        return HStack(spacing: LooprSpacing.md) {
            Button { model.scale(id: item.id, amount: max(step, current - step)) } label: {
                Image(systemName: "minus").frame(width: 44, height: 44)
            }
            .buttonStyle(.looprPressableCard).accessibilityLabel("Less \(item.name)").accessibilityIdentifier("food-item-less")
            Text("\(FoodInput.text(current)) \(item.unit.title(for: current))")
                .looprTypography(.cardTitle).foregroundStyle(Color.loopr(.ink)).contentTransition(.numericText())
                .frame(minWidth: 120)
            Button { model.scale(id: item.id, amount: current + step) } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }
            .buttonStyle(.looprPressableCard).accessibilityLabel("More \(item.name)").accessibilityIdentifier("food-item-more")
        }
        .foregroundStyle(Color.loopr(.energy))
        .frame(maxWidth: .infinity)
    }
    private func amountRange(_ item: FoodItem) -> ClosedRange<Double> {
        let minimum = item.unit == .grams || item.unit == .millilitres ? 1.0 : 0.25
        return min(minimum, item.amount)...max(item.unit == .grams || item.unit == .millilitres ? 500 : 5, item.amount)
    }
    private var estimateControls: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            if model.available, let provider = model.provider, !model.draft.photos.isEmpty {
                LooprText("Estimate this photo with \(provider.provider.name), then check each item.", style: .body, color: .inkSecondary)
                Button(model.busy ? "Estimating" : "Estimate photo") {
                    if model.consent { model.estimate() } else { showConsent = true }
                }.buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-estimate-photo")
            } else {
                LooprText("Photo estimates need your own Claude or OpenAI key in Your data. You can add foods yourself, scan a label or use a barcode.", style: .body, color: .inkSecondary)
            }
        }
    }
    private var correction: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprInlineComposer("Say what is wrong, like the rice was brown", text: $model.correction, recording: dictation.recording,
                identifier: "food-correction", voiceLabel: "Dictate correction", submitLabel: "Review correction",
                submitIdentifier: "food-send-correction", voice: {
                    if dictation.recording { dictation.stop() }
                    else { Task { await dictation.start { model.correction = $0 } } }
                }, submit: {
                    dictation.stop()
                    // The correction is sent: the keyboard goes, and the pinned Save comes back.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    if !model.available { model.message = "Add an API key in Your data, or edit the foods yourself." }
                    else if model.consent { model.estimate() } else { showConsent = true }
                })
            if let issue = dictation.issue { LooprText(issue.message, style: .caption, color: .inkSecondary) }
        }
    }
    private var saveControls: some View {
        Button(saving ? "Saving" : "Save \(model.draft.slot.rawValue)") {
            dictation.stop()
            let draft = model.draft
            saving = true
            Task {
                defer { saving = false }
                do { try await save(draft) }
                catch { model.message = error.localizedDescription }
            }
        }
        .buttonStyle(LooprButtonStyle(accent: .energy)).disabled(saving).accessibilityIdentifier("food-save-meal")
    }
    private var provenance: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            if let source = model.draft.items.flatMap(\.provenance).last(where: { $0.source == .photoAI }) {
                let caution = model.uncertainty.isEmpty ? "Check portions and ingredients before saving." : model.uncertainty
                LooprText("\(source.provider == "anthropic" ? "Claude" : "OpenAI") estimated this with your API key. Sent photos and notes leave this iPhone. \(caution)", style: .caption, color: .inkSecondary)
                    .accessibilityIdentifier("food-estimate-uncertainty")
            } else if !model.uncertainty.isEmpty {
                LooprText(model.uncertainty, style: .caption, color: .inkSecondary).accessibilityIdentifier("food-estimate-uncertainty")
            }
            if model.draft.items.contains(where: { $0.provenance.contains(where: { $0.product != nil }) }) {
                LooprText(FoodProductSource.attribution, style: .caption, color: .inkSecondary)
                Link("Open Database License", destination: FoodProductSource.databaseLicense).accessibilityIdentifier("food-product-license")
            }
        }.accessibilityIdentifier("food-review-source")
    }
    private var consentSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    LooprText("Send food photos to \(model.provider?.provider.name ?? "your provider")?", style: .titleLarge)
                    LooprText("Loopr sends the selected photo and food note with your API key. It removes photo location and capture-time metadata first. Corrections send your food draft and reviewed text, including on-device dictation, without resending the photo.", style: .body)
                    LooprText("This permission applies to food photos for this provider. You can revoke it from review or AI providers. Provider retention rules apply. Nothing is added to your food log until you tap Save.", style: .body, color: .inkSecondary)
                    if let provider = model.provider { Link("\(provider.provider.name) privacy policy", destination: provider.provider.privacyURL).accessibilityIdentifier("food-photo-privacy") }
                    Button("Allow and send") { showConsent = false; Task { await model.approveAndEstimate() } }
                        .buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-photo-consent-send")
                }.padding(LooprSpacing.screenGutter)
            }.background(Color.loopr(.background)).navigationTitle("Photo access")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showConsent = false }.accessibilityIdentifier("food-photo-consent-cancel") } }
        }
    }
}

/// USDA foods for a typed food Loopr could not fill in by itself. A tap takes one, with the amount the person typed.
struct FoodMatchPicker: View {
    @Environment(\.dismiss) private var dismiss
    let item: FoodItem
    let pick: (FoodReferenceFood) -> Void
    @State private var query: String
    init(item: FoodItem, pick: @escaping (FoodReferenceFood) -> Void) {
        self.item = item; self.pick = pick; _query = State(initialValue: item.name)
    }
    private var matches: [FoodReferenceFood] { FoodReference.shared?.search(query, limit: 12) ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprInlineTextField("Search foods", text: $query, label: "Search foods", identifier: "food-match-query")
                if matches.isEmpty {
                    LooprText("No match. Try fewer words, or scan the pack's barcode.", style: .body, color: .inkSecondary)
                        .accessibilityIdentifier("food-match-none")
                } else {
                    LooprCard(density: .flush) {
                        VStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, food in
                                if index > 0 { Divider().overlay(Color.loopr(.divider)) }
                                let portion = FoodCaptureView.portion(food)
                                Button { pick(food) } label: {
                                    HStack(spacing: LooprSpacing.sm) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            LooprText(food.name, style: .rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                                            LooprText("USDA · \(portion.label)", style: .caption, color: .inkSecondary)
                                        }
                                        Spacer(minLength: LooprSpacing.sm)
                                        LooprText((try? food.nutrients(grams: portion.grams))?[.energy].map { "\(FoodInput.text($0.rounded())) kcal" } ?? "– kcal",
                                                  style: .rowTitle)
                                    }
                                    .padding(.horizontal, LooprSpacing.cardHorizontal).padding(.vertical, LooprSpacing.sm)
                                    .frame(minHeight: LooprSpacing.interactiveRowHeight).contentShape(Rectangle())
                                }
                                .buttonStyle(.looprPressableRow)
                                .accessibilityIdentifier("food-match-pick-\(food.id)")
                            }
                        }
                    }
                }
                LooprText("Values from USDA FoodData Central, per 100 g, scaled to your amount. Check that the match is what you ate.",
                          style: .caption, color: .inkSecondary)
            }.padding(LooprSpacing.screenGutter)
        }
        .background(Color.loopr(.background))
        .navigationTitle("Match for \(item.name)").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("food-match-cancel") } }
    }
}
