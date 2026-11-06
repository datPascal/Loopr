import AIKit
import AnalyticsKit
import DataKit
import DesignSystem
import FoodKit
import Foundation
import StorageKit
import Testing
import UIKit
@testable import Loopr

/// Lab mode in the Food camera (LV-05.4): the fixture reads, edits, saving to the lab store, the absent and partial
/// states, the blood age line, and that nothing on the path reaches the photo provider.
@MainActor struct FoodLabModelTests {
    private let perth = TimeZone(identifier: "Australia/Perth")!
    /// The photo was taken on 15 November 2023, 13:30 in Perth.
    private let capturedAt = ISO8601DateFormatter().date(from: "2023-11-15T05:30:00Z")!

    private func perthDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = perth
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func dec(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    private func model(_ lines: [LabTextLine]) -> FoodLabModel {
        FoodLabModel(timeZone: perth, reader: FoodLabReader(lift: { _ in nil }, recognize: { _ in lines }), minimumReading: .zero)
    }

    private func read(_ lines: [LabTextLine]) async throws -> FoodLabModel {
        let lab = model(lines)
        await lab.read(try FoodCaptureFixtures.photo(at: capturedAt))
        return lab
    }

    /// One row per entry, top to bottom, each cell at its column.
    private func page(_ rows: [[(String, Double)]]) -> [LabTextLine] {
        rows.enumerated().flatMap { index, cells in
            cells.map { LabTextLine(text: $0.0, minX: $0.1, minY: 0.9 - Double(index) * 0.03, width: 0.1, height: 0.015, confidence: 0.98) }
        }
    }

    private func temporaryStore() throws -> (LabStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodLabModelTests-\(UUID().uuidString)")
        let database = try StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "food-lab-tests")
        return (LabStore(database: database), root)
    }

    // MARK: Fixture reads

    @Test func theEnglishFixtureReadsEveryValueWithOneToCheck() async throws {
        let lab = try await read(FoodLabFixture.lines(.english))
        #expect(lab.stage == .review && lab.problem == nil)
        #expect(lab.values.count == 29)
        #expect(lab.needsReviewCount == 1)
        #expect(lab.values[3].subject == .marker(.crp) && lab.values[3].needsReview && lab.values[3].scanConfidence == FoodLabFixture.uncertainConfidence)
        #expect(lab.summary == "29 values read · 1 needs a look")
        #expect(lab.skippedLine == nil && !lab.dateMissing)
        #expect(lab.collectedAt == perthDate(2023, 11, 13, 8, 15))
        #expect(lab.labName == "Sample Diagnostics Laboratory")
        #expect(lab.draft?.report.source == .scan && lab.values.allSatisfy { $0.source == .scan })
        // Units stay as printed, never converted.
        #expect(lab.values.first { $0.subject == .marker(.whiteBloodCellCount) }?.unit == "x10E3/uL")
        // Every value found its row on the page, top to bottom.
        let rows = lab.rows.compactMap { $0 }
        #expect(rows.count == 29 && zip(rows, rows.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func theGermanFixtureReadsDecimalCommasWithOneToCheck() async throws {
        let lab = try await read(FoodLabFixture.lines(.german))
        #expect(lab.stage == .review)
        #expect(lab.values.count == 29 && lab.needsReviewCount == 1)
        #expect(lab.values[3].subject == .marker(.crp) && lab.values[3].needsReview)
        #expect(lab.labName == "MVZ Labor Beispielstadt")
        #expect(lab.collectedAt == perthDate(2023, 11, 13, 8, 15))
        #expect(lab.values.allSatisfy { !$0.displayValue.contains(",") })
    }

    @Test func theFixtureReaderLiftsTheRenderedReport() async throws {
        let photo = try FoodLabFixture.photo(.english, at: capturedAt)
        let lab = FoodLabModel(timeZone: perth, reader: FoodLabFixture.reader(.english), minimumReading: .zero)
        await lab.read(photo)
        let report = try #require(lab.report)
        #expect(abs(report.aspect - 1_000.0 / 1_400.0) < 0.01)
        #expect(report.region == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(lab.values.count == 29)
    }

    // MARK: Editing

    @Test func confirmingTheUncertainValueClearsItsLookAndKeepsThePrintedUnit() async throws {
        let lab = try await read(FoodLabFixture.lines(.english))
        lab.editing = 3
        #expect(lab.unitChoices(at: 3) == ["mg/L", "mg/dL", "nmol/L"] && lab.unitSymbol(at: 3) == "mg/L")
        #expect(lab.confirm(3, value: "0,7,1", unit: "mg/L") == .invalidNumber)
        #expect(lab.values[3].needsReview && lab.editing == 3)
        #expect(lab.confirm(3, value: "0.7", unit: "mg/L") == .confirmed)
        let crp = lab.values[3]
        #expect(crp.value == dec("0.7") && crp.printedValue == nil && crp.unit == "mg/L" && !crp.needsReview)
        #expect(crp.source == .scan && crp.scanConfidence == FoodLabFixture.uncertainConfidence)
        #expect(lab.needsReviewCount == 0 && lab.reviewLine == "None need a look" && lab.editing == nil)

        // A decimal comma reads as the decimal mark on any phone (ICP R3-LAB-2), and trailing zeros stay as printed.
        #expect(lab.confirm(0, value: "4,60", unit: "g/dL") == .confirmed)
        #expect(lab.values[0].value == dec("4.6") && lab.values[0].printedValue == "4.60")
        // A changed unit is one the marker is reported in; an unchanged one keeps the lab's spelling.
        #expect(lab.confirm(1, value: "72", unit: "g/L") == .unitNotListed)
        #expect(lab.confirm(1, value: "72", unit: nil) == .unitNeeded)
        #expect(lab.confirm(1, value: "72", unit: "µmol/L") == .confirmed)
        #expect(lab.values[1].unit == "µmol/L")
        #expect(lab.confirm(8, value: "5.9", unit: "10^3/µL") == .confirmed)
        #expect(lab.values[8].unit == "x10E3/uL")
        // A test Loopr has no entry for keeps its unit as printed.
        let b12 = try #require(lab.values.firstIndex { $0.subject == .other(name: "Vitamin B12, Active") })
        #expect(lab.unitChoices(at: b12).isEmpty)
        #expect(lab.confirm(b12, value: "90", unit: nil) == .confirmed)
        #expect(lab.values[b12].unit == "pmol/L" && lab.values[b12].value == dec("90"))
    }

    @Test func theAmberValueSaysWhyAndShowsTheNameAsPrinted() async throws {
        let lab = try await read(FoodLabFixture.lines(.english))
        #expect(lab.reasons(at: 3) == [.faintRow])
        #expect(lab.reasons(at: 0).isEmpty)
        #expect(!FoodLabModel.sentence(for: .faintRow).isEmpty)
        // "Glucose, fasting" is shown as Glucose, so the printed name is offered; "hs-CRP" is its own assay name.
        #expect(lab.printedName(at: 2) == "Glucose, fasting")
        #expect(lab.printedName(at: 3) == nil)
        #expect(lab.confirm(3, value: "0.6", unit: "mg/L") == .confirmed)
        #expect(lab.reasons(at: 3).isEmpty)
    }

    @Test func aWrongValueCanBeRemovedAndAWrongMatchMovedToAnotherTest() async throws {
        let lab = try await read(FoodLabFixture.lines(.english))
        lab.finishFlight()
        let second = lab.values[1]
        lab.editing = 0
        lab.remove(0)
        #expect(lab.values.count == 28 && lab.values[0] == second && lab.rows.count == 28)
        #expect(lab.landed == Set(0..<28) && lab.editing == nil)

        // Hemoglobin read as HbA1c: the number stays, the unit is cleared because HbA1c is not reported in g/dL.
        let hemoglobin = try #require(lab.values.firstIndex { $0.subject == .marker(.hemoglobin) })
        lab.reassign(hemoglobin, to: .marker(.hba1c))
        #expect(lab.values[hemoglobin].subject == .marker(.hba1c) && lab.values[hemoglobin].unit == nil)
        #expect(lab.values[hemoglobin].needsReview && lab.reasons(at: hemoglobin) == [.unitMissing])
        // A move to a test reported in the same unit keeps it.
        let ldl = try #require(lab.values.firstIndex { $0.subject == .marker(.ldlCholesterol) })
        lab.reassign(ldl, to: .marker(.hdlCholesterol))
        #expect(lab.values[ldl].unit == "mg/dL" && !lab.values[ldl].needsReview)
    }

    @Test func aResultPrintedAsALimitIsReadAndKeptWithItsSign() async throws {
        let lab = try await read(page([[("hs-CRP", 0.05), ("<0.3", 0.36), ("mg/L", 0.53), ("< 3.0", 0.7)],
                                       [("Apolipoprotein B", 0.05), (">200", 0.36), ("H", 0.46), ("mg/dL", 0.53), ("< 90", 0.7)]]))
        #expect(lab.stage == .review && lab.values.count == 2 && lab.skippedLine == nil)
        #expect(lab.values[0].comparator == .lessThan && lab.values[0].value == dec("0.3"))
        #expect(lab.valueText(at: 0, locale: Locale(identifier: "de_DE")) == "<0,3")
        #expect(lab.values[1].comparator == .greaterThan && lab.values[1].flagText == "H")
        // Every row still finds its place on the page.
        #expect(lab.rows.allSatisfy { $0 != nil })
        // Typing it back with a sign keeps the sign; without one, the result is exact.
        #expect(lab.confirm(0, value: "<0,2", unit: "mg/L") == .confirmed)
        #expect(lab.values[0].comparator == .lessThan && lab.values[0].value == dec("0.2"))
        #expect(lab.confirm(0, value: "0.25", unit: "mg/L") == .confirmed)
        #expect(lab.values[0].comparator == nil)
        // A limit is not a number blood age can take.
        var values = try await read(FoodLabFixture.lines(.english)).values
        let crp = try #require(values.firstIndex { $0.subject == .marker(.crp) })
        values[crp].comparator = .lessThan
        #expect(!FoodLabModel.bloodAgeReady(values))
    }

    @Test func aValueWithoutAUnitStaysWithoutOneUntilThePersonPicksIt() async throws {
        let lab = try await read(page([[("Albumin", 0.05), ("4.6", 0.36), ("3.5 - 5.2", 0.7)]]))
        let albumin = try #require(lab.values.first)
        #expect(albumin.unit == nil && albumin.needsReview)
        #expect(lab.unitSymbol(at: 0) == nil)
        #expect(lab.confirm(0, value: "4.6", unit: nil) == .unitNeeded)
        #expect(lab.values[0].unit == nil && lab.values[0].needsReview)
    }

    // MARK: Saving

    @Test func savingWritesTheReportAndEveryValueWithSourceScan() async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = try await read(FoodLabFixture.lines(.english))
        #expect(lab.confirm(3, value: "0.6", unit: "mg/L") == .confirmed)

        await lab.save(to: nil)
        #expect(lab.stage == .review && lab.saveError != nil)
        await lab.save(to: store)
        #expect(lab.stage == .saved && lab.savedCount == 29 && lab.saveError == nil)

        let reports = try store.reports()
        let report = try #require(reports.first)
        #expect(reports.count == 1 && report.source == .scan)
        #expect(report.labName == "Sample Diagnostics Laboratory" && report.collectedAt == perthDate(2023, 11, 13, 8, 15))
        #expect(report.timeZoneIdentifier == "Australia/Perth")
        let saved = try store.values(reportID: report.id)
        #expect(saved.count == 29 && saved.allSatisfy { $0.source == .scan })
        #expect(saved.map(\.subject) == lab.values.map(\.subject))
        #expect(saved[3].value == dec("0.6") && !saved[3].needsReview && saved[3].referenceRange.text == "<3.0")
        #expect(saved.first { $0.subject == .marker(.apoB) }?.flagText == "H")
    }

    @Test func anUncheckedValueIsSavedStillNeedingALook() async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = try await read(FoodLabFixture.lines(.english))
        await lab.save(to: store)
        let report = try #require(try store.reports().first)
        #expect(try store.values(reportID: report.id).filter(\.needsReview).map(\.subject) == [.marker(.crp)])
    }

    @Test func theNextPageOfTheSameDrawAddsToTheSameReportAndBloodAgeSeesBoth() async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = model([])
        // Page 1: the chemistry, with the date and the lab.
        lab.accept(page([[("Sample Diagnostics Laboratory", 0.05)], [("Collected:", 0.05), ("November 13, 2023 08:15", 0.2)],
                         [("Albumin", 0.05), ("4.6", 0.36), ("g/dL", 0.53), ("3.5 - 5.2", 0.7)],
                         [("Creatinine", 0.05), ("0.82", 0.36), ("mg/dL", 0.53), ("0.60 - 1.20", 0.7)],
                         [("Glucose", 0.05), ("88", 0.36), ("mg/dL", 0.53), ("70 - 99", 0.7)],
                         [("hs-CRP", 0.05), ("0.6", 0.36), ("mg/L", 0.53), ("< 3.0", 0.7)],
                         [("Alkaline Phosphatase", 0.05), ("64", 0.36), ("U/L", 0.53), ("40 - 129", 0.7)]]), capturedAt: capturedAt)
        #expect(lab.stage == .review && lab.values.count == 5 && !lab.bloodAgeReady && lab.sessionLine == nil)
        await lab.save(to: store, birthYear: { 1985 })
        #expect(lab.stage == .saved && lab.savedTitle == "5 values saved" && lab.savedPlaceLine == nil)
        let first = try #require(lab.savedReportID)
        #expect(lab.outcome?.bloodAgeLine?.hasPrefix("Blood age needs 4 more values from this draw") == true)

        // Page 2: the blood count, with no date and no lab name printed, read a moment later.
        lab.reset()
        lab.accept(page([[("Page 2 of 2", 0.05)],
                         [("Lymphocytes %", 0.05), ("31", 0.36), ("%", 0.53), ("20 - 40", 0.7)],
                         [("MCV", 0.05), ("89.4", 0.36), ("fL", 0.53), ("80.0 - 100.0", 0.7)],
                         [("RDW", 0.05), ("12.9", 0.36), ("%", 0.53), ("11.5 - 14.5", 0.7)],
                         [("White Blood Cell Count", 0.05), ("5.9", 0.36), ("x10E3/uL", 0.53), ("3.4 - 10.8", 0.7)],
                         [("Glucose", 0.05), ("88", 0.36), ("mg/dL", 0.53), ("70 - 99", 0.7)]]), capturedAt: capturedAt.addingTimeInterval(120))
        #expect(lab.dateFromSession && lab.collectedAt == perthDate(2023, 11, 13, 8, 15))
        #expect(lab.addsToSession && lab.sessionLine?.hasPrefix("Adds to the") == true)
        #expect(lab.bloodAgeReady, "the two pages together hold all nine")
        await lab.save(to: store, birthYear: { 1985 })
        #expect(lab.stage == .saved && lab.savedReportID == first && lab.savedIntoExisting)
        // Glucose repeats on the second page and is not saved twice.
        #expect(lab.savedCount == 4 && lab.savedRepeats == 1 && lab.savedReportTotal == 9)
        #expect(lab.savedTitle == "4 values added")
        #expect(try store.reports().count == 1 && store.values(reportID: first).count == 9)
        #expect(lab.outcome?.bloodAgeLine?.hasPrefix("Blood age ") == true)
        if case .calculated? = lab.outcome?.bloodAge {} else { Issue.record("blood age should come out of the two pages") }
    }

    @Test func aPageFromAnotherDayStartsItsOwnReport() async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = model([])
        lab.accept(page([[("Albumin", 0.05), ("4.6", 0.36), ("g/dL", 0.53), ("3.5 - 5.2", 0.7)]]), capturedAt: capturedAt)
        await lab.save(to: store)
        let first = try #require(lab.savedReportID)
        lab.reset()
        lab.accept(page([[("Collected:", 0.05), ("November 1, 2023 08:15", 0.2)],
                         [("Albumin", 0.05), ("4.4", 0.36), ("g/dL", 0.53), ("3.5 - 5.2", 0.7)]]), capturedAt: capturedAt)
        #expect(!lab.addsToSession && lab.sessionLine?.contains("its own report") == true)
        await lab.save(to: store)
        #expect(lab.savedReportID != first && !lab.savedIntoExisting)
        #expect(try store.reports().count == 2)
    }

    // MARK: Absent and partial

    @Test func aPageWithNothingReadableIsEmpty() async throws {
        let lab = try await read(FoodLabFixture.lines(.empty))
        #expect(lab.stage == .problem && lab.problem == .empty(skippedRows: 0) && lab.values.isEmpty)
    }

    @Test func rowsThatCouldNotBeReadAreCounted() async throws {
        let garbled: [(String, Double)] = [("Homocystein", 0.05), ("9?2", 0.36), ("µmol/l", 0.53), ("< 12,0", 0.7)]
        let partial = try await read(page([[("Albumin", 0.05), ("46,2", 0.36), ("g/l", 0.53), ("35 - 52", 0.7)], garbled]))
        #expect(partial.stage == .review && partial.values.count == 1)
        #expect(partial.skippedLine == "1 row could not be read")
        #expect(partial.spokenSummary.contains("1 row could not be read"))

        let nothing = try await read(page([garbled]))
        #expect(nothing.stage == .problem && nothing.problem == .empty(skippedRows: 1))
    }

    @Test func withoutAPrintedDateTheCaptureDateStandsInUntilChanged() async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = try await read(page([[("Albumin", 0.05), ("4.6", 0.36), ("g/dL", 0.53), ("3.5 - 5.2", 0.7)]]))
        #expect(lab.dateMissing && lab.collectedAt == capturedAt)
        let drawn = perthDate(2023, 11, 10, 9, 0)
        lab.collectedAt = drawn
        await lab.save(to: store)
        #expect(try store.reports().first?.collectedAt == drawn)
    }

    @Test func aFailedReadIsAProblemNotAnEmptyPage() async throws {
        let lab = FoodLabModel(timeZone: perth, reader: FoodLabReader(lift: { _ in nil }, recognize: { _ in throw FoodLabReadError.noPage }),
                               minimumReading: .zero)
        await lab.read(try FoodCaptureFixtures.photo(at: capturedAt))
        #expect(lab.stage == .problem && lab.problem == .unreadable)
        lab.reset()
        #expect(lab.stage == .live && lab.problem == nil && lab.values.isEmpty)
    }

    // MARK: Blood age

    @Test func theBloodAgeLineFollowsThePhenoAgeInputs() async throws {
        let lab = try await read(FoodLabFixture.lines(.english))
        #expect(lab.bloodAgeReady && lab.spokenSummary.hasSuffix("Blood age can be calculated."))
        let values = lab.values
        #expect(FoodLabModel.bloodAgeReady(values))
        #expect(!FoodLabModel.bloodAgeReady(values.filter { $0.subject != .marker(.albumin) }))
        var noUnit = values
        let albumin = try #require(noUnit.firstIndex { $0.subject == .marker(.albumin) })
        noUnit[albumin].unit = nil
        #expect(!FoodLabModel.bloodAgeReady(noUnit))
        #expect(!FoodLabModel.bloodAgeReady(values + [values[albumin]]))
        #expect(!FoodLabModel.bloodAgeReady([]))
        let partial = try await read(page([[("Albumin", 0.05), ("4.6", 0.36), ("g/dL", 0.53), ("3.5 - 5.2", 0.7)]]))
        #expect(!partial.bloodAgeReady && !partial.spokenSummary.contains("Blood age"))
    }

    // MARK: Flight

    @Test func theFlightLandsEachValuesDotsOnItsChipOnce() async throws {
        let lab = try await read(FoodLabFixture.lines(.english))
        let chips = Dictionary(uniqueKeysWithValues: lab.values.indices.map { ($0, CGRect(x: 20, y: 400 + CGFloat($0) * 10, width: 80, height: 44)) })
        let plan = try #require(FoodLabFlight.plan(rows: lab.rows, review: lab.values.map(\.needsReview),
                                                   page: CGRect(x: 60, y: 80, width: 260, height: 364), chips: chips,
                                                   sweep: FoodLabFlight.sweepDuration(values: 29), read: .green, uncertain: .orange))
        #expect(plan.request.landings.count == 29 * FoodLabFlight.dotsPerValue)
        #expect(Set(plan.owners) == Set(lab.values.indices))
        // Dots break off as the light reaches their row: a lower row spawns later.
        let firstSpawn = plan.request.landings[0].dot.spawn
        let lastSpawn = plan.request.landings[28 * FoodLabFlight.dotsPerValue].dot.spawn
        #expect(firstSpawn < lastSpawn)
        #expect(plan.request.landings[3 * FoodLabFlight.dotsPerValue].color == .orange)
        #expect(FoodLabFlight.plan(rows: lab.rows, review: [], page: .zero, chips: chips, sweep: 1, read: .green, uncertain: .orange) == nil)

        for index in [0, 1] { lab.land(index) }
        #expect(lab.landed == [0, 1] && !lab.flightFinished)
        lab.finishFlight()
        #expect(lab.landed == Set(lab.values.indices) && lab.flightFinished)
    }

    // MARK: Privacy

    @Test func labModeNeverTouchesThePhotoProviderOrItsConsent() async throws {
        let suite = "FoodLabModelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = CoachProviderConfiguration(provider: .anthropic, model: CoachProvider.anthropic.defaultModel)
        defaults.set(try JSONEncoder().encode([configuration]), forKey: LooprAISettingsRuntime.providersKey)
        defaults.set(CoachProvider.anthropic.rawValue, forKey: LooprAISettingsRuntime.selectedKey)
        let before = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)
        let credentials = CountingCredentials()
        let provider = CountingProvider()
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.anthropic: credentials, .openAI: credentials],
                                             transport: provider, structuredTransport: provider)
        let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        let draft = FoodMealDraft(slot: .lunch, occurredAt: capturedAt, timeZoneIdentifier: "Australia/Perth")
        let model = FoodLensModel(draft: draft, repository: AppFoodRepository(environment: environment), runtime: runtime,
                                  fixture: false, now: capturedAt, labReader: FoodLabFixture.reader(.english))
        model.lens = .lab
        await model.readLab(try FoodLabFixture.photo(.english, at: capturedAt)).value

        #expect(model.lab.stage == .review && model.lab.values.count == 29)
        #expect(model.labActive)
        // Nothing was asked of the provider: no key read, no request, no consent written.
        #expect(await credentials.reads == 0)
        #expect(provider.calls == 0)
        #expect(Set((defaults.persistentDomain(forName: suite) ?? [:]).keys) == before)
        // The report is not a meal photo and the Food path did not move.
        #expect(model.stage == .live && model.problem == nil && model.kind == nil)
        #expect(model.draft.photos.isEmpty && model.draft.items.isEmpty)
    }
}

private actor CountingCredentials: AICredentialStore {
    private(set) var reads = 0
    func read() -> Data? { reads += 1; return Data("fixture-not-a-real-key".utf8) }
    func write(_ value: Data) {}
    func remove() {}
}

/// Counts every request a provider would get. Lab mode must make none.
private final class CountingProvider: CoachChatTransport, CoachStructuredTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    private func record() { lock.withLock { count += 1 } }

    func stream(_ request: CoachChatRequest, key: String) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        record()
        return AsyncThrowingStream { $0.finish(throwing: CoachProviderError.offline) }
    }
    func models(provider: CoachProvider, key: String) async throws -> [String] { record(); return [] }
    func structured(_ request: CoachStructuredRequest, key: String) async throws -> Data { record(); throw CoachProviderError.offline }
}
