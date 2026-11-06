import DesignSystem
import SwiftUI

/// "Plants this week" (contract p-food): the count as a hero number, a 30-slot field of seeds shaped by category with
/// this week's new plants ringed, and a sentence naming the newest. The whole card opens the week's plants.
struct FoodPlantsCard: View {
    @Environment(\.locale) private var locale
    let field: FoodSeedField
    let sentence: String
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Plants this week")
            Button(action: open) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        LooprHeroNumber(Double(field.count), unit: "of \(FoodSeedField.slots)", style: .heroNumeralLarge,
                                        color: field.count > 0 ? .ink : .inkSecondary)
                        Spacer(minLength: 0)
                        LooprChevron()
                    }
                    FoodSeedGrid(seeds: field.seeds)
                    LooprText(sentence, style: .body, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .padding(LooprSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .looprCardBackground()
                .contentShape(RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plants this week, \(field.count) of \(FoodSeedField.slots). \(sentence)")
            .accessibilityHint("Shows each plant, where it came from, and lets you change them")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("food-plants")
        }
    }
}

/// Ten seeds to a row.
struct FoodSeedGrid: View {
    let seeds: [FoodSeed]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: FoodSeedField.columns), spacing: 7) {
            ForEach(seeds) { seed in
                FoodSeedGlyph(seed: seed).aspectRatio(1, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One seed: its category's shape in its colour, lit from the top left, with a ring in the Food accent when it is
/// new this week. An empty slot is a faint outline.
struct FoodSeedGlyph: View {
    let seed: FoodSeed

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                if seed.plant == nil {
                    Circle().strokeBorder(Color.loopr(.inkMuted), lineWidth: 1.3).opacity(0.6)
                } else {
                    let color = Color(foodHex: seed.colorHex) ?? Color.loopr(.energy)
                    FoodSeedShapeView(shape: seed.shape)
                        .fill(color)
                        .overlay {
                            FoodSeedShapeView(shape: seed.shape)
                                .fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.34, y: 0.3),
                                                     startRadius: 0, endRadius: side * 0.45))
                        }
                        .overlay {
                            FoodSeedShapeView(shape: seed.shape)
                                .fill(LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .center, endPoint: .bottom))
                        }
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 3)
                        .padding(side * 0.06)
                    if seed.isNew {
                        Circle().strokeBorder(Color.loopr(.energy), lineWidth: 1.5)
                            .padding(-side * 0.1)
                    }
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The drawn outline of each seed shape, in a unit square.
struct FoodSeedShapeView: Shape {
    let shape: FoodSeedShape

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        switch shape {
        case .round:
            path.addEllipse(in: rect)
        case .berry:
            path.addEllipse(in: CGRect(x: rect.minX + w * 0.04, y: rect.minY + h * 0.14, width: w * 0.92, height: h * 0.86))
            path.move(to: p(0.5, 0.18)); path.addQuadCurve(to: p(0.66, 0.0), control: p(0.5, 0.04))
            path.addLine(to: p(0.7, 0.04)); path.addQuadCurve(to: p(0.56, 0.2), control: p(0.58, 0.08)); path.closeSubpath()
        case .bean:
            path.move(to: p(0.2, 0.3))
            path.addCurve(to: p(0.82, 0.22), control1: p(0.32, 0.02), control2: p(0.66, 0.0))
            path.addCurve(to: p(0.84, 0.8), control1: p(1.02, 0.42), control2: p(1.0, 0.68))
            path.addCurve(to: p(0.16, 0.78), control1: p(0.64, 0.98), control2: p(0.3, 1.0))
            path.addCurve(to: p(0.44, 0.48), control1: p(0.0, 0.6), control2: p(0.36, 0.62))
            path.addCurve(to: p(0.2, 0.3), control1: p(0.52, 0.36), control2: p(0.12, 0.44))
            path.closeSubpath()
        case .grain:
            let body = Path(ellipseIn: CGRect(x: rect.minX + w * 0.24, y: rect.minY, width: w * 0.52, height: h))
            path.addPath(body.applying(CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                .concatenating(CGAffineTransform(rotationAngle: .pi / 7))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))))
        case .almond:
            path.move(to: p(0.5, 0.0))
            path.addCurve(to: p(0.5, 1.0), control1: p(0.98, 0.3), control2: p(0.92, 0.9))
            path.addCurve(to: p(0.5, 0.0), control1: p(0.08, 0.9), control2: p(0.02, 0.3))
            path.closeSubpath()
        case .leaf:
            path.move(to: p(0.12, 0.9))
            path.addCurve(to: p(0.92, 0.08), control1: p(0.0, 0.3), control2: p(0.5, 0.0))
            path.addCurve(to: p(0.12, 0.9), control1: p(1.0, 0.5), control2: p(0.7, 1.0))
            path.closeSubpath()
        case .cap:
            path.move(to: p(0.04, 0.58))
            path.addCurve(to: p(0.96, 0.58), control1: p(0.04, 0.0), control2: p(0.96, 0.0))
            path.addLine(to: p(0.62, 0.62)); path.addLine(to: p(0.64, 0.96)); path.addLine(to: p(0.36, 0.96))
            path.addLine(to: p(0.38, 0.62)); path.closeSubpath()
        }
        return path
    }
}

extension Color {
    /// `#RRGGBB`, or nil for anything else.
    init?(foodHex hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Detail

/// The week's plants with where each came from, for checking and changing them. Removing a plant takes it off every
/// meal this week that held it; adding names a plant on one meal. Both save as the person's own edit, which wins over
/// the photo estimate and Open Food Facts.
public struct FoodPlantsDetailView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    private let week: FoodPlantWeek
    private let field: FoodSeedField
    private let sentence: String
    private let meals: [FoodMeal]
    private let remove: @MainActor @Sendable (String) async throws -> Void
    private let add: @MainActor @Sendable (String, UUID) async throws -> Void
    @State private var name = ""
    @State private var mealID: UUID?
    @State private var removing: FoodWeekPlant?
    @State private var working = false
    @State private var message: String?

    /// - Parameters:
    ///   - meals: this week's meals, the ones a plant can be added to.
    ///   - remove: takes the plant with this key off every meal this week.
    ///   - add: adds a plant by name to the meal with this id.
    public init(week: FoodPlantWeek, new: [FoodWeekPlant], today: String, hasEarlierWeeks: Bool, meals: [FoodMeal],
                remove: @escaping @MainActor @Sendable (String) async throws -> Void,
                add: @escaping @MainActor @Sendable (String, UUID) async throws -> Void) {
        self.week = week
        field = FoodSeedField(week: week, new: new)
        sentence = field.sentence(today: today, comparedWithEarlierWeeks: hasEarlierWeeks)
        self.meals = meals.filter { week.week.contains(localDay: $0.localDay) }.sorted { $0.occurredAt > $1.occurredAt }
        self.remove = remove; self.add = add
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprHeroNumber(Double(field.count), unit: "of \(FoodSeedField.slots)", color: .energy)
                    LooprText(sentence, style: .body, color: .inkSecondary).fixedSize(horizontal: false, vertical: true)
                    FoodSeedGrid(seeds: field.seeds)
                }
                if week.plants.isEmpty {
                    LooprText("Plants come from a photo estimate, the ingredients of a scanned barcode, or a name you add below.",
                              style: .body, color: .inkSecondary)
                } else {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprSectionHeader("Counted this week", detail: "Each plant once, with where it came from")
                        LooprCard(density: .flush) {
                            VStack(spacing: 0) {
                                ForEach(week.plants) { plant in
                                    row(plant)
                                    if plant.id != week.plants.last?.id { Divider().overlay(Color.loopr(.divider)) }
                                }
                            }
                        }
                    }
                }
                addSection
                if let message { LooprText(message, style: .body, color: .critical).accessibilityIdentifier("food-plants-error") }
            }
            .padding(LooprSpacing.screenGutter)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Plants this week")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("food-plants-done") } }
        .accessibilityIdentifier("food-plants-detail")
        .confirmationDialog(removing.map { "Remove \($0.name) from this week?" } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let plant = removing {
                Button("Remove from \(plant.itemCount == 1 ? "1 food" : "\(plant.itemCount) foods")", role: .destructive) {
                    run { try await remove(plant.key) }
                }.accessibilityIdentifier("food-plant-confirm-remove")
            }
        } message: { Text("It stays out of this week's count, even when a photo or a barcode finds it again on these foods.") }
    }

    private func row(_ plant: FoodWeekPlant) -> some View {
        HStack(spacing: LooprSpacing.sm) {
            FoodSeedGlyph(seed: FoodSeed(index: 0, plant: plant, shape: FoodSeedShape(plant.category),
                                         isNew: field.seeds.contains { $0.plant?.key == plant.key && $0.isNew },
                                         colorHex: FoodSeedField.color(for: plant)))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                LooprText(plant.name, style: .rowTitle)
                LooprText(details(plant), style: .caption, color: .inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LooprSpacing.xs)
            Button { removing = plant } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(working)
            .accessibilityLabel("Remove \(plant.name)")
            .accessibilityIdentifier("food-plant-remove-\(plant.key)")
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("food-plant-\(plant.key)")
    }

    private func details(_ plant: FoodWeekPlant) -> String {
        let sources = plant.sources.map(Self.sourceTitle).joined(separator: ", ")
        return [Self.categoryTitle(plant.category), sources, "first on \(weekday(plant.firstLocalDay))"].joined(separator: " · ")
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Add a plant", detail: meals.isEmpty ? "Log a meal this week to add plants to it" : "Saved as your edit on one meal")
            if !meals.isEmpty {
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        TextField("Plant name, such as fennel", text: $name)
                            .textInputAutocapitalization(.never)
                            .looprTypography(.body)
                            .frame(minHeight: LooprSpacing.interactiveRowHeight)
                            .accessibilityIdentifier("food-plant-add-name")
                        Picker("Meal", selection: Binding(get: { mealID ?? meals.first?.id }, set: { mealID = $0 })) {
                            ForEach(meals) { meal in
                                Text("\(meal.slot.title), \(weekday(meal.localDay))").tag(Optional(meal.id))
                            }
                        }
                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                        .accessibilityIdentifier("food-plant-add-meal")
                        Button {
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard let meal = mealID ?? meals.first?.id, !trimmed.isEmpty else { return }
                            run { try await add(trimmed, meal); name = "" }
                        } label: { Text("Add plant").frame(maxWidth: .infinity) }
                            .buttonStyle(LooprButtonStyle(accent: .energy))
                            .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("food-plant-add")
                    }
                }
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true; message = nil
        Task { @MainActor in
            do { try await work() }
            catch FoodError.invalidRecord { message = "That is not counted as a plant. Refined foods such as sugar, oil and white flour stay out." }
            catch { message = error.localizedDescription }
            working = false
        }
    }

    private func weekday(_ localDay: String) -> String {
        guard let days = FoodLocalDay.daysSinceEpoch(localDay) else { return localDay }
        var style = Date.FormatStyle().weekday(.abbreviated)
        style.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        style.locale = locale
        return Date(timeIntervalSince1970: Double(days) * 86_400).formatted(style)
    }

    static func sourceTitle(_ source: FoodPlantSource) -> String {
        switch source {
        case .edit: "your edit"
        case .openFoodFacts: "barcode ingredients"
        case .photoEstimate: "photo estimate"
        case .usda: "USDA table"
        }
    }

    static func categoryTitle(_ category: FoodPlantCategory?) -> String {
        switch category {
        case .vegetable?: "Vegetable"
        case .fruit?: "Fruit"
        case .legume?: "Legume"
        case .nut?: "Nut"
        case .seed?: "Seed"
        case .herb?: "Herb"
        case .spice?: "Spice"
        case .mushroom?: "Mushroom"
        case .wholeGrain?: "Whole grain"
        case nil: "Your plant"
        }
    }
}
