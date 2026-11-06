import Foundation
import Testing
import TrainKit

/// Progression, recovery, prefill, summary and expected strain. Fixtures use Alex and Australia/Perth.
struct TrainRulesTests {
    private let bench = TrainFixture.bench
    private let double = ProgressionRule.doubleProgression(incrementKg: 2.5)

    private func planned(sets: Int = 4, repsMin: Int = 6, repsMax: Int = 8, load: Double? = 80, kind: TrainLoadKind = .weight) -> TemplateExercise {
        .init(exercise: bench, sets: sets, repsMin: repsMin, repsMax: repsMax, loadKg: load, loadKind: kind, restSeconds: 150)
    }

    private func logged(_ load: Double?, _ reps: Int, skipped: Bool = false) -> LoggedSet {
        .init(loadKg: load, reps: skipped ? 0 : reps, loggedAt: TrainFixture.date, skipped: skipped)
    }

    private func sets(_ reps: [Int], load: Double = 80) -> [LoggedSet] { reps.map { logged(load, $0) } }

    // MARK: Progression

    @Test func doubleProgressionAddsLoadWhenEverySetReachesTheCeiling() {
        let decision = ProgressionEvaluator.evaluate(rule: double, planned: planned(), performed: sets([8, 8, 8, 8]))
        #expect(decision.earned && decision.reason == .targetReached)
        #expect(decision.nextLoadKg == 82.5 && decision.nextReps == 6 && decision.incrementKg == 2.5)
    }

    @Test func doubleProgressionHoldsBelowTheCeiling() {
        let decision = ProgressionEvaluator.evaluate(rule: double, planned: planned(), performed: sets([8, 7, 7, 6]))
        #expect(!decision.earned && decision.reason == .belowTarget)
        #expect(decision.nextLoadKg == nil && decision.nextReps == nil)
    }

    @Test func oneLowSetBlocksTheIncrease() {
        let decision = ProgressionEvaluator.evaluate(rule: double, planned: planned(), performed: sets([8, 8, 8, 7]))
        #expect(!decision.earned && decision.reason == .belowTarget)
    }

    @Test func skippedSetsAreNotWorkingSets() {
        let performed = sets([8, 8, 8]) + [logged(nil, 0, skipped: true)]
        let decision = ProgressionEvaluator.evaluate(rule: double, planned: planned(), performed: performed)
        #expect(!decision.earned && decision.reason == .setsIncomplete)
        let allSkipped = ProgressionEvaluator.evaluate(rule: double, planned: planned(), performed: [logged(nil, 0, skipped: true)])
        #expect(allSkipped.reason == .noWorkingSets)
        let threeSets = ProgressionEvaluator.evaluate(rule: double, planned: planned(sets: 3), performed: performed)
        #expect(threeSets.earned)
    }

    @Test func nextLoadBuildsOnTheHeaviestWorkingSet() {
        let performed = [logged(80, 8), logged(82.5, 8), logged(82.5, 8), logged(82.5, 8)]
        #expect(ProgressionEvaluator.evaluate(rule: double, planned: planned(), performed: performed).nextLoadKg == 85)
    }

    @Test func linearNeedsThePlannedRepsOnEverySet() {
        let linear = ProgressionRule.linear(incrementKg: 2.5)
        let hit = ProgressionEvaluator.evaluate(rule: linear, planned: planned(), performed: sets([6, 7, 6, 8]))
        #expect(hit.earned && hit.nextLoadKg == 82.5)
        let miss = ProgressionEvaluator.evaluate(rule: linear, planned: planned(), performed: sets([6, 6, 6, 5]))
        #expect(!miss.earned && miss.reason == .belowTarget)
    }

    @Test func noRuleBodyweightAndNoLoadNeverProgress() {
        #expect(ProgressionEvaluator.evaluate(rule: .none, planned: planned(), performed: sets([8, 8, 8, 8])).reason == .noRule)
        // A bodyweight line with no added load and no assistance has nothing to change (R2-LIFT-04 keeps the rule
        // for weighted and assisted lines).
        let bodyweight = planned(load: nil, kind: .bodyweight)
        let unloaded = (0..<4).map { _ in logged(nil, 8) }
        #expect(ProgressionEvaluator.evaluate(rule: double, planned: bodyweight, performed: unloaded).reason == .bodyweight)
        #expect(ProgressionEvaluator.evaluate(rule: double, planned: bodyweight, performed: sets([8, 8, 8, 8])).reason == .targetReached)
        let noLoad = planned(load: nil)
        #expect(ProgressionEvaluator.evaluate(rule: double, planned: noLoad, performed: unloaded).reason == .noLoad)
    }

    @Test func progressionMessageNamesTheIncrease() {
        let decision = ProgressionEvaluator.evaluate(rule: double, planned: planned(), performed: sets([8, 8, 8, 8]))
        #expect(decision.message == "Every set hit the target last time. Add 2.5 kg.")
    }

    // MARK: Recovery

    // Stored, not computed: each `TrainFixture.line` call makes a new exercise id, so a computed list never equals itself.
    private let lines: [TemplateExercise] = [TrainFixture.line(TrainFixture.bench), TrainFixture.line(TrainFixture.row), TrainFixture.line(TrainFixture.pushdown, sets: 3)]

    @Test func recoveryBelowTheThresholdRemovesOneSetPerLift() {
        let result = RecoveryAdjuster.adjust(exercises: lines, rule: RecoveryRule(), score: 31)
        #expect(result.exercises.map(\.sets) == [3, 3, 2] && result.totalSetsRemoved == 3 && result.isAdjusted)
        #expect(result.reason == .belowThreshold(score: 31, setsPerLift: 1))
        #expect(result.message == "Recovery is 31. The lighter version drops one set per lift.")
        let record = result.programAdjustment(createdAt: TrainFixture.date)
        #expect(record?.kind == .setsRemoved && record?.setsRemoved == 3 && record?.recoveryScore == 31)
    }

    @Test func recoveryJustBelowTheThresholdAdjusts() {
        let result = RecoveryAdjuster.adjust(exercises: lines, rule: RecoveryRule(), score: 33.9)
        #expect(result.isAdjusted)
        #expect(result.reason == .belowThreshold(score: 33, setsPerLift: 1))
    }

    @Test func recoveryExactlyAtTheThresholdChangesNothing() {
        let result = RecoveryAdjuster.adjust(exercises: lines, rule: RecoveryRule(), score: 34)
        #expect(!result.isAdjusted && result.exercises == lines && result.totalSetsRemoved == 0)
        #expect(result.reason == .atOrAboveThreshold(score: 34))
        #expect(result.message == "Recovery is 34, so go as planned.")
        #expect(result.programAdjustment(createdAt: TrainFixture.date) == nil)
    }

    @Test func noReadingChangesNothingAndSaysSo() {
        let result = RecoveryAdjuster.adjust(exercises: lines, rule: RecoveryRule(), score: nil)
        #expect(!result.isAdjusted && result.exercises == lines)
        #expect(result.reason == .noReading)
        #expect(result.message == "No recovery reading yet. Go as planned or lighten it yourself.")
        #expect(RecoveryAdjuster.adjust(exercises: lines, rule: RecoveryRule(), score: .nan).reason == .noReading)
    }

    @Test func recoveryNeverGoesBelowOneSet() {
        let thin = [TrainFixture.line(bench, sets: 1), TrainFixture.line(TrainFixture.row, sets: 2)]
        let one = RecoveryAdjuster.adjust(exercises: thin, rule: RecoveryRule(), score: 10)
        #expect(one.exercises.map(\.sets) == [1, 1] && one.totalSetsRemoved == 1)
        let heavyCut = RecoveryAdjuster.adjust(exercises: thin, rule: RecoveryRule(setsRemoved: 3), score: 10)
        #expect(heavyCut.exercises.map(\.sets) == [1, 1])
        #expect(heavyCut.message == "Recovery is 10. The lighter version drops 3 sets per lift.")
        let floor = RecoveryAdjuster.adjust(exercises: [TrainFixture.line(bench, sets: 1)], rule: RecoveryRule(), score: 10)
        #expect(!floor.isAdjusted && floor.reason == .alreadyMinimal(score: 10))
    }

    @Test func recoveryRuleOffOrMissingChangesNothing() {
        #expect(RecoveryAdjuster.adjust(exercises: lines, rule: nil, score: 5).reason == .ruleOff)
        #expect(RecoveryAdjuster.adjust(exercises: lines, rule: RecoveryRule(enabled: false), score: 5).exercises == lines)
        let template = TrainFixture.template()
        #expect(RecoveryAdjuster.adjust(template: template, score: 20).exercises.map(\.sets) == [3, 3, 2])
    }

    // MARK: Prefill

    private func lastSession(_ reps: [Int], load: Double = 80) -> SessionExercise {
        SessionExercise(planned: planned(), status: .done, sets: sets(reps, load: load))
    }

    @Test func prefillUsesThePreviousSetOfThisSessionFirst() {
        let earned = lastSession([8, 8, 8, 8])
        let thisSession = [logged(82.5, 6), logged(82.5, 5)]
        let result = SetPrefill.resolve(setIndex: 2, planned: planned(), progression: double, thisSession: thisSession, lastSession: earned)
        #expect(result == SetPrefill(loadKg: 82.5, reps: 5, source: .thisSession))
        #expect(result.source.loggedSetSource == .previousSet)
    }

    @Test func prefillSkippedSetsInThisSessionAreIgnored() {
        let thisSession = [logged(82.5, 6), logged(nil, 0, skipped: true)]
        let result = SetPrefill.resolve(setIndex: 2, planned: planned(), progression: .none, thisSession: thisSession, lastSession: nil)
        #expect(result == SetPrefill(loadKg: 82.5, reps: 6, source: .thisSession))
    }

    @Test func prefillAppliesProgressionBeforeLastSessionValues() {
        for index in 0..<5 {
            let result = SetPrefill.resolve(setIndex: index, planned: planned(), progression: double, thisSession: [], lastSession: lastSession([8, 8, 8, 8]))
            #expect(result == SetPrefill(loadKg: 82.5, reps: 6, source: .progression))
        }
        #expect(SetPrefill.Source.progression.loggedSetSource == .progression)
    }

    @Test func prefillUsesTheMatchingSetFromLastSessionWhenNothingWasEarned() {
        let last = lastSession([8, 7, 7, 6])
        let second = SetPrefill.resolve(setIndex: 1, planned: planned(), progression: double, thisSession: [], lastSession: last)
        #expect(second == SetPrefill(loadKg: 80, reps: 7, source: .lastSession))
        let fourth = SetPrefill.resolve(setIndex: 3, planned: planned(), progression: double, thisSession: [], lastSession: last)
        #expect(fourth == SetPrefill(loadKg: 80, reps: 6, source: .lastSession))
        let noRule = SetPrefill.resolve(setIndex: 0, planned: planned(), progression: .none, thisSession: [], lastSession: lastSession([8, 8, 8, 8]))
        #expect(noRule == SetPrefill(loadKg: 80, reps: 8, source: .lastSession))
    }

    @Test func prefillFallsBackToTheTemplate() {
        let template = SetPrefill.resolve(setIndex: 0, planned: planned(), progression: double, thisSession: [], lastSession: nil)
        #expect(template == SetPrefill(loadKg: 80, reps: 6, source: .template))
        // Set 5 does not exist last time, and a skipped set has no values to copy.
        let past = SetPrefill.resolve(setIndex: 4, planned: planned(), progression: .none, thisSession: [], lastSession: lastSession([8, 7, 7, 6]))
        #expect(past.source == .template)
        var withSkip = lastSession([8, 7, 7, 6])
        withSkip.sets[1] = logged(nil, 0, skipped: true)
        let skipped = SetPrefill.resolve(setIndex: 1, planned: planned(), progression: .none, thisSession: [], lastSession: withSkip)
        #expect(skipped.source == .template)
        let bodyweight = SetPrefill.resolve(setIndex: 0, planned: planned(load: nil, kind: .bodyweight), progression: .none, thisSession: [], lastSession: nil)
        #expect(bodyweight.loadKg == nil)
        #expect(template.source.loggedSetSource == .template)
    }

    // MARK: Template summary

    @Test func summaryEstimatesMinutesFromSetsRepsAndRest() {
        let single = [TemplateExercise(exercise: TrainFixture.bench, sets: 3, repsMin: 10, repsMax: 10, loadKg: 60, restSeconds: 60)]
        // 3 x 10 reps x 3 s + 30 s setup + 2 rests of 60 s = 240 s.
        #expect(TemplateSummary(exercises: single) == TemplateSummary(exerciseCount: 1, totalSets: 3, estimatedMinutes: 4))
        let upperA = TemplateSummary(template: TrainFixture.template())
        #expect(upperA.exerciseCount == 3 && upperA.totalSets == 11 && upperA.estimatedMinutes == 30)
    }

    @Test func supersetMembersShareOneRestPerRound() {
        let group = UUID()
        let pair = [TemplateExercise(exercise: TrainFixture.bench, sets: 3, repsMin: 10, repsMax: 10, loadKg: 60, restSeconds: 60, supersetGroup: group),
                    TemplateExercise(exercise: TrainFixture.row, sets: 3, repsMin: 10, repsMax: 10, loadKg: 60, restSeconds: 90, supersetGroup: group)]
        // Work 180 s, setup 60 s, 3 rounds of 90 s rest minus the last = 180 s. Total 420 s.
        #expect(TemplateSummary(exercises: pair).estimatedMinutes == 7)
    }

    @Test func summaryHandlesEmptyAndCardioTemplates() {
        #expect(TemplateSummary(exercises: []) == TemplateSummary(exerciseCount: 0, totalSets: 0, estimatedMinutes: 0))
        let cardio = TemplateSummary(template: TrainFixture.cardio())
        #expect(cardio.estimatedMinutes == 45 && cardio.exerciseCount == 0)
    }

    // MARK: Expected strain

    private func sample(_ template: UUID?, _ daysAgo: Double, _ strain: Double?) -> ExpectedStrain.Sample {
        .init(templateID: template, endedAt: TrainFixture.date.addingTimeInterval(-daysAgo * 86_400), strain: strain)
    }

    @Test func expectedStrainIsNilWithoutHistory() {
        let template = UUID()
        #expect(ExpectedStrain.estimate(templateID: template, history: []) == nil)
        #expect(ExpectedStrain.estimate(templateID: template, history: [sample(UUID(), 1, 9), sample(nil, 2, 9)]) == nil)
        #expect(ExpectedStrain.estimate(templateID: template, history: [sample(template, 1, nil)]) == nil)
    }

    @Test func expectedStrainIsTheMeanOfTheLastThreeSessions() {
        let template = UUID()
        let history = [sample(template, 30, 20), sample(template, 14, 9), sample(template, 7, 8), sample(template, 1, 7), sample(UUID(), 2, 1)]
        #expect(ExpectedStrain.estimate(templateID: template, history: history) == 8)
        #expect(ExpectedStrain.estimate(templateID: template, history: [sample(template, 3, 6), sample(template, 1, 8)]) == 7)
        // A session with no strain value is skipped, so the three before it count.
        let gap = history + [sample(template, 0.5, nil)]
        #expect(ExpectedStrain.estimate(templateID: template, history: gap) == 8)
    }
}
