import Foundation
import SwiftUI
import AnalyticsKit
import DesignSystem

public struct WorkoutRecoveryPresentation: Equatable, Sendable {
    public let assessment: TimedHeartRateRecovery
    public let usualDrop: Double?
    public let eligibleWorkouts: Int
    public init(assessment: TimedHeartRateRecovery, usualDrop: Double? = nil, eligibleWorkouts: Int = 0) {
        self.assessment = assessment; self.usualDrop = usualDrop; self.eligibleWorkouts = eligibleWorkouts
    }
    public var sentence: String {
        guard let first = assessment.firstMinute else { return assessment.reason ?? "No heart rate recorded after this workout." }
        let drop = Int(first.dropBPM.rounded())
        if drop > 0 { return "Heart rate dropped \(drop) bpm in the first minute." }
        if drop == 0 { return "Heart rate was unchanged after the first minute." }
        return "Heart rate rose \(abs(drop)) bpm in the first minute."
    }
    public var context: String? {
        guard let first = assessment.firstMinute else { return nil }
        if let usualDrop, eligibleWorkouts >= 5 {
            let delta = Int((first.dropBPM - usualDrop).rounded())
            return "\(delta >= 0 ? "+" : "")\(delta) bpm vs usual for this activity · \(eligibleWorkouts) workouts"
        }
        return "Learning your usual drop · \(min(eligibleWorkouts, 5)) of 5 eligible workouts"
    }
    public var secondMinute: String? {
        assessment.secondMinute.map {
            let drop = Int($0.dropBPM.rounded())
            if drop == 0 { return "Heart rate was unchanged after two minutes." }
            return "After two minutes: \(abs(drop)) bpm \(drop > 0 ? "below" : "above") the finishing peak."
        }
    }
}
public protocol WorkoutHeartRateRecoveryProviding: Sendable {
    func recovery(for workout: WorkoutRecord) async -> WorkoutRecoveryPresentation
}
extension EnvironmentValues {
    @Entry public var workoutHeartRateRecoveryProvider: (any WorkoutHeartRateRecoveryProviding)? = nil
}
struct WorkoutHeartRateRecoveryCard: View {
    let presentation: WorkoutRecoveryPresentation
    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("HEART RATE RECOVERY", style: .sectionLabel, color: .inkSecondary)
                LooprText(presentation.sentence, style: presentation.assessment.firstMinute == nil ? .prose : .cardTitle,
                          color: presentation.assessment.firstMinute == nil ? .inkSecondary : .ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let context = presentation.context { LooprText(context, style: .caption, color: .inkSecondary) }
                if presentation.assessment.firstMinute != nil {
                    LooprText(presentation.secondMinute ?? "Two-minute drop needs heart rate through two minutes after finishing.",
                              style: .prose, color: .inkSecondary)
                }
                if presentation.assessment.firstMinute != nil {
                    LooprText("The drop from your finishing peak, measured while your band stayed on.", style: .caption, color: .inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workout-heart-rate-recovery")
    }
}
