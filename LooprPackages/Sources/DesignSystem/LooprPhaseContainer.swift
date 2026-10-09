import SwiftUI

/// Cross-fades a tab between loading, content, empty and failed.
///
/// The screen hands in the phase it is in and the view for it. When the phase
/// changes, the old view fades out while the new one fades in and settles 6 pt
/// upward. Changes inside one phase, a number updating, do not run the
/// transition. With Reduce Motion it is a plain cross-fade.
public struct LooprPhaseContainer<Phase: Hashable, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let phase: Phase
    private let content: Content

    public init(phase: Phase, @ViewBuilder content: () -> Content) {
        self.phase = phase
        self.content = content()
    }

    public var body: some View {
        let reduces = LooprMotion.reducesMotion(reduceMotion)
        ZStack(alignment: .top) {
            content
                .id(phase)
                .transition(reduces ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                ))
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(LooprMotion.phaseChange(reduceMotion: reduceMotion), value: phase)
    }
}

/// The four states a tab moves through.
public enum LooprLoadPhase: Hashable, Sendable {
    case loading
    case content
    case empty
    case failed
}
