import BodyKit
import Combine
import DesignSystem
import DomainKit
import FoodKit
import ProfileKit
import SwiftUI

@MainActor
final class FoodOverviewModel: ObservableObject {
    @Published var day: FoodDaySummary?
    @Published var week: [FoodDaySummary] = []
    @Published var photos: [UUID: Image] = [:]
    @Published var error: String?
    @Published var targetWarning: String?
    /// Readings from the last 60 days. The card needs two weeks; the line shows 30 days.
    @Published var weights: [FoodWeightEntry] = []
    /// Finished days in the 120 days Food and your body reads. Nil when the count could not be read.
    @Published var finishedDays: Int?
    private var generation = 0
    let repository: AppFoodRepository
    private let bodyRepository: (any BodyRepository)?
    init(repository: AppFoodRepository, body: (any BodyRepository)?) {
        self.repository = repository; bodyRepository = body
    }
    func load(date: Date, calendar: Calendar) async {
        generation += 1; let token = generation
        error = nil; targetWarning = nil
        if day?.date != calendar.startOfDay(for: date) { day = nil; week = []; photos = [:] }
        do {
            let dates = try (-6...0).map { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: date) else { throw FoodError.invalidRecord }
                return date
            }
            let first = try FoodMeal.day(at: dates[0], timeZoneIdentifier: calendar.timeZone.identifier)
            let last = try FoodMeal.day(at: date, timeZoneIdentifier: calendar.timeZone.identifier)
            let data = try await repository.overview(from: first, through: last)
            var summaries: [FoodDaySummary] = []
            for date in dates {
                try Task.checkCancellation()
                let day = try await Self.summary(date: date, calendar: calendar, data: data, body: bodyRepository,
                                                 alwaysReadBody: (try? FoodMeal.day(at: date, timeZoneIdentifier: calendar.timeZone.identifier)) == last)
                if day.bodyFailed, token == generation { targetWarning = "Active energy could not be loaded. Targets use your base and planned allowances." }
                summaries.append(day.summary)
            }
            let photoIDs = summaries.last?.meals.flatMap(\.photos).map(\.id) ?? []
            let bytes = try await repository.photoBytes(ids: photoIDs)
            guard token == generation else { return }
            let readings = (try? await repository.weights(since: date.addingTimeInterval(-60 * 86_400))) ?? []
            guard token == generation else { return }
            // The same 120 days Food and your body reads, so its row can say how many finished days it still needs.
            var finished: Int?
            if let start = calendar.date(byAdding: .day, value: -119, to: date),
               let first = try? FoodMeal.day(at: start, timeZoneIdentifier: calendar.timeZone.identifier) {
                finished = try? await repository.finishedDayCount(from: first, through: last)
            }
            guard token == generation else { return }
            photos = bytes.compactMapValues { UIImage(data: $0).map { Image(uiImage: $0) } }
            weights = readings.filter { $0.measuredAt <= date.addingTimeInterval(86_400) }
            finishedDays = finished
            week = summaries; day = summaries.last
        } catch is CancellationError { }
        catch { if token == generation { self.error = error.localizedDescription } }
    }
    /// One day as the Food screen shows it: the target adds qualified active energy when the person chose that. Today
    /// and Ask build their food rows here too, so all three show the same target. A failed body read keeps the base
    /// target and reports `bodyFailed`. `alwaysReadBody` also reads the day's strain when the target does not adjust.
    nonisolated static func summary(date: Date, calendar: Calendar, data: FoodOverviewData, body: (any BodyRepository)?,
                                    alwaysReadBody: Bool = false) async throws -> (summary: FoodDaySummary, bodyFailed: Bool) {
        let base = try FoodDaySummary(date: date, calendar: calendar, data: data)
        guard let body, base.settings?.adjustsForActiveEnergy == true || alwaysReadBody else { return (base, false) }
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return (base, false) }
        do {
            guard let snapshot = try await body.readBodyDay(for: DayIdentity(era: parts.era ?? 1, year: year, month: month, day: day)) else {
                return (base, false)
            }
            let (energy, strain) = context(snapshot)
            return (try FoodDaySummary(date: date, calendar: calendar, data: data, active: energy, strain: strain), false)
        } catch is CancellationError { throw CancellationError() }
        catch { return (base, true) }
    }

    nonisolated static func context(_ body: BodyDaySnapshot) -> (FoodActiveEnergy?, FoodStrain?) {
        guard body.state == .partial || body.state == .measuredZero else { return (nil, nil) }
        let energy = body.metric(.energy).flatMap { metric -> FoodActiveEnergy? in
            guard metric.numericUnit == .kilocalories, let value = metric.numericValue, let version = metric.algorithmVersion,
                  metric.qualityQualified == true, metric.state != .stale else { return nil }
            return .init(energy: value, source: metric.source, algorithmVersion: version, hasUsableProfileAndWear: true)
        }
        let strain = body.metric(.strain).flatMap { metric -> FoodStrain? in
            guard metric.numericUnit == .strainScore, let value = metric.numericValue,
                  metric.qualityQualified == true, metric.state != .stale else { return nil }
            let result = FoodStrain(value: value, scale: .daily21)
            return result.isValid ? result : nil
        }
        return (energy, strain)
    }
}

private enum FoodSheet: Identifiable {
    case drink(FoodDrinkKind), targets, plan, weight, stack, plants
    var id: String {
        switch self {
        case .drink(let kind): "drink-\(kind.rawValue)"
        case .targets: "targets"
        case .plan: "plan"
        case .weight: "weight"
        case .stack: "stack"
        case .plants: "plants"
        }
    }
}

private enum FoodDetail {
    case entry(FoodMealDraft), capture(FoodMealDraft, voice: Bool), repeatMeal
}

/// What a toast's Undo takes back: a drink added from a row's plus, a meal logged again, or a finished day, with
/// whether finishing also marked no alcohol.
private enum FoodUndo {
    case drink(FoodDrink), meal(UUID), finish(markedNoAlcohol: Bool)
}

/// One opening of the food camera, for a meal slot.
private struct FoodLensRequest: Identifiable {
    let id = UUID()
    let slot: FoodMealSlot
    /// The camera mode it opens in. Blood tests' "Scan a report" opens Lab mode.
    var lens: FoodLensModel.Lens = .food
}

struct FoodTabRoot: View {
    @Environment(\.looprDayNavigation) private var navigation
    let repositories: ProductRepositoryContainer
    @StateObject private var model: FoodOverviewModel
    /// Plants, lens, stack, protocol targets and rail stickers.
    @StateObject private var longevity = FoodLongevityModel()
    @State private var sheet: FoodSheet?
    @State private var detail: FoodDetail?
    @State private var lens: FoodLensRequest?
    @State private var showDetail = false
    @State private var confirmComplete = false
    @State private var actionError: String?
    @State private var showAssociations = false
    /// The Week page, and what it pushes on top of itself: a meal from the eating window, and Food and your body.
    @State private var showWeek = false
    @State private var showWeekDetail = false
    @State private var showWeekAssociations = false
    @State private var suggestionProfile: FoodSuggestionProfile?
    /// Plays once for each finished save, delete or quick add on this tab.
    @State private var haptic: LooprHaptic?
    @State private var toast: LooprToastContent?
    /// Whether a photo estimate can run, which needs the person's own AI key. Nil until read.
    @State private var photoEstimates: Bool?
    /// What a toast's Undo removes.
    @State private var undo: FoodUndo?
    @Binding private var photoRequested: Bool
    @Binding private var labScanRequested: Bool

    /// - Parameter photoRequested: Ask sets this to open photo capture, the screen "Log a meal"
    ///   opens. The tab clears it once it has opened the screen.
    /// - Parameter labScanRequested: Blood tests' "Scan a report" sets this to open the camera in Lab mode.
    init(repositories: ProductRepositoryContainer, photoRequested: Binding<Bool> = .constant(false),
         labScanRequested: Binding<Bool> = .constant(false)) {
        self.repositories = repositories
        _photoRequested = photoRequested
        _labScanRequested = labScanRequested
        let repository: AppFoodRepository
        if let persistent = repositories.persistent {
            repository = AppFoodRepository(store: persistent.food, environment: repositories.environment)
        } else {
            #if DEBUG
            repository = repositories.fixtureFoodRepository
            #else
            repository = AppFoodRepository(environment: repositories.environment)
            #endif
        }
        _model = StateObject(wrappedValue: .init(repository: repository, body: repositories.persistent?.body))
    }

    private var calendar: Calendar {
        var result = navigation?.calendar ?? Calendar(identifier: .gregorian)
        result.timeZone = repositories.isFixtureComposition ? TimeZone(identifier: "Australia/Perth")! : repositories.environment.timeZoneProvider.timeZone
        return result
    }
    private var date: Date {
        navigation?.day.noon(in: calendar) ?? repositories.environment.dateProvider.now()
    }
    private var now: Date {
        repositories.isFixtureComposition ? TodayDialFixtureClock.now(sameDayAs: date, calendar: calendar) : repositories.environment.dateProvider.now()
    }
    var body: some View {
        // The minute clock moves the rail's "now" and the kitchen countdown while the tab is open.
        TimelineView(.everyMinute) { context in
            FoodScreen(day: model.day, week: model.week, photos: model.photos, error: model.error, targetWarning: model.targetWarning,
                weightTrend: FoodWeightTrend(model.weights), now: repositories.isFixtureComposition ? now : context.date,
                longevity: longevity.state, photoEstimates: photoEstimates, finishedDays: model.finishedDays, action: act,
                retry: { Task { await reload() } })
        }
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: date) {
                await reload()
                #if DEBUG
                // Screenshot tours open Type straight away: `--loopr-food-open=type`.
                if ProcessInfo.processInfo.arguments.contains("--loopr-food-open=type"), detail == nil { act(.manual) }
                #endif
            }
            .onChange(of: photoRequested, initial: true) { _, requested in
                guard requested else { return }
                photoRequested = false
                // Ask's sheet may still be closing; a cover presented during that is dropped.
                Task { try? await Task.sleep(for: .milliseconds(400)); act(.log(suggestedSlot)) }
            }
            .onChange(of: labScanRequested, initial: true) { _, requested in
                guard requested else { return }
                labScanRequested = false
                // The tab switch may still be animating; a cover presented during it is dropped.
                Task { try? await Task.sleep(for: .milliseconds(400)); lens = .init(slot: suggestedSlot, lens: .lab) }
            }
            .sheet(item: $sheet) { route in
                NavigationStack {
                    switch route {
                    case .drink(let kind):
                        FoodDrinkEditor(kind: kind, date: date, now: now, calendar: calendar, logged: model.day?.drinks ?? [],
                            delete: { @MainActor @Sendable drink in
                                try await model.repository.deleteDrink(id: drink.id)
                                haptic = LooprHaptic(.impact(weight: .medium))
                                await reload()
                            }) { @MainActor @Sendable drink in
                            try await model.repository.confirmDrink(drink)
                            haptic = .success
                            await reload()
                            longevity.settle()
                        }
                    case .targets:
                        FoodDayEditor(day: model.day, date: date, now: now, calendar: calendar, repository: model.repository,
                            isToday: isToday, openPlan: { openPlan() },
                            finish: {
                                // The same Done for today as the tab's row: the sheet closes, then the tab asks or finishes.
                                sheet = nil
                                Task { try? await Task.sleep(for: .milliseconds(450)); requestCompletion() }
                            },
                            didSave: { @MainActor @Sendable in await reload() })
                    case .plan:
                        if let profile = suggestionProfile {
                            planner(profile: profile)
                        } else {
                            ProgressView().task { await loadSuggestionProfile(now: now, calendar: calendar) }
                        }
                    case .stack:
                        FoodStackEditor(repository: model.repository, calendar: calendar, now: now) { @MainActor @Sendable in
                            await longevity.reloadStack(repository: model.repository)
                        }
                    case .plants:
                        plantsDetail
                    case .weight:
                        FoodWeightEditor(now: now, calendar: calendar, entries: model.weights,
                            save: { @MainActor @Sendable entry in try await saveWeight(entry) },
                            delete: { @MainActor @Sendable entry in
                                try await model.repository.deleteWeight(id: entry.id)
                                haptic = LooprHaptic(.impact(weight: .medium))
                                await reload()
                            })
                    }
                }
                .presentationDetents(Self.detents(route))
            }
            // A stored flag keeps the destination binding stable. A computed Binding is new on every
            // render, so each render queued another navigation request and re-rendered the shell.
            // A detail opened from the Week page pushes on top of it; one opened from the tab pushes from the root.
            .onChange(of: detail != nil, initial: true) { _, present in
                if showWeek { if showWeekDetail != present { showWeekDetail = present } }
                else if showDetail != present { showDetail = present }
            }
            .onChange(of: showDetail) { _, shown in if !shown, detail != nil, !showWeekDetail { detail = nil } }
            .onChange(of: showWeekDetail) { _, shown in if !shown, detail != nil, !showDetail { detail = nil } }
            .onChange(of: showWeek) { _, shown in if !shown { showWeekDetail = false; showWeekAssociations = false } }
            .navigationDestination(isPresented: $showDetail) { detailPage }
            .navigationDestination(isPresented: $showWeek) { weekPage }
            .confirmationDialog(completionTitle, isPresented: $confirmComplete, titleVisibility: .visible) {
                if model.day?.isCompleted == true {
                    Button("Reopen") { finishDay(noAlcohol: false) }.accessibilityIdentifier("food-confirm-completion")
                } else {
                    // The alcohol answer rides with finishing: "None today" is a real answer only at the end of the day.
                    // The dialog only opens while alcohol is unanswered.
                    Button(isToday ? "Done, no alcohol today" : "Done, no alcohol that day") { finishDay(noAlcohol: true) }
                        .accessibilityIdentifier("food-confirm-no-alcohol")
                    Button("Done") { finishDay(noAlcohol: false) }.accessibilityIdentifier("food-confirm-completion")
                }
                Button("Cancel", role: .cancel) {}.accessibilityIdentifier("food-cancel-completion")
            } message: { Text(completionMessage) }
            .alert("Food", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: { Text(actionError ?? "") }
            .fullScreenCover(item: $lens) { request in
                FoodLensView(draft: newDraft(slot: request.slot), repository: model.repository,
                    fixture: repositories.isFixtureComposition, now: now, day: FoodBurstDay(model.day), lens: request.lens,
                    close: { @MainActor @Sendable in lens = nil },
                    save: { @MainActor @Sendable draft in try await model.repository.confirm(draft, at: now) },
                    finished: { @MainActor @Sendable draft in
                        lens = nil
                        // The finish left its dots on the rings: they settle there once more.
                        longevity.settle()
                        toast = .init("\(draft.slot.title) saved", accent: .energy)
                        Task { await reload() }
                    })
            }
            .navigationDestination(isPresented: $showAssociations) { associations }
            .looprHaptic(haptic)
            .looprToast($toast) { undoLast() }
            .productStorageGate(repositories)
    }
    @ViewBuilder private var detailPage: some View {
        if let detail {
            switch detail {
            case .capture(let draft, let voice):
                FoodCaptureView(draft: draft, beginVoice: voice, repository: model.repository,
                    fixture: repositories.isFixtureComposition, now: now,
                    close: { @MainActor @Sendable in self.detail = nil },
                    repeatMeal: { @MainActor @Sendable in self.detail = .repeatMeal }) { @MainActor @Sendable draft in
                        try await confirm(draft)
                    }
            case .entry(let draft):
                FoodReviewView(draft: draft, repository: model.repository, now: now,
                    fixture: repositories.isFixtureComposition,
                    delete: draft.expectedRevision.map { revision in { @MainActor @Sendable in
                        try await model.repository.deleteMeal(id: draft.id, expectedRevision: revision)
                        await reload()
                        self.detail = nil
                    } }, cancel: { @MainActor @Sendable in self.detail = nil }) { @MainActor @Sendable draft in
                        try await confirm(draft)
                    }
            case .repeatMeal:
                FoodRepeatPicker(repository: model.repository, recent: model.week.flatMap(\.meals), slot: suggestedSlot, now: now,
                    timeZoneIdentifier: calendar.timeZone.identifier) { @MainActor @Sendable draft in
                        self.detail = .entry(draft)
                    }
            }
        }
    }
    @ViewBuilder private var weekPage: some View {
        if let day = model.day {
            FoodWeekPage(day: day, week: model.week, weightTrend: FoodWeightTrend(model.weights), now: now, longevity: longevity.state,
                         finishedDays: model.finishedDays, action: act)
                .environment(\.calendar, calendar)
                .environment(\.timeZone, calendar.timeZone)
                .navigationDestination(isPresented: $showWeekDetail) { detailPage }
                .navigationDestination(isPresented: $showWeekAssociations) { associations }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.loopr(.background))
        }
    }
    private var associations: some View {
        FoodAssociationRoot(repository: model.repository, repositories: repositories, date: date, calendar: calendar,
                            fibreTarget: longevity.state.targets.fibreGrams)
    }
    private var isToday: Bool { calendar.isDate(now, inSameDayAs: date) }
    private var completionTitle: String {
        if model.day?.isCompleted == true { return "Reopen this day?" }
        return "\(FoodScreen.doneTitle(isToday: isToday))?"
    }
    private var completionMessage: String {
        if model.day?.isCompleted == true { return "Food stops counting this day in your week and your rules until you finish it again." }
        return "Finished days count toward your week and your rules. No alcohol is logged."
    }
    /// Done for today, from the tab's row or the day sheet. A finished day asks before reopening. Otherwise it asks
    /// only while alcohol is unanswered, and finishes at once when it is answered (UX R2-MAC-10, R2-DES-13).
    private func requestCompletion() {
        guard let day = model.day else { return }
        if day.isCompleted || (!day.logsAlcohol && day.record?.noAlcoholAt == nil) { confirmComplete = true }
        else { finishDay(noAlcohol: false) }
    }
    /// Finishes the shown day, marking no alcohol first when asked, with an Undo that reopens it; or reopens a finished one.
    private func finishDay(noAlcohol: Bool) {
        Task {
            do {
                if let day = model.day, day.isCompleted {
                    try await model.repository.reopen(day.localDay)
                    haptic = .light
                    await reload()
                } else {
                    if noAlcohol { try await model.repository.setNoAlcohol(true, on: date, zone: calendar.timeZone.identifier, at: now) }
                    try await model.repository.complete(on: date, zone: calendar.timeZone.identifier, at: now)
                    haptic = .success
                    undo = .finish(markedNoAlcohol: noAlcohol)
                    await reload()
                    toast = .init(FoodScreen.doneTitle(isToday: isToday), symbol: "checkmark.circle.fill", accent: .brand, actionTitle: "Undo")
                }
            } catch { haptic = .error; actionError = error.localizedDescription }
        }
    }
    private func confirm(_ draft: FoodMealDraft) async throws {
        try await model.repository.confirm(draft, at: now)
        haptic = .success
        await reload()
        detail = nil
        // Every save settles the rings, as the camera's finish does (UX R2-DES-05).
        longevity.settle()
        toast = .init("\(draft.slot.title) saved", accent: .energy)
    }
    /// Logs a common drink straight away and offers Undo, so a glass of water is one tap.
    private func quickDrink(_ preset: FoodDrinkPreset) {
        do {
            let macros: [FoodNutrient: Double] = preset.kind == .water ? [:] : [.protein: preset.protein, .carbs: preset.carbs, .fat: preset.fat]
            let drink = try FoodDrink(kind: preset.kind, name: preset.kind == .water ? "Water" : preset.name,
                occurredAt: drinkTime, timeZoneIdentifier: calendar.timeZone.identifier,
                waterMillilitres: preset.kind == .water ? preset.amount : nil,
                caffeineMilligrams: preset.kind == .caffeine ? preset.amount : 0, alcoholUnits: preset.kind == .alcohol ? preset.amount : 0,
                energy: preset.energy, additionalNutrients: macros.isEmpty ? nil : FoodNutrients(macros), confirmedAt: now)
            log(drink)
        } catch {
            haptic = .error
            actionError = error.localizedDescription
        }
    }
    /// Logs a copy of the newest drink of its kind now, what a drink row's plus repeats (UX R2-MAC-08, R2-DES-08).
    private func repeatDrink(_ last: FoodDrink) {
        do {
            let drink = try FoodDrink(kind: last.kind, name: last.name, occurredAt: drinkTime, timeZoneIdentifier: calendar.timeZone.identifier,
                waterMillilitres: last.waterMillilitres, caffeineMilligrams: last.caffeineMilligrams, alcoholUnits: last.alcoholUnits,
                energy: last.energy, additionalNutrients: last.additionalNutrients, confirmedAt: now)
            log(drink)
        } catch {
            haptic = .error
            actionError = error.localizedDescription
        }
    }
    /// Now on today, the shown day at noon on another.
    private var drinkTime: Date { calendar.isDate(now, inSameDayAs: date) ? now : date }
    /// Saves a one-tap drink, settles the rings and offers Undo in a toast that names it: "Flat white added".
    private func log(_ drink: FoodDrink) {
        Task {
            do {
                try await model.repository.confirmDrink(drink)
                undo = .drink(drink)
                await reload()
                longevity.settle()
                let name = drink.kind == .water ? "\(FoodScreen.millilitres(drink.waterMillilitres)) ml of water" : drink.name
                toast = .init("\(name) added", symbol: drink.kind.symbol, accent: drink.kind == .water ? .brand : .energy, actionTitle: "Undo")
            } catch {
                haptic = .error
                actionError = error.localizedDescription
            }
        }
    }
    /// Logs a copy of `meal` in its slot straight away, at the time of day it was eaten, and offers Undo.
    private func logAgain(_ meal: FoodMeal) {
        Task {
            do {
                let draft = FoodMealDraft.repeating(meal, at: againTime(meal), timeZoneIdentifier: calendar.timeZone.identifier)
                try await model.repository.confirm(draft, at: now)
                haptic = .success
                undo = .meal(draft.id)
                await reload()
                longevity.settle()
                // The toast names the meal, so a one-tap repeat is checkable before Undo goes (UX R2-NEW-09, R2-DES-07).
                toast = .init("\(draft.slot.title) added. \(meal.namesLine)", accent: .energy, actionTitle: "Undo")
            } catch {
                haptic = .error
                actionError = error.localizedDescription
            }
        }
    }
    /// The shown day at the meal's own time of day, so the eating window stays true. Today never runs past now.
    private func againTime(_ meal: FoodMeal) -> Date {
        var source = calendar
        source.timeZone = TimeZone(identifier: meal.timeZoneIdentifier) ?? calendar.timeZone
        let parts = source.dateComponents([.hour, .minute], from: meal.occurredAt)
        guard let hour = parts.hour, let minute = parts.minute,
              let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: date)) else {
            return isToday ? now : date
        }
        return isToday ? min(time, now) : time
    }
    private func undoLast() {
        guard let last = undo else { return }
        undo = nil
        Task {
            do {
                switch last {
                case .drink(let drink): try await model.repository.deleteDrink(id: drink.id)
                case .meal(let id):
                    guard let meal = model.day?.meals.first(where: { $0.id == id }) else { return }
                    try await model.repository.deleteMeal(id: id, expectedRevision: meal.revision)
                case .finish(let markedNoAlcohol):
                    guard let day = model.day, day.isCompleted else { return }
                    try await model.repository.reopen(day.localDay)
                    if markedNoAlcohol { try await model.repository.setNoAlcohol(false, on: date, zone: calendar.timeZone.identifier, at: now) }
                }
                haptic = .light
                await reload()
            } catch { actionError = error.localizedDescription }
        }
    }
    private func reload() async {
        await loadPhotoEstimates()
        await model.load(date: date, calendar: calendar)
        await longevity.load(repository: model.repository, date: date, calendar: calendar, day: model.day,
                             bodyWeightKilograms: FoodWeightTrend(model.weights)?.current)
    }
    /// Reads whether an AI key is saved, so the camera tile can say up front what it can do without one.
    private func loadPhotoEstimates() async {
        #if DEBUG
        let runtime = repositories.isFixtureComposition ? FoodProviderFixtures.runtime() : LooprAISettingsRuntime.shared
        #else
        let runtime = LooprAISettingsRuntime.shared
        #endif
        guard let provider = try? await runtime.selectedConfiguration() else { photoEstimates = false; return }
        photoEstimates = await runtime.credentialAvailable(provider)
    }
    /// Ticks or clears a dose. A taken dose plays the kept-rule success; a cleared one a light tap.
    private func toggle(_ capsule: FoodCapsule) {
        Task {
            do {
                let took = try await longevity.toggle(capsule, repository: model.repository, at: now)
                haptic = took ? .ruleKept : .light
            } catch {
                haptic = .error
                actionError = error.localizedDescription
            }
        }
    }
    @ViewBuilder private var plantsDetail: some View {
        if let plants = longevity.state.plants {
            FoodPlantsDetailView(week: plants, new: longevity.state.newPlants,
                today: (try? FoodMeal.day(at: date, timeZoneIdentifier: calendar.timeZone.identifier)) ?? plants.week.lastDay,
                hasEarlierWeeks: longevity.state.hasEarlierWeeks, meals: longevity.weekMeals,
                remove: { @MainActor @Sendable key in
                    try await model.repository.removePlant(key: key, week: plants.week, at: now)
                    haptic = .light
                    await reload()
                },
                add: { @MainActor @Sendable name, meal in
                    try await model.repository.addPlant(named: name, toMeal: meal, at: now)
                    haptic = .success
                    await reload()
                })
        } else {
            LooprText("This week's plants could not be loaded.", style: .body, color: .inkSecondary).padding()
        }
    }
    private func act(_ action: FoodOverviewAction) {
        switch action {
        case .drink(let kind): sheet = .drink(kind)
        case .targets: sheet = .targets
        case .plan: openPlan()
        case .logWeight: sheet = .weight
        case .completion: requestCompletion()
        case .associations: if showWeek { showWeekAssociations = true } else { showAssociations = true }
        case .week: showWeek = true
        case .log(let slot): lens = .init(slot: slot)
        case .voice: detail = .capture(newDraft(slot: suggestedSlot), voice: true)
        case .manual: detail = .capture(newDraft(slot: suggestedSlot), voice: false)
        case .typeMeal(let slot): detail = .capture(newDraft(slot: slot), voice: false)
        case .again(let meal): logAgain(meal)
        case .quickDrink(let preset): quickDrink(preset)
        case .repeatDrink(let drink): repeatDrink(drink)
        case .repeatMeal: detail = .repeatMeal
        case .stackTick(let capsule): toggle(capsule)
        case .editStack: sheet = .stack
        case .plants: sheet = .plants
        case .edit(let meal):
            Task {
                do { detail = .entry(try await model.repository.editDraft(id: meal.id)) }
                catch { actionError = error.localizedDescription }
            }
        }
    }
    /// Drinks and weight fit a medium sheet and can grow; the day sheet, planner, plants and stack open large (UX R2-DES-11).
    private static func detents(_ route: FoodSheet) -> Set<PresentationDetent> {
        switch route {
        // The drink sheet's fields did not fit a medium sheet (R3-DES-03); weight does.
        case .weight: [.medium, .large]
        case .drink, .targets, .plan, .stack, .plants: [.large]
        }
    }
    /// The slot Speak, Manual and Ask start a log in, the same one the Log tiles offer.
    private var suggestedSlot: FoodMealSlot {
        FoodMealSlot.toLog(at: now, calendar: calendar, logged: Set(model.day?.meals.map(\.slot) ?? [])).slot
    }
    private func newDraft(slot: FoodMealSlot) -> FoodMealDraft {
        .init(slot: slot, occurredAt: calendar.isDate(now, inSameDayAs: date) ? now : date,
            timeZoneIdentifier: calendar.timeZone.identifier, items: [])
    }
}

extension FoodTabRoot {
    /// Reads the profile for the planner. A missing or unreadable profile starts the planner empty.
    @MainActor fileprivate func loadSuggestionProfile(now: Date, calendar: Calendar) async {
        let profile = try? await repositories.persistent?.profile.readProfile()
        suggestionProfile = profile.map { FoodSuggestionProfile($0, year: calendar.component(.year, from: now)) }
            ?? FoodSuggestionProfile(age: nil, sex: .unspecified, heightCentimetres: nil, weightKilograms: nil)
    }

    @MainActor fileprivate func openPlan() {
        suggestionProfile = nil
        sheet = .plan
    }

    @MainActor fileprivate func planner(profile: FoodSuggestionProfile) -> some View {
        FoodPlannerView(now: now, calendar: calendar, previous: model.day?.settings, profile: profile,
            latestWeight: FoodWeightTrend(model.weights)?.latest.kilograms,
            saveTarget: { @MainActor @Sendable target in
                try await model.repository.confirmTarget(target)
                haptic = .success
                await reload()
            },
            saveProfile: { @MainActor @Sendable about in try await saveProfile(about) },
            logWeight: { @MainActor @Sendable kilograms in
                let entry = try FoodWeightEntry(measuredAt: now, timeZoneIdentifier: calendar.timeZone.identifier, kilograms: kilograms)
                try await model.repository.saveWeight(entry)
                await reload()
            })
    }

    /// Saves a reading. The newest reading also becomes the profile weight, which energy estimates read.
    @MainActor fileprivate func saveWeight(_ entry: FoodWeightEntry) async throws {
        try await model.repository.saveWeight(entry)
        haptic = .success
        if entry.measuredAt >= (model.weights.map(\.measuredAt).max() ?? .distantPast), let repository = repositories.persistent?.profile,
           var draft = try await repository.readProfile()?.draft() {
            draft.weightKilograms = (entry.kilograms * 10).rounded() / 10
            _ = try? await repository.saveProfile(draft)
        }
        await reload()
    }

    /// Writes what the planner asked for back to the profile. Fields left empty keep the profile's value.
    @MainActor fileprivate func saveProfile(_ about: FoodSuggestionProfile) async throws {
        guard let repository = repositories.persistent?.profile else { return }
        var draft = try await repository.readProfile()?.draft() ?? ProfileDraft()
        let year = calendar.component(.year, from: now)
        if let age = about.age { draft.birthYear = year - age }
        switch about.sex {
        case .female: draft.biologicalSex = .female
        case .male: draft.biologicalSex = .male
        case .unspecified: break
        }
        if let height = about.heightCentimetres { draft.heightCentimeters = height }
        if let weight = about.weightKilograms { draft.weightKilograms = (weight * 10).rounded() / 10 }
        _ = try await repository.saveProfile(draft)
    }
}

extension FoodSuggestionProfile {
    init(_ profile: Profile, year: Int) {
        let sex: FoodGoalPlanner.Sex = switch profile.biologicalSex {
        case .female: .female
        case .male: .male
        default: .unspecified
        }
        self.init(age: profile.birthYear.map { year - $0 }, sex: sex,
                  heightCentimetres: profile.heightCentimeters, weightKilograms: profile.weightKilograms)
    }
}
