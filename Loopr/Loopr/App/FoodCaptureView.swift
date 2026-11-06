import DesignSystem
import FoodKit
import SwiftUI

/// Type and Speak: type or dictate one food per line, take a match for the line being typed, then check the meal on the
/// review screen. Quick add saves totals like "600 kcal, 30 g protein" straight away.
struct FoodCaptureView: View {
    @Environment(\.calendar) private var calendar
    @StateObject private var model: FoodCaptureModel
    @StateObject private var dictation = CoachDictation()
    @State private var dictated = false
    @State private var showReview = false
    @State private var beginVoice: Bool
    /// Foods (type or pick each food) or Totals (quick add), at the top so a meal out is two taps away (R2-MAC-07).
    @State private var totals = false
    @State private var saving = false
    let save: @MainActor @Sendable (FoodMealDraft) async throws -> Void
    /// Pops capture through the owner's state. The environment dismiss can stop resolving after the
    /// review destination pops, which left Close doing nothing.
    let close: @MainActor @Sendable () -> Void
    /// Opens past meals and favourites in place of this screen.
    let repeatMeal: (@MainActor @Sendable () -> Void)?
    init(draft: FoodMealDraft, beginVoice: Bool = false, repository: AppFoodRepository,
         fixture: Bool, now: Date, close: @escaping @MainActor @Sendable () -> Void,
         repeatMeal: (@MainActor @Sendable () -> Void)? = nil,
         save: @escaping @MainActor @Sendable (FoodMealDraft) async throws -> Void) {
        _model = StateObject(wrappedValue: .init(draft: draft, repository: repository, fixture: fixture, now: now))
        _beginVoice = State(initialValue: beginVoice); self.close = close; self.repeatMeal = repeatMeal; self.save = save
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprChoiceControl("What to add", choices: [.init("foods", title: "Foods"), .init("totals", title: "Totals")],
                                   selection: totals ? "totals" : "foods", accent: .energy, identifier: "food-type-mode") { choice in
                    dictation.stop(); totals = choice == "totals"
                }
                if totals { quickAddSection } else { foodsSection }
            }.padding(.horizontal, LooprSpacing.screenGutter).padding(.vertical, LooprSpacing.md)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background)).navigationTitle(model.draft.slot.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar).navigationBarBackButtonHidden()
        // Type gets the whole screen: the floating tab bar covered its fields and Save (R2-NEW-06, R2-DES-02).
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dictation.stop(); close() }.labelStyle(.iconOnly).tint(Color.loopr(.ink))
                    .accessibilityIdentifier("food-capture-close")
            }
        }
        .task {
            if beginVoice { beginVoice = false; await dictate() }
            await model.loadRecent(calendar: calendar)
        }
        .onDisappear { dictation.stop() }
        // Stored flag, not a computed Binding: see FoodTabRoot's detail destination.
        .onChange(of: model.review != nil, initial: true) { _, present in if showReview != present { showReview = present } }
        .onChange(of: showReview) { _, shown in
            guard !shown, model.review != nil else { return }
            model.review = nil
        }
        .navigationDestination(isPresented: $showReview) {
            if let draft = model.review {
                FoodReviewView(draft: draft, repository: model.repository, now: model.now, fixture: model.fixture, captureMessage: model.message, save: save)
            }
        }
    }
    @ViewBuilder private var foodsSection: some View {
        LooprCard(density: .flush) {
            LooprTextEditorRow(title: "What did you eat?", placeholder: "2 eggs and toast\na banana", text: $model.text)
                .accessibilityIdentifier("food-capture-text")
        }
        HStack(alignment: .top, spacing: LooprSpacing.md) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(dictation.recording ? "Listening. Tap stop when you're done." : "Say it the way you'd say it. Grams are optional.",
                          style: .body, color: .inkSecondary)
                LooprText("Speech stays on this iPhone.", style: .caption, color: .inkSecondary)
            }
            Spacer(minLength: 0)
            LooprHeaderActionButton(action: .init(symbol: dictation.recording ? "stop.fill" : "mic", label: dictation.recording ? "Stop dictation" : "Dictate food",
                identifier: "food-capture-dictation", run: { Task { await dictate() } }))
        }
        matchList
        pickedList
        // Every food known: add it now, or check amounts first. Otherwise review, where unknown foods get a match.
        if model.allKnown {
            Button(saving ? "Saving" : "Add to \(model.draft.slot.rawValue)") { addNow() }
                .buttonStyle(LooprButtonStyle(accent: .energy)).disabled(saving).accessibilityIdentifier("food-capture-add")
            Button("Check amounts first") { dictation.stop(); model.reviewText(source: dictated ? .voice : .typed) }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy)).accessibilityIdentifier("food-capture-review-text")
        } else {
            Button("Review meal") { dictation.stop(); model.reviewText(source: dictated ? .voice : .typed) }
                .buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-capture-review-text")
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.picked.isEmpty)
        }
        LooprInlineTextField("Add a note, like half a portion", text: $model.draft.note,
            label: "Food note", identifier: "food-capture-note")
        if let message = model.message, !message.isEmpty {
            LooprText(message, style: .body, color: .inkSecondary).accessibilityIdentifier("food-capture-message")
        }
        if let issue = dictation.issue { LooprText(issue.message, style: .body, color: .inkSecondary) }
        if let repeatMeal {
            LooprCard(density: .flush) {
                LooprInlineActionRow("Repeat a past meal or favourite", symbol: "arrow.counterclockwise", identifier: "food-repeat") {
                    dictation.stop(); repeatMeal()
                }
            }
        }
    }
    private func addNow() {
        guard !saving, let draft = model.directDraft(source: dictated ? .voice : .typed) else { return }
        dictation.stop(); saving = true
        Task {
            defer { saving = false }
            do { try await save(draft) }
            catch { model.message = error.localizedDescription }
        }
    }
    /// Matches for the line being typed: the person's own foods first, then USDA's. A tap takes one.
    @ViewBuilder private var matchList: some View {
        let mine = model.mine, matches = model.matches
        if !mine.isEmpty || !matches.isEmpty {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Matches", detail: "Tap one to add it with its calories")
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        ForEach(Array(mine.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().overlay(Color.loopr(.divider)) }
                            matchRow(title: item.name, detail: "Logged before · \(amount(item))", nutrients: item.nutrients,
                                     identifier: "food-match-mine-\(index)") { model.pick(item) }
                        }
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, food in
                            if index > 0 || !mine.isEmpty { Divider().overlay(Color.loopr(.divider)) }
                            let preview = model.preview(food)
                            matchRow(title: food.name, detail: "USDA · \(preview.label)", nutrients: preview.nutrients,
                                     identifier: "food-match-usda-\(food.id)") { model.pick(food) }
                        }
                    }
                }
            }
        }
    }
    private func matchRow(title: String, detail: String, nutrients: FoodNutrients, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    LooprText(title, style: .rowTitle).lineLimit(2).multilineTextAlignment(.leading)
                    LooprText(detail, style: .caption, color: .inkSecondary).lineLimit(1)
                }
                Spacer(minLength: LooprSpacing.sm)
                VStack(alignment: .trailing, spacing: 2) {
                    LooprText(nutrients[.energy].map { "\(FoodInput.text($0.rounded())) kcal" } ?? "– kcal", style: .rowTitle)
                    LooprText(nutrients[.protein].map { "\(FoodInput.text($0.rounded())) g protein" } ?? "", style: .caption, color: .inkSecondary)
                }
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.loopr(.energy)).accessibilityHidden(true)
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal).padding(.vertical, LooprSpacing.sm)
            .frame(minHeight: LooprSpacing.interactiveRowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel("Add \(title). \(detail). \(nutrients[.energy].map { "\(FoodInput.text($0.rounded())) kilocalories" } ?? "")")
        .accessibilityIdentifier(identifier)
    }
    /// The foods taken from the matches so far.
    @ViewBuilder private var pickedList: some View {
        if !model.picked.isEmpty {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("In this meal", detail: pickedTotal)
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.picked.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().overlay(Color.loopr(.divider)) }
                            HStack(spacing: LooprSpacing.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    LooprText(item.name, style: .rowTitle).lineLimit(1)
                                    LooprText([amount(item), item.valueSource?.sourceTitle].compactMap { $0 }.joined(separator: " · "), style: .caption, color: .inkSecondary)
                                }
                                Spacer(minLength: LooprSpacing.sm)
                                VStack(alignment: .trailing, spacing: 2) {
                                    LooprText(item.nutrients[.energy].map { "\(FoodInput.text($0.rounded())) kcal" } ?? "– kcal", style: .rowTitle)
                                    LooprText(item.nutrients[.protein].map { "\(FoodInput.text($0.rounded())) g protein" } ?? "", style: .caption, color: .inkSecondary)
                                }
                                Button { withAnimation(LooprMotion.stateChange) { model.unpick(item.id) } } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(Color.loopr(.inkSecondary)).frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.looprPressableRow)
                                .accessibilityLabel("Remove \(item.name)").accessibilityIdentifier("food-unpick-\(index)")
                            }
                            .padding(.leading, LooprSpacing.cardHorizontal).padding(.trailing, LooprSpacing.xs)
                            .accessibilityIdentifier("food-picked-\(index)")
                        }
                    }
                }
            }
        }
    }
    /// "290 kcal · 48 g protein" for the picked foods.
    private var pickedTotal: String {
        [(FoodNutrient.energy, "kcal"), (.protein, "g protein")].compactMap { nutrient, unit in
            FoodNutrientTotal(nutrient, items: model.picked).knownValue.map { "\(FoodInput.text($0.rounded())) \(unit)" }
        }.joined(separator: " · ")
    }
    private func amount(_ item: FoodItem) -> String { "\(FoodInput.text(item.amount)) \(item.unit.title(for: item.amount))" }
    /// The portion a match is shown at: its household measure without USDA's notes, or 100 g.
    static func portion(_ food: FoodReferenceFood) -> (label: String, grams: Double) {
        guard let index = food.defaultPortion, food.portions.indices.contains(index) else { return ("100 g", 100) }
        // USDA's size notes ("(7\" to 7-7/8\" long)") go; Loopr's own portions keep their "(Loopr)".
        let raw = food.portions[index].label
        let label = raw.contains("(Loopr)") ? raw : raw.replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression)
        return ("\(label), \(FoodInput.text(food.portions[index].grams.rounded())) g", food.portions[index].grams)
    }
    @ViewBuilder private var quickAddSection: some View {
        LooprSectionHeader("Totals", detail: "For a meal out: type what the menu says. Loopr saves it as your totals.")
        LooprCard(density: .flush) {
            VStack(spacing: 0) {
                LooprTextFieldRow(title: "Name", placeholder: "Optional", text: $model.quickName)
                    .accessibilityIdentifier("food-quick-name")
                ForEach([FoodNutrient.energy, .protein, .carbs, .fat], id: \.self) { nutrient in
                    Divider()
                    LooprTextFieldRow(title: quickTitle(nutrient), placeholder: "Optional",
                        text: Binding(get: { model.quick[nutrient] ?? "" }, set: { model.quick[nutrient] = $0 }))
                        .keyboardType(.decimalPad).accessibilityIdentifier("food-quick-\(nutrient.rawValue)")
                }
            }
        }
        if let message = model.quickMessage {
            LooprText(message, style: .body, color: .critical).accessibilityIdentifier("food-quick-message")
        }
        if model.hasQuickValues {
            Button(saving ? "Saving" : "Save \(model.draft.slot.rawValue)") {
                guard !saving else { return }
                dictation.stop()
                guard let draft = model.quickDraft() else { return }
                saving = true
                Task {
                    defer { saving = false }
                    do { try await save(draft) }
                    catch { model.quickMessage = error.localizedDescription }
                }
            }.buttonStyle(LooprButtonStyle(accent: .energy)).disabled(saving).accessibilityIdentifier("food-quick-save")
        }
    }
    private func quickTitle(_ nutrient: FoodNutrient) -> String {
        switch nutrient {
        case .energy: "Energy, kcal"
        case .protein: "Protein, g"
        case .carbs: "Carbs, g"
        default: "Fat, g"
        }
    }
    private func dictate() async {
        if dictation.recording { dictation.stop(); return }
        dictated = true
        let initial = model.text
        await dictation.start { text in model.text = initial.isEmpty ? text : initial + "\n" + text }
    }
}
