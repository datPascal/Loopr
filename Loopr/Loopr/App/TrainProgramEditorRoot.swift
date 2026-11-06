import DesignSystem
import SwiftUI
import TrainKit

/// The program editor pushed from the Train overview: a new program, or an existing one by id.
struct TrainProgramEditorRoot: View {
    let programID: UUID?

    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var writer: any TrainCalendarWriter = TrainCalendarWriters.make()

    private enum Phase {
        case loading
        case ready(program: Program?, templates: [WorkoutTemplate], sessions: [TrainSession])
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.loopr(.background))
                    .accessibilityLabel("Loading the program")
                    .accessibilityIdentifier("program-editor-loading")
            case .failed(let message):
                VStack(spacing: LooprSpacing.cardStack) {
                    LooprText(message, style: .body, color: .inkSecondary)
                        .accessibilityIdentifier("program-editor-load-error")
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(LooprButtonStyle(accent: .movement))
                        .accessibilityIdentifier("program-editor-retry")
                }
                .padding(LooprSpacing.screenGutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.loopr(.background))
            case .ready(let program, let templates, let sessions):
                TrainProgramEditorHost(
                    program: program, templates: templates, sessions: sessions, repository: repositories.trainProgramRepository,
                    writer: writer, clock: repositories.trainProgramClock, onClose: { dismiss() })
            }
        }
        .task(id: programID) { await load() }
    }

    private func load() async {
        let repository = repositories.trainProgramRepository
        phase = .loading
        do {
            async let templates = repository.templates()
            async let sessions = repository.recentSessions(limit: 500, status: .completed)
            var program: Program?
            if let programID {
                guard let stored = try await repository.program(id: programID) else { throw TrainError.missingRecord }
                program = stored
            }
            let saved = try await templates
            let pending = (program?.pendingTemplates ?? []).filter { pending in !saved.contains { $0.id == pending.id } }
            phase = .ready(program: program, templates: saved + pending, sessions: try await sessions)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Builds the editor from loaded values. Shared by the new-program route and the Edit button on the Program screen.
struct TrainProgramEditorHost: View {
    let program: Program?
    let templates: [WorkoutTemplate]
    let sessions: [TrainSession]
    let repository: AppTrainRepository
    let writer: any TrainCalendarWriter
    let clock: (now: Date, calendar: Calendar)
    let onClose: () -> Void

    var body: some View {
        ProgramEditorScreen(
            model: model, calendar: clock.calendar,
            save: { @MainActor @Sendable [repository, writer, templates, sessions, clock] program in
                let saved = try await repository.saveProgram(program, at: Date())
                // Brings Calendar in line with the saved plan. It never prompts: the switch asked already.
                _ = await TrainCalendarSync(writer: writer).refresh(
                    program: saved, templates: templates,
                    context: ProgramScheduler.Context(now: clock.now, completed: CompletedSession.completed(in: sessions)),
                    calendar: clock.calendar)
                return saved
            },
            requestCalendarAccess: { @Sendable [writer] in await writer.requestAccess() },
            onClose: onClose)
            .id(program?.id)
    }

    private var model: ProgramEditorModel {
        if let program { return ProgramEditorModel(program: program, templates: templates) }
        let day = ProgramScheduler(calendar: clock.calendar).localDay(for: clock.now)
        return .blank(startDay: day, templates: templates)
    }
}
