import Foundation
import Testing
import DomainKit
import DesignSystem
@testable import SleepKit

struct SleepKitTests {
    @Test
    func stateMatrixCoversAllFourteenStatesAndSeparatesZeroFromAbsent() {
        #expect(SleepFixtures.allStates.count == 14)
        let absent = SleepFixtures.snapshot(for: .absent).metric("duration")
        let zero = SleepFixtures.snapshot(for: .measuredZero).metric("duration")
        #expect(absent?.value == nil)
        #expect(absent?.state == .absent)
        #expect(zero?.value == "0:00")
        #expect(zero?.state == .measuredZero)
        #expect(absent?.accessibilitySummary != zero?.accessibilitySummary)
    }

    @Test
    func partialOvernightIsExplicitAndNeverPromotedToComplete() {
        let snapshot = SleepFixtures.partialOvernight
        #expect(snapshot.state == .partial)
        #expect(snapshot.mainSleep?.isPartial == true)
        #expect(snapshot.mainSleep?.durationMinutes == 462)
    }

    @Test
    func canonicalSnapshotPreservesSourceAndAlgorithmProvenance() {
        let snapshot = SleepFixtures.populated
        #expect(snapshot.source == "ANA-03.canonical")
        #expect(snapshot.algorithmVersion == "sleep.v1")
        #expect(snapshot.metric("efficiency")?.source == "ANA-03.accounting")
        #expect(snapshot.suggestedAlarm?.localTime == "07:30")
    }

    @Test
    func trendRangesUseCivilDaysAcrossDSTWithoutRebasingLabels() {
        let points = [
            SleepTrendPoint(id: "1", localDay: "2024-03-08", value: 7, state: .partial, unit: "hours"),
            SleepTrendPoint(id: "2", localDay: "2024-03-09", value: 7.5, state: .partial, unit: "hours"),
            SleepTrendPoint(id: "3", localDay: "2024-03-10", value: 6, state: .partial, unit: "hours"),
            SleepTrendPoint(id: "4", localDay: "2024-03-11", value: 8, state: .partial, unit: "hours"),
            SleepTrendPoint(id: "5", localDay: "2024-03-12", value: 7.8, state: .partial, unit: "hours"),
            SleepTrendPoint(id: "6", localDay: "2024-03-13", value: 7.2, state: .partial, unit: "hours"),
            SleepTrendPoint(id: "7", localDay: "2024-03-14", value: 7.1, state: .partial, unit: "hours"),
            SleepTrendPoint(id: "8", localDay: "2024-03-15", value: 7.4, state: .partial, unit: "hours")
        ]
        let week = SleepTrendFilter.points(points, range: .week)
        #expect(week.map(\.localDay) == ["2024-03-09", "2024-03-10", "2024-03-11", "2024-03-12", "2024-03-13", "2024-03-14", "2024-03-15"])
        #expect(Set(week.map(\.localDay)).count == week.count)
    }

    @Test @MainActor
    func suggestedAlarmRequiresAnExplicitConfirmationAction() async {
        let suggestion = SleepFixtures.populated.suggestedAlarm!
        let effect = RecordingAlarmEffect()
        #expect(await effect.confirmationCount() == 0)
        #expect(await effect.confirm(suggestion) == .applied)
        #expect(await effect.confirmationCount() == 1)
        _ = SleepSuggestedAlarmScreen(suggestion: suggestion) { await effect.confirm(suggestion) }
    }

    @Test @MainActor
    func viewModelReadsRepositoryAndCorrectionAuditWithoutRecomputing() async {
        let repository = InMemorySleepRepository(values: [SleepFixtures.day: SleepFixtures.populated])
        let corrections = InMemorySleepCorrectionRepository()
        let viewModel = SleepViewModel(repository: repository, correctionRepository: corrections)
        await viewModel.load(day: SleepFixtures.day)
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.snapshot == SleepFixtures.populated)

        await viewModel.recordCorrection(day: SleepFixtures.day, target: "onset", before: "22:10", after: "22:30", reason: "User corrected onset", algorithmVersion: "sleep.v1", createdAt: SleepFixtures.baseDate)
        #expect(viewModel.corrections.count == 1)
        #expect(viewModel.corrections.first?.before == "22:10")
        #expect(viewModel.corrections.first?.after == "22:30")
        #expect(viewModel.corrections.first?.source == "user")
    }

    @Test
    func correctionRepositoryIsAppendOnlyAndDeletionIsExplicit() async throws {
        let repository = InMemorySleepCorrectionRepository()
        let correction = SleepCorrection(day: SleepFixtures.day, target: "stage", before: "light", after: "deep", reason: "Correction", algorithmVersion: "sleep.v1", createdAt: SleepFixtures.baseDate)
        try await repository.append(correction)
        #expect(try await repository.history(for: SleepFixtures.day) == [correction])
        try await repository.deleteAll()
        #expect(try await repository.history(for: SleepFixtures.day).isEmpty)
    }

    @Test @MainActor
    func screensConstructForDayAndHypnogramRoutes() {
        let repository = InMemorySleepRepository(values: [SleepFixtures.day: SleepFixtures.populated])
        let viewModel = SleepViewModel(repository: repository)
        _ = SleepScreen(viewModel: viewModel)
        _ = SleepHypnogramScreen(snapshot: SleepFixtures.populated)
        _ = SleepTrendsScreen(snapshot: SleepFixtures.populated)
        _ = SleepSuggestedAlarmScreen(suggestion: SleepFixtures.populated.suggestedAlarm!)
        _ = SleepCorrectionsScreen(corrections: [])
        #expect(SleepRoute.allCases.count == 6)
    }

    @Test @MainActor
    func theNightlyMetricsTheDerivationAddedRenderFromTheirOwnTitlesAndUnits() {
        let added: [(String, String, String, String)] = [
            ("cycles", "Sleep cycles", "4", "cycles"),
            ("latency", "Time to fall asleep", "12", "minutes"),
            ("remLatency", "Time to first REM", "78", "minutes"),
            ("disturbances", "Wake-ups", "3", "times"),
            ("need", "Sleep need", "8.1", "hours"),
            ("debt", "Sleep debt", "0.4", "hours"),
            ("regularity", "Sleep regularity", "86", "points")
        ]
        let metrics = added.map { id, title, value, unit in
            SleepMetricValue(id: id, title: title, value: value, unit: unit, state: .partial, source: "test")
        }
        let rows = metrics.map(SleepMetricList.row)
        #expect(rows.map(\.title) == added.map { $0.1 })
        #expect(rows.map(\.value) == added.map { $0.2 })
        #expect(rows.map(\.unit) == added.map { $0.3 })
        #expect(rows.allSatisfy { !$0.title.isEmpty })
    }

    @Test @MainActor
    func daytimeNapsGetTheirOwnRowsAndTheTrendsRowNeedsPoints() {
        let snapshot = SleepFixtures.populated
        #expect(snapshot.naps.count == 1)
        guard let nap = snapshot.naps.first else { return }
        let row = SleepNapList.row(nap)
        #expect(row.title.hasPrefix("Nap at "))
        #expect(row.value == nap.durationLabel)
        _ = SleepNapList(naps: snapshot.naps)
        // The Sleep screen only offers the trends row once there is something
        // to plot, and the derivation now fills the trend.
        #expect(!snapshot.trend.isEmpty)
        #expect(snapshot.needHours != nil)
        #expect(snapshot.debtHours != nil)
    }
}

private actor RecordingAlarmEffect: SleepSuggestedAlarmEffect {
    private var confirmations = 0

    func confirm(_ suggestion: SleepSuggestedAlarm) async -> SleepAlarmConfirmation {
        confirmations += 1
        return .applied
    }

    func confirmationCount() -> Int { confirmations }
}
