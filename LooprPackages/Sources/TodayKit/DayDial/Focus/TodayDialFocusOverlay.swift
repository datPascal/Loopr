import DesignSystem
import Observation
import SwiftUI
import UIKit

/// How far the open card is, 0 folded into its element and 1 open, frame by frame. The UIKit spring writes it and the
/// dial reads it, so the dial steps back behind the card on the very same curve, and comes forward again as it folds.
@MainActor @Observable
final class TodayDialFocusMotion {
    var progress: Double = 0
}

/// The dial behind an open card: it sinks a little, softens and fades, so the card reads as the dial itself coming
/// forward rather than a sheet laid over it.
struct TodayDialRecede: ViewModifier {
    let motion: TodayDialFocusMotion

    func body(content: Content) -> some View {
        let q = min(max(motion.progress, 0), 1)
        content
            .scaleEffect(1 - 0.08 * q)
            .blur(radius: 7 * q)
            .opacity(1 - 0.88 * q)
    }
}

/// Puts the UIKit focus card over the dial's square. SwiftUI owns which element is focused; the view owns the motion
/// and says when the card has folded back, so the dial can draw what it carried again.
struct TodayDialFocusOverlay: UIViewRepresentable {
    let focus: TodayDialFocus?
    let model: TodayDialModel
    let photos: [UUID: UIImage]
    let actions: TodayDialActions
    let reduceMotion: Bool
    let locale: Locale
    let motion: TodayDialFocusMotion
    let onDismissed: () -> Void

    func makeUIView(context: Context) -> TodayDialFocusView {
        TodayDialFocusView(frame: .zero)
    }

    func updateUIView(_ view: TodayDialFocusView, context: Context) {
        view.onDismissed = onDismissed
        view.motion = motion
        guard let focus else {
            view.dismiss()
            return
        }
        guard let detail = TodayDialFocusDetail.make(focus, model: model, locale: locale),
              let anchor = TodayDialHitTest.anchor(for: focus, in: model) else {
            // The element left the dial while its card was open, or before it could open.
            if view.isPresented { view.dismiss() } else { DispatchQueue.main.async(execute: onDismissed) }
            return
        }
        let photo = Self.photo(for: detail, in: photos)
        if view.focus == focus {
            view.update(detail: detail, photo: photo, actions: actions)
            return
        }
        // The square has to be laid out before the morph can measure it.
        let present = { [weak view] in
            guard let view else { return }
            view.present(focus, detail: detail, anchor: anchor, spans: Self.spans(model), photo: photo, actions: actions,
                         reduceMotion: reduceMotion)
        }
        if view.bounds.width > 0 { present() } else { DispatchQueue.main.async(execute: present) }
    }

    static func dismantleUIView(_ view: TodayDialFocusView, coordinator: ()) {
        view.dismiss(animated: false)
    }

    static func photo(for detail: TodayDialFocusDetail, in photos: [UUID: UIImage]) -> UIImage? {
        guard case .meal(let meal) = detail, let id = meal.photoID else { return nil }
        return photos[id]
    }

    static func spans(_ model: TodayDialModel) -> [TodayDialStageSpan] {
        if case .present(.lastNight(let night)) = model.sleep { return night.spans }
        return []
    }
}

/// The spoken targets: VoiceOver cannot tap a spot on the dial, so each element is an action on it.
struct TodayDialFocusTarget: Hashable {
    let focus: TodayDialFocus
    let label: String
}

enum TodayDialFocusTargets {
    static func all(_ model: TodayDialModel) -> [TodayDialFocusTarget] {
        var targets: [TodayDialFocusTarget] = []
        switch model.sleep {
        case .present(.lastNight): targets.append(.init(focus: .lastNight, label: "Show last night"))
        case .present(.tonight): targets.append(.init(focus: .tonight, label: "Show tonight"))
        case .absent: break
        }
        for meal in model.eating.value?.meals ?? [] { targets.append(.init(focus: .meal(meal.id), label: "Show \(meal.title)")) }
        for block in model.training.value ?? [] { targets.append(.init(focus: .training(block.id), label: "Show \(block.title)")) }
        for bead in model.beads { targets.append(.init(focus: .bead(bead.id), label: "Show \(bead.title)")) }
        if model.bedtime != nil { targets.append(.init(focus: .bedtime, label: "Show bedtime")) }
        if model.alarm != nil { targets.append(.init(focus: .alarm, label: "Show wake alarm")) }
        return targets
    }
}
