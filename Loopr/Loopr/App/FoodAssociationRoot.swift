import Combine
import DesignSystem
import DomainKit
import FoodKit
import JournalKit
import SwiftUI
import WorkoutKit

@MainActor final class FoodAssociationModel: ObservableObject {
    @Published var report: FoodAssociationReport?
    @Published var error: String?
    @Published var loading = false
    /// The pattern Patterns found for a last meal after 21:00, the one Today's card and Protocol show. Food leads with
    /// it, so the same relationship never reads "not enough days" here and "Strong" there (ICP R2-OPT-20).
    @Published var latePattern: FoundPattern?
    private var generation = UUID()
    private(set) var detailStore: InMemoryHabitStore?
    func load(repository: AppFoodRepository, repositories: ProductRepositoryContainer, date: Date, calendar: Calendar) async {
        let token = UUID(); generation = token; loading = true; error = nil; report = nil; detailStore = nil
        defer { if generation == token { loading = false } }
        do {
            guard let start = calendar.date(byAdding: .day, value: -119, to: date) else { throw FoodError.invalidRecord }
            let data = try await repository.overview(from: FoodMeal.day(at: start, timeZoneIdentifier: calendar.timeZone.identifier),
                                                     through: FoodMeal.day(at: date, timeZoneIdentifier: calendar.timeZone.identifier))
            let workouts = await repositories.workoutStore?.all()
            // 120 days of input are built off the main actor; only repository and resolver calls hop back.
            let input = try await Self.prepare(data: data, workouts: workouts, endingOn: date, calendar: calendar)
            var outcomes: [HabitOutcomeSnapshot] = []
            var exclusions: [HabitOutcomeExclusionRecord] = []
            if let persistent = repositories.persistent {
                let resolver = AppHabitOutcomeResolver(today: persistent.today, sleep: persistent.sleep, heart: persistent.heart,
                    calendar: repositories.environment.calendarProvider, dateProvider: repositories.environment.dateProvider)
                for record in input.records {
                    try Task.checkCancellation()
                    switch await resolver.resolve(record: record) {
                    case .outcome(let outcome): outcomes.append(outcome)
                    case .excluded(let exclusion): exclusions.append(exclusion)
                    }
                }
            } else {
                #if DEBUG
                if repositories.isFixtureComposition {
                    outcomes = await Task.detached(priority: .userInitiated) { FoodAssociationFixtures.outcomes(input: input) }.value
                }
                #endif
            }
            let now = repositories.environment.dateProvider.now()
            let frozenOutcomes = outcomes, frozenExclusions = exclusions
            let analysis = Task.detached(priority: .userInitiated) {
                try await input.analyze(outcomes: frozenOutcomes, exclusions: frozenExclusions, at: now)
            }
            let result = try await withTaskCancellationHandler { try await analysis.value } onCancel: { analysis.cancel() }
            try Task.checkCancellation()
            guard generation == token else { return }
            report = result
            latePattern = await Self.latePattern(repositories: repositories)
            guard generation == token else { return }
            detailStore = .init(definitions: input.definitions, dayRecords: input.screenRecords, outcomes: outcomes,
                outcomeExclusions: exclusions, estimates: result.estimates)
        } catch is CancellationError { }
        catch { if generation == token { self.error = error.localizedDescription; report = nil; detailStore = nil } }
    }
    /// Read where Today's pattern card reads it (`TodayAgentLoader.patternsSnapshot`).
    private static func latePattern(repositories: ProductRepositoryContainer) async -> FoundPattern? {
        guard LooprPatternsRuntime.isEnabled else { return nil }
        let snapshot: PatternsSnapshot?
        if let persistent = repositories.persistent {
            guard let engine = try? LooprPatternsRuntime.shared.configure(persistent) else { return nil }
            snapshot = try? await engine.snapshot()
        } else {
            #if DEBUG
            snapshot = repositories.isFixtureComposition ? try? await PatternsFixtures.shared().engine.snapshot() : nil
            #else
            snapshot = nil
            #endif
        }
        return snapshot?.found.first { $0.candidateID == LooprPatternExposureProvider.lateDinner.id }
    }
    private nonisolated static func prepare(data: FoodOverviewData, workouts: [WorkoutRecord]?, endingOn date: Date,
                                            calendar: Calendar) async throws -> FoodAssociationInput {
        try await Task.detached(priority: .userInitiated) {
            let completed = workouts?.filter { $0.state == .completed }
            let training = try completed.map { workouts in
                Set(try data.days.compactMap { day -> String? in
                    let trained = try workouts.contains { workout in
                        guard let start = workout.startedAt, workout.endedAt != nil else { return false }
                        return try FoodMeal.day(at: start, timeZoneIdentifier: day.timeZoneIdentifier) == day.localDay
                    }
                    return trained ? day.localDay : nil
                })
            }
            return try FoodAssociationInput(data: data, endingOn: date, calendar: calendar, trainingDays: training)
        }.value
    }
}

private struct FoodAssociationSelection: Hashable, Identifiable { let kind: FoodAssociationKind; var id: Int { kind.rawValue } }
struct FoodAssociationRoot: View {
    let repository: AppFoodRepository
    let repositories: ProductRepositoryContainer
    let date: Date
    let calendar: Calendar
    /// The protocol's fibre target, the one Food's fibre tile fills to. Nil keeps the 30 g reference.
    var fibreTarget: Double? = nil
    @StateObject private var model = FoodAssociationModel()
    @State private var selection: FoodAssociationSelection?
    var body: some View {
        ZStack {
            if let report = model.report {
                FoodAssociationScreen(report: report, comparisonsEnabled: AppHabitFeatureGate.currentStage.exposesEntryPoints,
                                      latePattern: model.latePattern.map(FoodLatePattern.init), fibreTarget: fibreTarget) { selection = .init(kind: $0) }
            } else {
                ScrollView {
                    LooprCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            StateMessage(model.error == nil ? .loading : .recoverableError)
                            if let error = model.error {
                                LooprText(error, style: .body, color: .inkSecondary)
                                Button("Try again") { Task { await load() } }.buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-body-retry")
                            }
                        }
                    }.padding(LooprSpacing.screenGutter)
                }.background(Color.loopr(.background))
            }
        }
        .navigationTitle("Food and your body").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar).looprAskToolbar(origin: "Food and your body")
        .task(id: date) { await load() }
        .navigationDestination(item: $selection) { selection in
            if let store = model.detailStore { FoodAssociationDetail(store: store, kind: selection.kind) }
        }
    }
    private func load() async { await model.load(repository: repository, repositories: repositories, date: date, calendar: calendar) }
}
private struct FoodAssociationDetail: View {
    @StateObject private var model: HabitViewModel
    let kind: FoodAssociationKind
    init(store: InMemoryHabitStore, kind: FoodAssociationKind) {
        self.kind = kind
        _model = StateObject(wrappedValue: HabitViewModel(store: store, featureStageOverride: AppHabitFeatureGate.currentStage))
    }
    var body: some View {
        HabitDetailScreen(viewModel: model, habitID: kind.id, target: kind.target)
            .looprAskToolbar(origin: "Food comparison")
    }
}

/// The found late-meal pattern as Food shows it: Patterns' own headline and caption, word for word.
struct FoodLatePattern: Equatable {
    let headline: String
    /// "Strong · 41 nights"
    let caption: String
    let nights: Int
    init(_ pattern: FoundPattern) {
        headline = PatternsCopy.headline(pattern)
        caption = PatternsCopy.caption(pattern)
        nights = pattern.nights.total
    }
    init(headline: String, caption: String, nights: Int) { self.headline = headline; self.caption = caption; self.nights = nights }
}
