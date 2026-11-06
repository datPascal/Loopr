import SwiftUI
import TrainKit

/// Maps each pushed `TrainRoute` to its screen.
struct TrainDestinationRoots: View {
    let route: TrainRoute
    let runtime: TrainLiveRuntime
    let actions: TrainSessionActions

    var body: some View {
        Group {
            switch route {
            case .template, .libraryPicker: TrainTemplateRoot(route: route)
            case .program(let id): TrainProgramRoot(programID: id)
            case .programEditor(let id): TrainProgramEditorRoot(programID: id)
            case .live, .summary: session
            case .exercises, .exercise, .muscleVolume: TrainExerciseHistoryRoot(route: route)
            case .pastSession: TrainPastSessionRoot(workoutSession: actions.workoutSession)
            }
        }
        .loadsExerciseRecents()
    }

    @ViewBuilder
    private var session: some View {
        #if DEBUG
        if case .live = route, AppTrainFixtures.isLiveRequested() {
            TrainLiveFixtureRoot()
        } else {
            TrainSessionRoot(route: route, runtime: runtime, actions: actions)
        }
        #else
        TrainSessionRoot(route: route, runtime: runtime, actions: actions)
        #endif
    }
}
