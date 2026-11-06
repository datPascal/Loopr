import DesignSystem
import DomainKit
import SwiftUI
import TrainKit
import UIKit

extension ProductRepositoryContainer {
    /// The Train repository for this composition. Production reads the app's own database. Every other
    /// composition reads a separate temporary one, so a fixture never writes into real data.
    @MainActor var trainProgramRepository: AppTrainRepository {
        if let persistent {
            return AppTrainRepository(store: persistent.train, environment: environment)
        }
        #if DEBUG
        return fixtureTrainRepository
        #else
        return AppTrainRepository(environment: environment)
        #endif
    }

    /// The clock the Train screens plan with. Fixture launches pin the day and the zone.
    @MainActor var trainProgramClock: (now: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        #if DEBUG
        if isFixtureComposition, AppTrainFixtures.isRequested() { return (AppTrainFixtures.now, AppTrainFixtures.calendar) }
        #endif
        calendar.timeZone = environment.timeZoneProvider.timeZone
        return (environment.dateProvider.now(), calendar)
    }
}

/// One program: the plan as a grid, its rules and how it is going. Also where an agent draft is accepted or discarded.
///
/// Storage runs in `AppTrainRepository`, which keeps SQLite off the main actor. Calendar permission is
/// requested only from the Add to Calendar switch.
struct TrainProgramRoot: View {
    let programID: UUID

    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @Environment(\.looprAsk) private var ask
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var calendarDenied = false
    @State private var problem: String?
    @State private var showsEditor = false
    @State private var writer: any TrainCalendarWriter = TrainCalendarWriters.make()

    private struct Loaded {
        var program: Program
        var templates: [WorkoutTemplate]
        var sessions: [TrainSession]
    }

    private enum Phase {
        case loading
        case ready(Loaded)
        case failed(String)
    }

    var body: some View {
        content
            .task(id: programID) { await load() }
            .alert("Program", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) { problem = nil }
            } message: {
                Text(problem ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.loopr(.background))
                .accessibilityLabel("Loading the program")
                .accessibilityIdentifier("program-loading")
        case .failed(let message):
            VStack(spacing: LooprSpacing.cardStack) {
                LooprText(message, style: .body, color: .inkSecondary)
                    .accessibilityIdentifier("program-load-error")
                Button("Try again") { Task { await load() } }
                    .buttonStyle(LooprButtonStyle(accent: .movement))
                    .accessibilityIdentifier("program-retry")
            }
            .padding(LooprSpacing.screenGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.loopr(.background))
        case .ready(let loaded):
            let clock = repositories.trainProgramClock
            ProgramScreen(
                model: ProgramScreenModel(ProgramScreenInput(
                    program: loaded.program, templates: loaded.templates, sessions: loaded.sessions,
                    now: clock.now, calendar: clock.calendar, calendarDenied: calendarDenied)),
                actions: actions(for: loaded))
                .navigationDestination(isPresented: $showsEditor) {
                    TrainProgramEditorHost(
                        program: loaded.program, templates: loaded.templates, sessions: loaded.sessions,
                        repository: repositories.trainProgramRepository, writer: writer, clock: clock,
                        onClose: {
                            showsEditor = false
                            Task { await load() }
                        })
                }
        }
    }

    // MARK: Actions

    private func actions(for loaded: Loaded) -> ProgramScreenActions {
        ProgramScreenActions(
            setEarlyLightWeek: { on in setRules { var rules = $0; rules.earlyLightWeek = on; return rules } },
            setMissedRule: { rule in setRules { var rules = $0; rules.missed = rule; return rules } },
            setCalendarExport: { on in setCalendar(on) },
            edit: { showsEditor = true },
            changePlan: { ask?.run("Program") },
            accept: { accept(loaded.program) },
            discard: { discard(loaded.program) },
            openSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            })
    }

    /// Shows the change at once, then saves it against the stored program so two quick taps never collide.
    private func setRules(_ edit: @escaping @Sendable (ProgramRules) -> ProgramRules) {
        guard case .ready(var loaded) = phase else { return }
        loaded.program.rules = edit(loaded.program.rules)
        phase = .ready(loaded)
        let repository = repositories.trainProgramRepository
        let now = repositories.trainProgramClock.now
        let id = programID
        Task { @MainActor in
            do {
                let saved = try await repository.updateProgramRules(id: id, at: now, edit: edit)
                if case .ready(var current) = phase { current.program = saved; phase = .ready(current) }
            } catch {
                problem = error.localizedDescription
                await load()
            }
        }
    }

    private func setCalendar(_ on: Bool) {
        guard case .ready(let loaded) = phase, !loaded.program.isDraft else { return }
        let writer = writer
        let clock = repositories.trainProgramClock
        Task { @MainActor in
            let sync = TrainCalendarSync(writer: writer)
            let context = ProgramScheduler.Context(now: clock.now, completed: CompletedSession.completed(in: loaded.sessions))
            if on {
                var candidate = loaded.program
                candidate.rules.calendarExport = true
                switch await sync.turnOn(program: candidate, templates: loaded.templates, context: context, calendar: clock.calendar) {
                case .denied:
                    calendarDenied = true
                case .synced(let result):
                    calendarDenied = false
                    setRules { var rules = $0; rules.calendarExport = true; return rules }
                    if result.couldNotChange > 0 { problem = Self.leftBehindMessage }
                case .failed(let message):
                    problem = message
                case .cleared:
                    break
                }
            } else {
                calendarDenied = false
                setRules { var rules = $0; rules.calendarExport = false; return rules }
                switch await sync.clear(programID: loaded.program.id) {
                case .cleared(let result): if result.couldNotChange > 0 { problem = Self.leftBehindMessage }
                case .failed(let message): problem = message
                case .denied, .synced: break
                }
            }
        }
    }

    static let leftBehindMessage = "Some sessions stay in Calendar. Delete them there."

    private func accept(_ program: Program) {
        let repository = repositories.trainProgramRepository
        let now = repositories.trainProgramClock.now
        Task { @MainActor in
            do {
                _ = try await repository.acceptDraft(id: program.id, expectedRevision: program.revision, at: now)
                await load()
            } catch {
                problem = error.localizedDescription
                await load()
            }
        }
    }

    private func discard(_ program: Program) {
        let repository = repositories.trainProgramRepository
        Task { @MainActor in
            do {
                try await repository.discardDraft(id: program.id, expectedRevision: program.revision)
                dismiss()
            } catch {
                problem = error.localizedDescription
                await load()
            }
        }
    }

    // MARK: Loading

    private func load() async {
        let repository = repositories.trainProgramRepository
        let clock = repositories.trainProgramClock
        do {
            async let program = repository.program(id: programID)
            async let templates = repository.templates()
            async let sessions = repository.recentSessions(limit: 500, status: .completed)
            guard let program = try await program else {
                phase = .failed("This program is no longer available.")
                return
            }
            let loaded = Loaded(program: program, templates: try await Self.merged(templates, with: program),
                                sessions: try await sessions)
            phase = .ready(loaded)
            await refreshCalendar(loaded, clock: clock)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Saved templates plus the ones an agent draft carries, without repeats.
    private static func merged(_ stored: [WorkoutTemplate], with program: Program) -> [WorkoutTemplate] {
        let known = Set(stored.map(\.id))
        return stored + (program.pendingTemplates ?? []).filter { !known.contains($0.id) }
    }

    /// Keeps Calendar in step after a reschedule or an edit. Never prompts.
    private func refreshCalendar(_ loaded: Loaded, clock: (now: Date, calendar: Calendar)) async {
        guard loaded.program.rules.calendarExport, !loaded.program.isDraft else { return }
        let context = ProgramScheduler.Context(now: clock.now, completed: CompletedSession.completed(in: loaded.sessions))
        switch await TrainCalendarSync(writer: writer).refresh(program: loaded.program, templates: loaded.templates,
                                                              context: context, calendar: clock.calendar) {
        case .denied: calendarDenied = true
        case .synced, .cleared: calendarDenied = false
        case .failed(let message): problem = message
        }
    }
}
