import Foundation
import Testing
import DesignSystem
@testable import BodyKit

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Tuesday 2026-10-20 08:00 UTC.
private let now = Date(timeIntervalSince1970: 1_792_483_200)

private func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

private func typed(_ kilograms: Double, hoursAgo: Double = 0, bodyFat: Double? = nil, leanMass: Double? = nil,
                   id: UUID = UUID()) -> BodyLogTypedRecord {
    BodyLogTypedRecord(id: id, measuredAt: ago(hours: hoursAgo), timeZoneIdentifier: "UTC", weightKilograms: kilograms,
                       bodyFatPercent: bodyFat, leanMassKilograms: leanMass)
}

private func health(_ quantity: BodyLogQuantity, _ value: Double, hoursAgo: Double = 0, source: String = "Withings",
                    typedIntoHealth: Bool = false) -> BodyLogHealthSample {
    BodyLogHealthSample(quantity: quantity, value: value, measuredAt: ago(hours: hoursAgo), sourceName: source,
                        typedIntoHealth: typedIntoHealth)
}

@Suite struct BodyLogMergeTests {
    @Test func aTypedEntryAndAnAppleHealthSampleAtTheSameTimeStayTwoEntries() {
        let entries = BodyLogMerge.entries(typed: [typed(78.4)], health: [health(.weight, 79.1)])
        #expect(entries.count == 2)
        #expect(entries.map(\.weightKilograms) == [78.4, 79.1], "the person's own entry first, and no averaged number")
        #expect(entries.map(\.isTyped) == [true, false])
        #expect(entries[0].origin.provenance == .typedIn)
        #expect(entries[1].origin.provenance == .appleHealth(source: "Withings", typedIn: false))
    }

    @Test func entriesRunNewestFirst() {
        let entries = BodyLogMerge.entries(
            typed: [typed(78.0, hoursAgo: 48), typed(78.6, hoursAgo: 1)],
            health: [health(.weight, 79.0, hoursAgo: 24), health(.weight, 79.5, hoursAgo: 72)])
        #expect(entries.compactMap(\.weightKilograms) == [78.6, 79.0, 78.0, 79.5])
    }

    @Test func oneScaleWritingThreeQuantitiesAtOnceIsOneEntryWithAllThree() {
        let entries = BodyLogMerge.entries(typed: [], health: [
            health(.weight, 79.0, hoursAgo: 5), health(.bodyFat, 21.5, hoursAgo: 5), health(.leanMass, 62.0, hoursAgo: 5)])
        #expect(entries.count == 1)
        #expect(entries.first?.weightKilograms == 79.0)
        #expect(entries.first?.bodyFatPercent == 21.5)
        #expect(entries.first?.leanMassKilograms == 62.0)
    }

    @Test func twoSourcesAtTheSameTimeStayApartAndKeepTheirNames() {
        let entries = BodyLogMerge.entries(typed: [], health: [
            health(.weight, 79.0, source: "Withings"), health(.weight, 78.8, source: "Apple Watch")])
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.origin)) == [.appleHealth(sourceName: "Withings", typedIntoHealth: false),
                                              .appleHealth(sourceName: "Apple Watch", typedIntoHealth: false)])
    }

    @Test func samplesMoreThanAMinuteApartAreSeparateEntries() {
        let entries = BodyLogMerge.entries(typed: [], health: [
            health(.weight, 79.0, hoursAgo: 0), health(.weight, 79.4, hoursAgo: 0.05)])
        #expect(entries.count == 2)
    }

    @Test func aMissingQuantityStaysMissingNeverZero() {
        let entries = BodyLogMerge.entries(typed: [typed(78.4)], health: [health(.weight, 79.1, hoursAgo: 3)])
        #expect(entries.allSatisfy { $0.bodyFatPercent == nil && $0.leanMassKilograms == nil })
    }

    @Test func aSampleTypedIntoAppleHealthSaysSo() {
        let entries = BodyLogMerge.entries(typed: [], health: [health(.weight, 80, typedIntoHealth: true)])
        #expect(entries.first?.origin.provenance.label == "Typed into Apple Health")
    }

    @Test func nothingMergesToNothing() {
        #expect(BodyLogMerge.entries(typed: [], health: []).isEmpty)
    }

    @Test func entryIdsAreUniqueAndAppleHealthEntriesCarryNoTypedId() {
        let record = typed(78)
        let entries = BodyLogMerge.entries(typed: [record], health: [health(.weight, 79), health(.weight, 80, hoursAgo: 30)])
        #expect(Set(entries.map(\.id)).count == 3)
        #expect(entries.first { $0.isTyped }?.typedID == record.id)
        #expect(entries.filter { !$0.isTyped }.allSatisfy { $0.typedID == nil })
    }
}

@Suite struct BodyLogSummaryTests {
    @Test func eachQuantityTakesItsOwnNewestReadingAcrossSources() throws {
        let entries = BodyLogMerge.entries(
            typed: [typed(78.4, hoursAgo: 2, bodyFat: 19.0)],
            health: [health(.weight, 79.0, hoursAgo: 30), health(.bodyFat, 22.0, hoursAgo: 50), health(.leanMass, 61.0, hoursAgo: 50)])
        let summary = BodyLogSummary.make(entries)
        #expect(summary.weight?.value == 78.4)
        #expect(summary.weight?.origin == .typed)
        #expect(summary.bodyFat?.value == 19.0)
        #expect(summary.bodyFat?.origin == .typed)
        let lean = try #require(summary.leanMass)
        #expect(lean.value == 61.0)
        #expect(lean.provenance == .appleHealth(source: "Withings", typedIn: false))
    }

    @Test func appleHealthWeightWithoutBodyFatLeavesBodyFatAbsent() {
        let summary = BodyLogSummary.make(BodyLogMerge.entries(typed: [], health: [health(.weight, 79.0)]))
        #expect(summary.weight?.value == 79.0)
        #expect(summary.bodyFat == nil)
        #expect(summary.leanMass == nil)
        #expect(!summary.isEmpty)
    }

    @Test func atTheSameTimeTheTypedValueWins() {
        let summary = BodyLogSummary.make(BodyLogMerge.entries(typed: [typed(78.4)], health: [health(.weight, 79.1)]))
        #expect(summary.weight?.origin == .typed)
        #expect(summary.weight?.value == 78.4)
    }

    @Test func noEntriesIsEmpty() {
        #expect(BodyLogSummary.make([]).isEmpty)
        #expect(BodyLogSummary.make([]) == .empty)
    }
}

@Suite struct BodyLogValidationTests {
    private func validate(_ weight: String, bodyFat: String = "", leanMass: String = "", at date: Date = now,
                          system: LooprMeasurementSystem = .metric) -> Result<BodyLogInput, BodyLogValidationError> {
        BodyLogDraft.validate(weightText: weight, bodyFatText: bodyFat, leanMassText: leanMass, measuredAt: date, now: now, system: system)
    }

    @Test func weightAloneIsEnoughAndTheOptionalFieldsStayAbsent() throws {
        let input = try validate("78.4").get()
        #expect(input.weightKilograms == 78.4)
        #expect(input.bodyFatPercent == nil)
        #expect(input.leanMassKilograms == nil)
        #expect(input.measuredAt == now)
    }

    @Test func allThreeValuesAndACommaDecimalAreAccepted() throws {
        let input = try validate("78,4", bodyFat: "21,5", leanMass: "61.2").get()
        #expect(input.weightKilograms == 78.4)
        #expect(input.bodyFatPercent == 21.5)
        #expect(input.leanMassKilograms == 61.2)
    }

    @Test func weightIsRequired() {
        #expect(validate("") == .failure(.weightMissing))
        #expect(validate("   ", bodyFat: "20") == .failure(.weightMissing))
        #expect(validate("heavy") == .failure(.weightNotANumber))
    }

    @Test func weightKeepsToTheFoodStoresRange() {
        #expect(BodyLogLimits.weightKilograms == 20...400)
        #expect(validate("19.9") == .failure(.weightOutOfRange))
        #expect(validate("400.1") == .failure(.weightOutOfRange))
        #expect(validate("0") == .failure(.weightOutOfRange))
        #expect(validate("-5") == .failure(.weightOutOfRange))
        #expect((try? validate("20").get()) != nil)
        #expect((try? validate("400").get()) != nil)
    }

    @Test func bodyFatRunsFromTwoToSeventyFivePercent() {
        #expect(validate("78", bodyFat: "1.9") == .failure(.bodyFatOutOfRange))
        #expect(validate("78", bodyFat: "75.1") == .failure(.bodyFatOutOfRange))
        #expect(validate("78", bodyFat: "0") == .failure(.bodyFatOutOfRange))
        #expect(validate("78", bodyFat: "lots") == .failure(.bodyFatNotANumber))
        #expect((try? validate("78", bodyFat: "2").get()) != nil)
        #expect((try? validate("78", bodyFat: "75").get()) != nil)
    }

    @Test func leanMassRunsFromTenTo200AndStaysBelowTheWeight() {
        #expect(validate("78", leanMass: "9.9") == .failure(.leanMassOutOfRange))
        #expect(validate("390", leanMass: "200.1") == .failure(.leanMassOutOfRange))
        #expect(validate("78", leanMass: "78") == .failure(.leanMassNotBelowWeight))
        #expect(validate("78", leanMass: "90") == .failure(.leanMassNotBelowWeight))
        #expect(validate("78", leanMass: "thin") == .failure(.leanMassNotANumber))
        #expect((try? validate("78", leanMass: "77.9").get()) != nil)
        #expect((try? validate("390", leanMass: "200").get()) != nil)
    }

    @Test func theTimeCannotBeInTheFuture() {
        #expect(validate("78", at: now.addingTimeInterval(60)) == .failure(.timeInFuture))
        #expect((try? validate("78", at: now.addingTimeInterval(-86_400)).get()) != nil)
    }

    @Test func poundsConvertToKilogramsAndTheRangesFollow() throws {
        let input = try validate("172.8", leanMass: "135", system: .imperial).get()
        #expect(abs(input.weightKilograms - 78.38) < 0.01)
        #expect(abs((input.leanMassKilograms ?? 0) - 61.23) < 0.01)
        #expect(validate("44", system: .imperial) == .failure(.weightOutOfRange), "44 lb is under 20 kg")
        #expect((try? validate("45", system: .imperial).get()) != nil)
        #expect(validate("882", system: .imperial) == .failure(.weightOutOfRange))
    }

    @Test func eachErrorNamesItsFieldAndReadsInThePersonsUnit() {
        #expect(BodyLogValidationError.weightOutOfRange.field == .weight)
        #expect(BodyLogValidationError.bodyFatOutOfRange.field == .bodyFat)
        #expect(BodyLogValidationError.leanMassNotBelowWeight.field == .leanMass)
        #expect(BodyLogValidationError.timeInFuture.field == .date)
        #expect(BodyLogValidationError.weightOutOfRange.message(system: .metric) == "Weight needs to be between 20 and 400 kg.")
        #expect(BodyLogValidationError.weightOutOfRange.message(system: .imperial) == "Weight needs to be between 45 and 881 lb.")
        #expect(BodyLogValidationError.leanMassOutOfRange.message(system: .metric) == "Lean mass needs to be between 10 and 200 kg.")
        #expect(BodyLogValidationError.bodyFatOutOfRange.message(system: .metric) == "Body fat needs to be between 2 and 75 percent.")
    }

    @Test func everyNamedBoundInAMessageIsItselfAllowed() {
        // Pounds round inward, so the number a message names always passes.
        #expect((try? validate("45", system: .imperial).get()) != nil)
        #expect((try? validate("881", system: .imperial).get()) != nil)
        #expect((try? validate("100", leanMass: "23", system: .imperial).get()) != nil)
        #expect((try? validate("880", leanMass: "440", system: .imperial).get()) != nil)
        #expect(validate("100", leanMass: "22", system: .imperial) == .failure(.leanMassOutOfRange))
        #expect(validate("880", leanMass: "441", system: .imperial) == .failure(.leanMassOutOfRange))
    }
}

@Suite struct BodyLogFormatTests {
    @Test func weightShowsInKilogramsOrPoundsFollowingTheSetting() {
        #expect(BodyLogFormat.text(.weight, value: 78.4, system: .metric) == "78.4 kg")
        #expect(BodyLogFormat.text(.weight, value: 78.4, system: .imperial) == "172.8 lb")
        #expect(BodyLogFormat.text(.leanMass, value: 61.2, system: .metric) == "61.2 kg")
        #expect(BodyLogFormat.text(.leanMass, value: 61.2, system: .imperial) == "134.9 lb")
    }

    @Test func bodyFatIsAPercentInEitherSystem() {
        #expect(BodyLogFormat.text(.bodyFat, value: 21.5, system: .metric) == "21.5 %")
        #expect(BodyLogFormat.text(.bodyFat, value: 21.5, system: .imperial) == "21.5 %")
    }

    @Test func spokenValuesNameTheUnit() {
        #expect(BodyLogFormat.spoken(.weight, value: 78.4, system: .metric) == "78.4 kilograms")
        #expect(BodyLogFormat.spoken(.weight, value: 78.4, system: .imperial) == "172.8 pounds")
        #expect(BodyLogFormat.spoken(.bodyFat, value: 21.5, system: .metric) == "21.5 percent")
    }

    @Test func parsingTakesNumbersAndNothingElse() {
        #expect(BodyLogFormat.parse("78.4") == 78.4)
        #expect(BodyLogFormat.parse(" 78,4 ") == 78.4)
        #expect(BodyLogFormat.parse("") == nil)
        #expect(BodyLogFormat.parse("kg") == nil)
        #expect(BodyLogFormat.parse("inf") == nil)
        #expect(BodyLogFormat.parse("nan") == nil)
    }

    @Test func kilogramsRoundTripThroughPounds() {
        let pounds = BodyLogFormat.displayValue(kilograms: 80, system: .imperial)
        #expect(abs(BodyLogFormat.kilograms(fromDisplay: pounds, system: .imperial) - 80) < 1e-9)
        #expect(BodyLogFormat.displayValue(kilograms: 80, system: .metric) == 80)
    }
}

@Suite struct BodyLogSeriesTests {
    @Test func theTrendKeepsTheNewestReadingOfEachDayInTheUnitShown() {
        let entries = BodyLogMerge.entries(typed: [typed(78.0, hoursAgo: 30), typed(78.6, hoursAgo: 28), typed(79.0, hoursAgo: 80)],
                                           health: [health(.weight, 80.0, hoursAgo: 120)])
        let metric = BodyLogSeries.make(entries: entries, quantity: .weight, system: .metric, now: now, calendar: utc)
        #expect(metric.points.map(\.value) == [80.0, 79.0, 78.6])
        #expect(metric.hasTrend)
        let imperial = BodyLogSeries.make(entries: entries, quantity: .weight, system: .imperial, now: now, calendar: utc)
        #expect(abs((imperial.points.last?.value ?? 0) - 78.6 * 2.204_622_621_848_78) < 1e-9)
    }

    @Test func aQuantityWithNoReadingHasNoPointsAndNoLatest() {
        let entries = BodyLogMerge.entries(typed: [], health: [health(.weight, 79.0)])
        let fat = BodyLogSeries.make(entries: entries, quantity: .bodyFat, system: .metric, now: now, calendar: utc)
        #expect(fat.points.isEmpty)
        #expect(fat.latest == nil)
        #expect(!fat.hasTrend)
    }

    @Test func oneReadingIsAPointAndNotYetATrend() {
        let entries = BodyLogMerge.entries(typed: [typed(78)], health: [])
        let series = BodyLogSeries.make(entries: entries, quantity: .weight, system: .metric, now: now, calendar: utc)
        #expect(series.points.count == 1)
        #expect(!series.hasTrend)
        #expect(series.latest?.value == 78)
    }

    @Test func readingsOlderThanTheWindowAreLeftOutOfTheLineButNotTheLatest() {
        let entries = BodyLogMerge.entries(typed: [typed(78, hoursAgo: 24 * 120)], health: [])
        let series = BodyLogSeries.make(entries: entries, quantity: .weight, system: .metric, now: now, calendar: utc)
        #expect(series.points.isEmpty)
        #expect(series.latest?.value == 78)
    }
}

@Suite struct BodyCompositionRowsWithLogTests {
    private let profile = BodyCompositionContext(weight: "70.0 kg", height: "175 cm", bodyFat: nil, state: .partial, source: "Your profile")

    @Test func theLatestLoggedWeightReplacesTheProfileWeightAndKeepsItsSource() throws {
        let entries = BodyLogMerge.entries(typed: [], health: [health(.weight, 79.1, hoursAgo: 3)])
        let rows = BodyCompositionRows.make(profile, log: BodyLogSummary.make(entries), system: .metric)
        #expect(rows.rows.map(\.title) == ["Weight", "Height"])
        #expect(rows.rows.map(\.value) == ["79.1 kg", "175 cm"])
        let weight = try #require(rows.rows.first)
        #expect(weight.provenance == .appleHealth(source: "Withings", typedIn: false))
        #expect(rows.rows.last?.provenance == .typedIn)
        #expect(rows.source == nil, "each row carries its own chip")
    }

    @Test func bodyFatAndLeanMassAppearOnlyWhenSomeoneLoggedThem() {
        let withFat = BodyLogSummary.make(BodyLogMerge.entries(typed: [typed(78.4, bodyFat: 21.5, leanMass: 61.2)], health: []))
        let rows = BodyCompositionRows.make(profile, log: withFat, system: .imperial)
        #expect(rows.rows.map(\.title) == ["Weight", "Height", "Body fat", "Lean mass"])
        #expect(rows.rows.map(\.value) == ["172.8 lb", "175 cm", "21.5 %", "134.9 lb"])
        #expect(rows.rows.compactMap(\.provenance).count == 4)

        let withoutFat = BodyLogSummary.make(BodyLogMerge.entries(typed: [typed(78.4)], health: []))
        #expect(BodyCompositionRows.make(profile, log: withoutFat, system: .metric).rows.map(\.title) == ["Weight", "Height"])
    }

    @Test func withNothingLoggedTheProfileRowsStayAsTheyWere() {
        #expect(BodyCompositionRows.make(profile, log: .empty, system: .metric) == BodyCompositionRows.make(profile))
        #expect(BodyCompositionRows.make(profile, log: nil, system: .metric) == BodyCompositionRows.make(profile))
    }

    @Test func profileWeightStandsInWhileOnlyBodyFatIsLogged() {
        let log = BodyLogSummary.make(BodyLogMerge.entries(typed: [], health: [health(.bodyFat, 20.0)]))
        let rows = BodyCompositionRows.make(profile, log: log, system: .metric)
        #expect(rows.rows.map(\.title) == ["Weight", "Height", "Body fat"])
        #expect(rows.rows.first?.value == "70 kg")
        #expect(rows.rows.first?.qualifier == "profile")
    }
}

@Suite struct BodyLogCopyTests {
    @Test func statusesCombineToTheMostTellingReason() {
        #expect(BodyLogHealthStatus.combine([.noSamples, .reading, .notShared]) == .reading)
        #expect(BodyLogHealthStatus.combine([.noSamples, .notShared, .noSamples]) == .notShared)
        #expect(BodyLogHealthStatus.combine([.switchedOff, .notShared]) == .switchedOff)
        #expect(BodyLogHealthStatus.combine([.noSamples, .noSamples]) == .noSamples)
        #expect(BodyLogHealthStatus.combine([]) == .noSamples)
    }

    @Test func theEmptySentenceSaysWhereValuesComeFromForEveryStatus() {
        for status in [BodyLogHealthStatus.reading, .noSamples, .notShared, .switchedOff, .unavailable, .failed] {
            let text = BodyLogCopy.emptyText(status)
            #expect(text.contains("what you type in and from Apple Health"), "\(status)")
        }
        #expect(BodyLogCopy.emptyText(.notShared).contains("not shared"))
    }

    @Test func noCopyHasAnEmDashAnExclamationOrAJudgement() {
        var all = [BodyLogCopy.title, BodyLogCopy.absent, BodyLogCopy.readOnlyHealthNote, BodyLogCopy.healthFootnote]
        for status in [BodyLogHealthStatus.reading, .noSamples, .notShared, .switchedOff, .unavailable, .failed] {
            all.append(BodyLogCopy.emptyText(status))
            if let note = BodyLogCopy.healthNote(status) { all.append(note) }
        }
        for system in [LooprMeasurementSystem.metric, .imperial] {
            for error in [BodyLogValidationError.weightMissing, .weightNotANumber, .weightOutOfRange, .bodyFatNotANumber,
                          .bodyFatOutOfRange, .leanMassNotANumber, .leanMassOutOfRange, .leanMassNotBelowWeight, .timeInFuture] {
                all.append(error.message(system: system))
            }
        }
        for text in all {
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}") && !text.contains("!"), Comment(rawValue: text))
            for word in ["healthy", "too high", "too low", "normal", "ideal", "obese"] { #expect(!text.lowercased().contains(word), Comment(rawValue: text)) }
        }
    }

    @Test func appleHealthEntriesSayTheyCannotBeEditedHere() {
        #expect(BodyLogCopy.readOnlyHealthNote.contains("cannot be edited here"))
    }
}

private actor StubLogProvider: BodyLogProviding {
    var typed: [BodyLogTypedRecord]
    var health: [BodyLogHealthSample]
    var status: BodyLogHealthStatus
    var failSaves = false

    init(typed: [BodyLogTypedRecord] = [], health: [BodyLogHealthSample] = [], status: BodyLogHealthStatus = .noSamples) {
        self.typed = typed
        self.health = health
        self.status = status
    }

    func setFailSaves(_ value: Bool) { failSaves = value }

    func snapshot(now: Date) -> BodyLogSnapshot { BodyLogSnapshot(typed: typed, health: health, healthStatus: status) }

    func save(_ input: BodyLogInput, timeZoneIdentifier: String) throws -> BodyLogTypedRecord {
        if failSaves { throw StubFailure() }
        let record = BodyLogTypedRecord(measuredAt: input.measuredAt, timeZoneIdentifier: timeZoneIdentifier,
                                        weightKilograms: input.weightKilograms, bodyFatPercent: input.bodyFatPercent,
                                        leanMassKilograms: input.leanMassKilograms)
        typed.append(record)
        return record
    }

    func delete(id: UUID) throws {
        if failSaves { throw StubFailure() }
        typed.removeAll { $0.id == id }
    }

    func restore(_ record: BodyLogTypedRecord) throws { typed.append(record) }

    struct StubFailure: Error {}
}

@MainActor @Suite struct BodyLogViewModelTests {
    private func makeModel(_ provider: StubLogProvider) -> BodyLogViewModel {
        BodyLogViewModel(provider: provider, timeZoneIdentifier: "UTC", now: { now })
    }

    @Test func loadingMergesTypedEntriesAndAppleHealthSamples() async {
        let model = makeModel(StubLogProvider(typed: [typed(78.4, hoursAgo: 1)], health: [health(.weight, 79.1, hoursAgo: 9)], status: .reading))
        #expect(model.loadState == .idle)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.entries.count == 2)
        #expect(model.summary.weight?.value == 78.4)
        #expect(model.snapshot.healthStatus == .reading)
    }

    @Test func nothingLoggedAndNoAppleHealthAccessIsEmptyWithTheReason() async {
        let model = makeModel(StubLogProvider(status: .notShared))
        await model.load()
        #expect(model.entries.isEmpty)
        #expect(model.summary.isEmpty)
        #expect(BodyLogCopy.emptyText(model.snapshot.healthStatus).contains("not shared"))
    }

    @Test func savingAnEntryAddsItToTheList() async throws {
        let model = makeModel(StubLogProvider())
        await model.load()
        let input = try BodyLogDraft.validate(weightText: "78.4", bodyFatText: "21.5", leanMassText: "", measuredAt: now, now: now,
                                              system: .metric).get()
        #expect(await model.save(input))
        #expect(model.entries.count == 1)
        #expect(model.entries.first?.weightKilograms == 78.4)
        #expect(model.entries.first?.bodyFatPercent == 21.5)
        #expect(model.entries.first?.leanMassKilograms == nil)
        #expect(model.entries.first?.isTyped == true)
    }

    @Test func aFailedSaveSaysSoAndAddsNothing() async throws {
        let provider = StubLogProvider()
        await provider.setFailSaves(true)
        let model = makeModel(provider)
        await model.load()
        let input = BodyLogInput(weightKilograms: 78, bodyFatPercent: nil, leanMassKilograms: nil, measuredAt: now)
        #expect(await model.save(input) == false)
        #expect(model.failure != nil)
        #expect(model.entries.isEmpty)
    }

    @Test func deletingATypedEntryOffersUndoAndUndoBringsItBack() async {
        let record = typed(78.4, hoursAgo: 2)
        let model = makeModel(StubLogProvider(typed: [record]))
        await model.load()
        let entry = model.entries[0]
        await model.delete(entry)
        #expect(model.entries.isEmpty)
        #expect(model.toast?.actionTitle == "Undo")
        await model.undoDelete()
        #expect(model.entries.count == 1)
        #expect(model.entries.first?.typedID == record.id)
        #expect(model.entries.first?.measuredAt == record.measuredAt)
    }

    @Test func anAppleHealthEntryCannotBeDeleted() async {
        let model = makeModel(StubLogProvider(health: [health(.weight, 79.1)], status: .reading))
        await model.load()
        let entry = model.entries[0]
        #expect(entry.typedID == nil)
        await model.delete(entry)
        #expect(model.entries.count == 1)
        #expect(model.toast == nil)
    }
}
