import DesignSystem
import EventKit
import Foundation
import Testing
import TrainKit
import WorkoutKit
@testable import Loopr

/// Programs against the seeded fixture database: Alex, Australia/Perth, Tuesday 2023-11-14.
@MainActor struct TrainProgramIntegrationTests {
    private static func repository() -> AppTrainRepository {
        AppTrainRepository(environment: AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:]), seedsFixture: true)
    }

    private static func loader(_ repository: AppTrainRepository) -> TrainOverviewLoader {
        TrainOverviewLoader(repository: repository, workouts: InMemoryWorkoutStore(workouts: AppTrainFixtures.workoutRecords))
    }

    private static func load(_ loader: TrainOverviewLoader) async {
        await loader.load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
    }

    private static func addDraft(_ repository: AppTrainRepository) async throws -> Program {
        try await repository.createProgramDraft(json: AppTrainFixtures.draftJSON, library: nil, defaultStartDay: AppTrainFixtures.draftStartDay,
                                                at: AppTrainFixtures.now)
    }

    // MARK: Drafts

    @Test func theFixtureDraftDecodesStoresAndStaysOutOfThePlan() async throws {
        let repository = Self.repository()
        let draft = try await Self.addDraft(repository)
        #expect(draft.status == .draft && draft.source == .agent && draft.name == "Spring base")
        #expect(draft.pendingTemplates?.map(\.name) == ["Easy ride"])
        #expect(try await repository.templates().map(\.name) == ["Lower A", "Lower B", "Upper A", "Upper B", "Zone 2"])

        let loader = Self.loader(repository)
        await Self.load(loader)
        let overview = try #require(loader.overview)
        #expect(overview.drafts.map(\.name) == ["Spring base"] && overview.drafts.first?.slug == "spring-base")
        #expect(overview.drafts.first?.caption == "4 weeks · 4 days a week")
        #expect(overview.programs.map(\.name) == ["Strength block", "Half marathon"])
        #expect(overview.headerMeta == "Week 3 of 8 · Strength block")
        // The week strip and today read the active program only.
        #expect(overview.week.map(\.caption).contains("Easy ride") == false)
    }

    @Test func acceptMovesTheDraftIntoProgramsAndSavesItsTemplate() async throws {
        let repository = Self.repository()
        _ = try await Self.addDraft(repository)
        let loader = Self.loader(repository)
        await Self.load(loader)
        let draft = try #require(loader.overview?.drafts.first)
        let problem = await loader.accept(draft, now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        #expect(problem == nil)
        let overview = try #require(loader.overview)
        #expect(overview.drafts.isEmpty)
        let row = try #require(overview.programs.first { $0.name == "Spring base" })
        #expect(row.status == .active && row.caption == "4 weeks · starts 20 Nov")
        #expect(try await repository.templates().map(\.name).contains("Easy ride"))
        // A second tap on the same stale draft cannot act again.
        let again = await loader.accept(draft, now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        #expect(again != nil)
    }

    @Test func discardDeletesTheDraftAndLeavesTemplatesAlone() async throws {
        let repository = Self.repository()
        _ = try await Self.addDraft(repository)
        let loader = Self.loader(repository)
        await Self.load(loader)
        let draft = try #require(loader.overview?.drafts.first)
        let problem = await loader.discard(draft, now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        #expect(problem == nil && loader.overview?.drafts.isEmpty == true)
        #expect(try await repository.programs().map(\.name).sorted() == ["Half marathon", "Strength block"])
        #expect(try await repository.templates().map(\.name).contains("Easy ride") == false)
    }

    @Test func aRefusedDraftStoresNothing() async throws {
        let repository = Self.repository()
        let bad = AppTrainFixtures.draftJSON.replacingOccurrences(of: "\"Upper B\"", with: "\"Upper C\"")
        await #expect(throws: ProgramDraftError.unknownTemplate("Upper C")) {
            _ = try await repository.createProgramDraft(json: bad, library: nil, defaultStartDay: "2023-11-20", at: AppTrainFixtures.now)
        }
        #expect(try await repository.programs().count == 2)
    }

    // MARK: Rules

    @Test func theEarlyLightDecisionIsSavedOnceAndLeavesWeekThreeAsPlanned() async throws {
        let repository = Self.repository()
        let loader = Self.loader(repository)
        await Self.load(loader)
        var block = try #require(try await repository.programs().first { $0.name == "Strength block" })
        #expect(block.adjustments.map(\.kind) == [.earlyLightDeclined] && block.adjustments.first?.week == 3)
        let revision = block.revision
        await Self.load(loader)
        block = try #require(try await repository.programs().first { $0.name == "Strength block" })
        #expect(block.revision == revision && block.adjustments.count == 1)
    }

    @Test func rulesChangeAgainstTheStoredProgram() async throws {
        let repository = Self.repository()
        let id = AppTrainFixtures.strengthBlockID
        let first = try await repository.updateProgramRules(id: id, at: AppTrainFixtures.now) { var rules = $0; rules.earlyLightWeek = false; return rules }
        let second = try await repository.updateProgramRules(id: id, at: AppTrainFixtures.now) { var rules = $0; rules.missed = .skip; return rules }
        #expect(first.rules.earlyLightWeek == false && second.rules.earlyLightWeek == false && second.rules.missed == .skip)
        #expect(second.revision == first.revision + 1)
        #expect(try await repository.program(id: id)?.rules == second.rules)
    }

    // MARK: Screen

    @Test func theProgramScreenReadsSessionsDoneAndTheEstimatedMaxFromStoredSessions() async throws {
        let repository = Self.repository()
        let program = try #require(try await repository.program(id: AppTrainFixtures.strengthBlockID))
        let templates = try await repository.templates()
        let sessions = try await repository.recentSessions(limit: 100, status: .completed)
        let model = ProgramScreenModel(ProgramScreenInput(program: program, templates: templates, sessions: sessions,
                                                          now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar))
        #expect(model.soFar?.sessionsValue == "3 of 12")
        #expect(model.soFar?.liftTitle == "Back squat, estimated max" && model.soFar?.liftValue == "120 → 127 kg")
        #expect(model.lighterCaption == "Weeks 4 and 7 are lighter")
        #expect(model.grid[2].days[1]?.isCurrent == true && model.grid[2].days[1]?.spokenName == "Upper A")
    }

    @Test func todayCarriesThePlannedTime() async throws {
        let loader = Self.loader(Self.repository())
        await Self.load(loader)
        guard case .plan(let plan) = loader.overview?.today else { Issue.record("expected a plan"); return }
        #expect(plan.name == "Upper A" && plan.startMinute == 18 * 60 + 30)
    }

    // MARK: Calendar

    @Test func exportWritesUpcomingSessionsAndRemovesThemWhenTurnedOff() async throws {
        let repository = Self.repository()
        var program = try #require(try await repository.program(id: AppTrainFixtures.strengthBlockID))
        program.rules.calendarExport = true
        let templates = try await repository.templates()
        let writer = FixtureTrainCalendar(grants: true)
        let sync = TrainCalendarSync(writer: writer)
        let context = ProgramScheduler.Context(now: AppTrainFixtures.now)
        let outcome = await sync.turnOn(program: program, templates: templates, context: context, calendar: AppTrainFixtures.calendar)
        guard case .synced(let result) = outcome else { Issue.record("expected synced, got \(outcome)"); return }
        #expect(result.created > 0)
        let again = await sync.refresh(program: program, templates: templates, context: context, calendar: AppTrainFixtures.calendar)
        guard case .synced(let second) = again else { Issue.record("expected synced"); return }
        #expect(second.created == 0 && second.updated == result.created)
        guard case .cleared(let removed) = await sync.clear(programID: program.id) else { Issue.record("expected cleared"); return }
        #expect(removed.removed == result.created)
    }

    @Test func deniedAccessShowsTheSettingsMessage() async throws {
        let program = try #require(try await Self.repository().program(id: AppTrainFixtures.strengthBlockID))
        let outcome = await TrainCalendarSync(writer: FixtureTrainCalendar(grants: false))
            .turnOn(program: program, templates: [], context: .init(now: AppTrainFixtures.now), calendar: AppTrainFixtures.calendar)
        #expect(outcome == .denied)
    }

    @Test func eventKitStatusesMapToThePermissionLooprNeeds() {
        #expect(EventKitTrainCalendar.map(.writeOnly) == .granted && EventKitTrainCalendar.map(.fullAccess) == .granted)
        #expect(EventKitTrainCalendar.map(.notDetermined) == .notDetermined)
        #expect(EventKitTrainCalendar.map(.denied) == .denied && EventKitTrainCalendar.map(.restricted) == .denied)
    }
}
