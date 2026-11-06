import RoutineKit
import Testing

struct RoutineMetricTests {
    /// Templates and stored protocols carry these names. A rename is a data migration, so this list changes only on purpose.
    @Test func theVocabularyIsExactlyTheDocumentedNames() {
        let names = RoutineMetric.allCases.map(\.rawValue)
        #expect(names == [
            "protein_g", "fibre_g", "energy_kcal", "last_meal_time", "alcohol_drinks", "last_caffeine_time",
            "supplements_all_taken", "medication_all_taken", "supplement_adherence",
            "sleep_onset_time", "in_bed_time", "zone2_minutes", "zone45_minutes", "sleep_hr",
            "strength_sessions", "mobility_sessions", "workout_minutes",
            "steps", "daylight_minutes", "vo2max", "weight_kg", "done"
        ])
        #expect(Set(names).count == names.count)
    }

    @Test func everyMetricBelongsToOneSourceAndEverySourceHasMetrics() {
        #expect(RoutineMetric.metrics(for: .food).count == 9)
        #expect(RoutineMetric.metrics(for: .band).count == 5)
        #expect(RoutineMetric.metrics(for: .fitness).count == 3)
        #expect(RoutineMetric.metrics(for: .appleHealth).count == 4)
        #expect(RoutineMetric.metrics(for: .manual) == [.done])
        #expect(RoutineMetric.allCases.allSatisfy { RoutineMetric(rawValue: $0.rawValue) == $0 })
    }

    @Test func timesAreMinutesAfterMidnightAndOnlyMealAndCaffeineAreEvents() {
        let times = RoutineMetric.allCases.filter(\.isTimeOfDay)
        #expect(times == [.lastMealTime, .lastCaffeineTime, .sleepOnsetTime, .inBedTime])
        #expect(RoutineMetric.allCases.filter(\.isEventTime) == [.lastMealTime, .lastCaffeineTime])
        #expect(RoutineMetric.sleepOnsetTime.nature == .settled && RoutineMetric.proteinG.nature == .accumulating)
        #expect(RoutineMetric.sleepHR.settleDelayMinutes == 720 && RoutineMetric.steps.settleDelayMinutes == 0)
    }

    @Test func aQuantityReadingKeepsMissingMissingAndMarksFloors() {
        #expect(MetricReading.quantity(known: nil, isComplete: true) == nil)
        #expect(MetricReading.quantity(known: .nan, isComplete: true) == nil)
        #expect(MetricReading.quantity(known: -1, isComplete: true) == nil)
        #expect(MetricReading.quantity(known: 0, isComplete: true) == .measured(0))
        #expect(MetricReading.quantity(known: 38, isComplete: false) == .atLeast(38))
    }
}
