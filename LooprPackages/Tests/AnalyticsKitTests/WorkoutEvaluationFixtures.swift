import Foundation
@testable import AnalyticsKit

// Synthetic, minute-resolution scenarios matching the app's MotionMinute input.
// Labels describe deliberate exercise, not merely elevated heart rate.
struct WorkoutEvaluationFixture {
    let name: String
    let heartRate: [WorkoutHRPoint]
    let motion: [WorkoutMotionPoint]
    let expected: [SavedWorkoutSpan]
    let saved: [SavedWorkoutSpan]

    init(_ name: String, minutes: Int = 65, offset: Double = 0,
         effort: [Range<Int>], bpm: Double, movement: Double,
         rests: [Range<Int>] = [], missing: [Range<Int>] = [],
         saved: [Range<Int>] = [], expected: [Range<Int>]? = nil,
         baseline: Double = 60, restBPM: Double = 110) {
        self.name = name
        let gaps = Set(missing.flatMap { $0 })
        let pauses = Set(rests.flatMap { $0 })
        self.heartRate = (0..<minutes).compactMap { minute in
            guard !gaps.contains(minute) else { return nil }
            let active = effort.contains { $0.contains(minute) }
            return WorkoutHRPoint(timestamp: offset + Double(minute * 60), bpm: active ? (pauses.contains(minute) ? restBPM : bpm) : baseline)
        }
        self.motion = (0..<minutes).compactMap { minute in
            guard !gaps.contains(minute) else { return nil }
            let active = effort.contains { $0.contains(minute) }
            return WorkoutMotionPoint(timestamp: offset + Double(minute * 60), intensity: active && !pauses.contains(minute) ? movement : 0.02)
        }
        self.expected = (expected ?? effort).map { SavedWorkoutSpan(start: offset + Double($0.lowerBound * 60), end: offset + Double(($0.upperBound - 1) * 60)) }
        self.saved = saved.map { SavedWorkoutSpan(start: offset + Double($0.lowerBound * 60), end: offset + Double(($0.upperBound - 1) * 60)) }
    }
}

enum WorkoutEvaluationFixtures {
    static let all: [WorkoutEvaluationFixture] = [
        .init("steady run", effort: [5..<30], bpm: 150, movement: 0.50),
        .init("interval session", effort: [5..<35], bpm: 154, movement: 0.53, rests: [12..<14, 22..<24]),
        .init("strength with rests", effort: [5..<36], bpm: 145, movement: 0.35, rests: [13..<16, 24..<27]),
        .init("cycling", effort: [5..<35], bpm: 148, movement: 0.23),
        .init("long walk", effort: [5..<52], bpm: 123, movement: 0.35),
        .init("brisk commute walk", effort: [5..<28], bpm: 105, movement: 0.28, expected: []),
        .init("stairs", effort: [5..<22], bpm: 139, movement: 0.48),
        .init("stress or caffeine", effort: [5..<30], bpm: 145, movement: 0.02, expected: []),
        .init("fever", effort: [5..<55], bpm: 120, movement: 0.02, expected: []),
        .init("bumpy drive", effort: [5..<35], bpm: 100, movement: 0.50, expected: []),
        .init("sauna", effort: [5..<30], bpm: 135, movement: 0.02, expected: []),
        .init("short eight minute effort", effort: [5..<13], bpm: 154, movement: 0.50),
        .init("short five minute effort", effort: [5..<11], bpm: 155, movement: 0.50),
        .init("signal gap", effort: [5..<35], bpm: 150, movement: 0.50, missing: [16..<19]),
        .init("midnight", minutes: 40, offset: 1_704_153_000, effort: [5..<30], bpm: 150, movement: 0.50),
        .init("two workouts", effort: [5..<20, 27..<43], bpm: 150, movement: 0.50),
        .init("saved overlap", effort: [5..<30], bpm: 150, movement: 0.50, saved: [5..<30], expected: [])
    ]
}
