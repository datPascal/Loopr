@testable import AnalyticsKit
import XCTest

private func dec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private struct Vector: Decodable {
    struct Value: Decodable { let marker: String; let value: String; let unit: String }
    struct Output: Decodable { let linearPredictor: Double; let phenotypicAge: Double; let mortalityScore: Double }
    struct Expected: Decodable { let pyaging: Output; let bioAge: Output; let liuCorrection: Output }
    let id: String
    let inputSource: String
    let ageYears: Double
    let values: [Value]
    let expected: Expected
}

private struct TransformVector: Decodable {
    let id: String
    let linearPredictor: Double
    let phenotypicAge: Double
    let source: String
}

private struct Fixture: Decodable {
    let vectors: [Vector]
    let transformVectors: [TransformVector]
}

private func loadFixture() throws -> Fixture {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/PhenoAge"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
}

/// What the app uses: Table S1 coefficients, the Table S1 constant and the Supplement 1 conversion constants.
private var pyagingSet: PhenoAgeCoefficients { .published }

/// A set whose sources are not settled, passed in explicitly. Only this can give `coefficientsUnverified`.
private var unverifiedSet: PhenoAgeCoefficients {
    let published = PhenoAgeCoefficients.published
    return PhenoAgeCoefficients(intercept: published.intercept, markerCoefficients: published.markerCoefficients,
                                ageCoefficient: published.ageCoefficient, divisor: 0.09165,
                                verification: .unverified(disagreement: "test set"))
}

/// BioAge `orig = TRUE`: seven-digit coefficients, 0.0055305 and the 0.090165 divisor.
private let bioAgeSet = PhenoAgeCoefficients(
    intercept: -19.90667,
    markerCoefficients: [
        .albumin: -0.03359355, .creatinine: 0.009506491, .glucose: 0.1953192, .crp: 0.09536762,
        .lymphocytePercent: -0.01199984, .meanCellVolume: 0.02676401, .redCellDistributionWidth: 0.3306156,
        .alkalinePhosphatase: 0.001868778, .whiteBloodCellCount: 0.05542406
    ],
    ageCoefficient: 0.08035356, gamma: 0.007692696, scale: 0.0055305, divisor: 0.090165, verification: .crossChecked)

/// The equations printed in the 2019 PLoS Med correction: 141.50, 0.00553, 0.09165, ALP 0.00188, intercept -19.907.
/// Superseded by Supplement 1 and never used by the app; kept to show how far it differs.
private let liuSet = PhenoAgeCoefficients(
    intercept: -19.907,
    markerCoefficients: [
        .albumin: -0.0336, .creatinine: 0.0095, .glucose: 0.1953, .crp: 0.0954, .lymphocytePercent: -0.0120,
        .meanCellVolume: 0.0268, .redCellDistributionWidth: 0.3306, .alkalinePhosphatase: 0.00188, .whiteBloodCellCount: 0.0554
    ],
    ageCoefficient: 0.0804, offsetYears: 141.50, divisor: 0.09165, verification: .crossChecked)

final class PhenoAgeEngineTests: XCTestCase {
    private let reportID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private let drawn = Date(timeIntervalSince1970: 1_789_193_700) // 12 September 2026, 08:15 in Berlin

    private func reading(_ key: LabMarkerKey, _ value: String, _ unit: String?, printed: String? = nil, at date: Date? = nil,
                         zone: String = "Europe/Berlin") -> PhenoAgeReading {
        let labValue = LabValue(reportID: reportID, subject: .marker(key), value: dec(value), printedValue: printed, unit: unit, source: .typed)
        return PhenoAgeReading(value: labValue, collectedAt: date ?? drawn, timeZoneIdentifier: zone)
    }

    /// A complete draw in the units PhenoAge uses.
    private func siReadings() -> [PhenoAgeReading] {
        [
            reading(.albumin, "46", "g/L"), reading(.creatinine, "70", "µmol/L"), reading(.glucose, "5.0", "mmol/L"),
            reading(.crp, "0.5", "mg/dL"), reading(.lymphocytePercent, "30", "%"), reading(.meanCellVolume, "90", "fL"),
            reading(.redCellDistributionWidth, "13", "%"), reading(.alkalinePhosphatase, "70", "U/L"),
            reading(.whiteBloodCellCount, "7", "10^3/µL")
        ]
    }

    private func inputs(_ readings: [PhenoAgeReading]? = nil, age: Double = 50) -> PhenoAgeInputs {
        PhenoAgeInputs(readings: readings ?? siReadings(), chronologicalAgeYears: age)
    }

    private func replacing(_ key: LabMarkerKey, with new: PhenoAgeReading) -> [PhenoAgeReading] {
        siReadings().map { $0.value.subject == .marker(key) ? new : $0 }
    }

    private func readings(from vector: Vector) throws -> [PhenoAgeReading] {
        try vector.values.map { value in
            let key = try XCTUnwrap(LabMarkerKey(rawValue: value.marker), value.marker)
            return reading(key, value.value, value.unit)
        }
    }

    // MARK: Matches the open implementations

    func testTheTransformMatchesTheValuesPyagingPrints() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.transformVectors.count, 3)
        for vector in fixture.transformVectors {
            let age = try XCTUnwrap(PhenoAge.phenotypicAge(linearPredictor: vector.linearPredictor, coefficients: pyagingSet))
            XCTAssertEqual(age, vector.phenotypicAge, accuracy: 1e-9, vector.id)
        }
    }

    func testTheEngineReproducesPyagingOnEveryVectorToDoublePrecision() throws {
        for vector in try loadFixture().vectors {
            let result = PhenoAge.calculate(inputs: PhenoAgeInputs(readings: try readings(from: vector), chronologicalAgeYears: vector.ageYears), coefficients: pyagingSet)
            let estimate = try XCTUnwrap(result.estimate, vector.id)
            XCTAssertEqual(estimate.linearPredictor, vector.expected.pyaging.linearPredictor, accuracy: 1e-9, vector.id)
            XCTAssertEqual(estimate.phenotypicAgeYears, vector.expected.pyaging.phenotypicAge, accuracy: 1e-8, vector.id)
            XCTAssertEqual(estimate.mortalityScore, vector.expected.pyaging.mortalityScore, accuracy: 1e-10, vector.id)
        }
    }

    /// Levine prints the coefficients to four decimals, so each can be off by half a unit in the fourth decimal. That
    /// moves the linear predictor by at most the sum of |input| x 0.00005, plus the intercept's 0.00005, and one unit
    /// of linear predictor is 1 / 0.090165 years. The mortality score moves by that factor in relative terms.
    private func printingBound(_ estimate: PhenoAgeEstimate) -> (years: Double, relativeMortality: Double) {
        let inputs = estimate.inputs.reduce(0.0) { $0 + abs($1.marker == .crp ? log($1.value) : $1.value) } + estimate.chronologicalAgeYears
        let linear = (inputs + 1) * 0.00005
        return (linear / 0.090165, expm1(linear))
    }

    func testTheEngineAgreesWithBioAgesSevenDigitCoefficientsWithinTheFourDecimalPrintingBound() throws {
        for vector in try loadFixture().vectors {
            let estimate = try XCTUnwrap(PhenoAge.calculate(inputs: PhenoAgeInputs(readings: try readings(from: vector), chronologicalAgeYears: vector.ageYears), coefficients: pyagingSet).estimate, vector.id)
            let bound = printingBound(estimate)
            XCTAssertLessThan(bound.years, 0.3, "the bound is meant to be small: \(vector.id)")
            XCTAssertEqual(estimate.phenotypicAgeYears, vector.expected.bioAge.phenotypicAge, accuracy: bound.years, vector.id)
            XCTAssertLessThanOrEqual(abs(estimate.mortalityScore / vector.expected.bioAge.mortalityScore - 1), bound.relativeMortality, vector.id)
        }
    }

    func testTheEngineWithBioAgesOwnConstantsReproducesBioAge() throws {
        for vector in try loadFixture().vectors {
            let estimate = try XCTUnwrap(PhenoAge.calculate(inputs: PhenoAgeInputs(readings: try readings(from: vector), chronologicalAgeYears: vector.ageYears), coefficients: bioAgeSet).estimate, vector.id)
            XCTAssertEqual(estimate.linearPredictor, vector.expected.bioAge.linearPredictor, accuracy: 1e-9, vector.id)
            // BioAge hard-codes exp(120 x gamma) - 1 as 1.51714; the engine computes it. Both agree to five digits.
            XCTAssertEqual(estimate.phenotypicAgeYears, vector.expected.bioAge.phenotypicAge, accuracy: 1e-3, vector.id)
            XCTAssertEqual(estimate.mortalityScore, vector.expected.bioAge.mortalityScore, accuracy: 1e-5, vector.id)
        }
    }

    func testThePLoSCorrectionsDivisorGivesADifferentAgeAndIsNotUsed() throws {
        XCTAssertEqual(PhenoAgeCoefficients.published.divisor, 0.090165)
        XCTAssertNotEqual(PhenoAgeCoefficients.published.divisor, 0.09165)
        for vector in try loadFixture().vectors {
            let readings = try readings(from: vector)
            let inputs = PhenoAgeInputs(readings: readings, chronologicalAgeYears: vector.ageYears)
            let liu = try XCTUnwrap(PhenoAge.calculate(inputs: inputs, coefficients: liuSet).estimate, vector.id)
            // The correction prints 1.51714 for exp(120 x gamma) - 1; the engine computes 1.5171417, worth 1e-5 years.
            XCTAssertEqual(liu.phenotypicAgeYears, vector.expected.liuCorrection.phenotypicAge, accuracy: 1e-4, vector.id)
            let used = try XCTUnwrap(PhenoAge.calculate(inputs: inputs).estimate, vector.id)
            let gap = liu.phenotypicAgeYears - used.phenotypicAgeYears
            XCTAssertGreaterThan(gap, 1.0, "the superseded divisor is material: \(vector.id)")
            XCTAssertLessThan(gap, 2.5, vector.id)
            XCTAssertEqual(used.phenotypicAgeYears, vector.expected.pyaging.phenotypicAge, accuracy: 1e-8, vector.id)
        }
    }

    // MARK: Verification

    func testThePublishedSetIsCrossCheckedAndComputesABloodAge() throws {
        XCTAssertTrue(PhenoAgeCoefficients.published.isVerified)
        XCTAssertEqual(PhenoAgeCoefficients.published.verification, .crossChecked)
        let estimate = try XCTUnwrap(PhenoAge.calculate(inputs: inputs()).estimate)
        XCTAssertEqual(estimate.coefficientsVerification, .crossChecked)
        XCTAssertEqual(estimate.version, "loopr.phenoage.1")
        XCTAssertNil(PhenoAge.calculate(inputs: inputs()).absence)
    }

    func testOnlyAnExplicitlyUnverifiedSetLeavesBloodAgeAbsentForTheCoefficients() throws {
        XCTAssertFalse(unverifiedSet.isVerified)
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(), coefficients: unverifiedSet), .unavailable(.coefficientsUnverified))
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(), coefficients: unverifiedSet).absence, .coefficientsUnverified)
        for vector in try loadFixture().vectors {
            let readings = try self.readings(from: vector)
            XCTAssertNotEqual(PhenoAge.calculate(inputs: PhenoAgeInputs(readings: readings, chronologicalAgeYears: vector.ageYears)).absence, .coefficientsUnverified)
        }
    }

    func testTheSupersededDivisorIsRecordedWithThePrimarySource() {
        let superseded = PhenoAgeCrossCheck.supersededRecords
        XCTAssertEqual(superseded.map(\.name), ["Age divisor"])
        XCTAssertEqual(superseded.first?.levine2018.hasPrefix("0.090165"), true)
        XCTAssertEqual(superseded.first?.pyaging, "0.090165")
        XCTAssertEqual(superseded.first?.liuCorrection, "0.09165")
        XCTAssertTrue(PhenoAgeCrossCheck.primarySource.contains("5a0b7bf66f1b08079a9ecaf036a26613c61e00f8a8e35e5c13f9bacb61d7cd2c"))
        XCTAssertTrue(PhenoAgeCrossCheck.primarySource.contains("aging-10-101414-s001.pdf"))
        XCTAssertTrue(PhenoAgeCrossCheck.divisorNote.contains("0.09165"))
    }

    func testEveryInputProblemIsStillNamedBeforeTheCoefficientsAreChecked() {
        var missing = siReadings()
        missing.removeAll { $0.value.subject == .marker(.albumin) }
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(missing), coefficients: unverifiedSet), .unavailable(.missingMarkers([.albumin])))
    }

    // MARK: Coefficient table

    private let markerNames: [String: LabMarkerKey] = [
        "Albumin": .albumin, "Creatinine": .creatinine, "Glucose": .glucose, "C-reactive protein, natural log": .crp,
        "Lymphocyte percent": .lymphocytePercent, "Mean cell volume": .meanCellVolume,
        "Red cell distribution width": .redCellDistributionWidth, "Alkaline phosphatase": .alkalinePhosphatase,
        "White blood cell count": .whiteBloodCellCount
    ]

    private func leadingNumber(_ text: String) -> Double? {
        Double(text.split(separator: " ").first.map(String.init) ?? "")
    }

    func testEveryCoefficientCitesThePaperAndBothImplementationsAndMatchesTheEngine() throws {
        let records = PhenoAgeCrossCheck.records
        XCTAssertEqual(records.count, 16)
        for record in records {
            XCTAssertFalse(record.levine2018.isEmpty, record.name)
            XCTAssertFalse(record.pyaging.isEmpty, record.name)
            XCTAssertFalse(record.bioAge.isEmpty, record.name)
            XCTAssertFalse(record.liuCorrection.isEmpty, record.name)
        }
        let published = PhenoAgeCoefficients.published
        for (name, key) in markerNames {
            let record = try XCTUnwrap(records.first { $0.name == name }, name)
            let paper = try XCTUnwrap(leadingNumber(record.levine2018), name)
            let pyaging = try XCTUnwrap(leadingNumber(record.pyaging), name)
            let bioAge = try XCTUnwrap(leadingNumber(record.bioAge), name)
            XCTAssertEqual(published.markerCoefficients[key], paper, name)
            XCTAssertEqual(pyaging, paper, name)
            // BioAge's seven digits round to the paper's printed value.
            let decimals = (record.levine2018.split(separator: " ").first ?? "").split(separator: ".").last?.count ?? 0
            let scale = pow(10.0, Double(decimals))
            XCTAssertEqual((bioAge * scale).rounded() / scale, paper, accuracy: 1e-12, name)
            XCTAssertEqual(record.agreement, .agrees, name)
        }
        let age = try XCTUnwrap(records.first { $0.name == "Chronological age" })
        XCTAssertEqual(published.ageCoefficient, leadingNumber(age.levine2018))
        XCTAssertEqual(published.ageCoefficient, leadingNumber(age.pyaging))
        let intercept = try XCTUnwrap(records.first { $0.name == "Intercept" })
        XCTAssertEqual(published.intercept, leadingNumber(intercept.pyaging))
        XCTAssertEqual((leadingNumber(intercept.bioAge)! * 1000).rounded() / 1000, leadingNumber(intercept.liuCorrection))
        XCTAssertEqual(published.gamma, leadingNumber(try XCTUnwrap(records.first { $0.name == "Gompertz gamma" }).pyaging))
        XCTAssertEqual(published.offsetYears, leadingNumber(try XCTUnwrap(records.first { $0.name == "Age offset" }).pyaging))
        XCTAssertEqual(published.scale, leadingNumber(try XCTUnwrap(records.first { $0.name == "Age scale" }).pyaging))
        XCTAssertEqual(published.divisor, leadingNumber(try XCTUnwrap(records.first { $0.name == "Age divisor" }).pyaging))
        XCTAssertEqual(published.horizonMonths, 120)
        XCTAssertEqual(Set(published.markerCoefficients.keys), Set(PhenoAge.inputMarkers))
        // 1.51714 in BioAge and in the correction is exp(120 x gamma) - 1.
        XCTAssertEqual(expm1(published.horizonMonths * published.gamma), 1.51714, accuracy: 1e-5)
    }

    func testTheCrossCheckUsesNoJudgingWords() {
        let text = PhenoAgeCrossCheck.records.map { [$0.name, $0.levine2018, $0.pyaging, $0.bioAge, $0.liuCorrection, $0.note ?? ""].joined(separator: " ") }
            .joined(separator: " ") + PhenoAgeCrossCheck.divisorNote + PhenoAgeCrossCheck.primarySource
        for word in ["good", "bad", "normal", "abnormal", "healthy", "unhealthy", "optimal", "better", "worse"] {
            XCTAssertFalse(text.lowercased().contains(word), word)
        }
    }

    // MARK: Absence

    func testInvalidChronologicalAgeLeavesBloodAgeAbsent() {
        for age in [0.0, -3, .nan, .infinity] {
            XCTAssertEqual(PhenoAge.calculate(inputs: inputs(age: age), coefficients: pyagingSet), .unavailable(.invalidChronologicalAge), "\(age)")
        }
    }

    func testAMissingMarkerLeavesBloodAgeAbsentAndNamesEveryMissingOne() {
        var partial = siReadings()
        partial.removeAll { $0.value.subject == .marker(.crp) || $0.value.subject == .marker(.albumin) }
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(partial), coefficients: pyagingSet), .unavailable(.missingMarkers([.albumin, .crp])))
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs([]), coefficients: pyagingSet), .unavailable(.missingMarkers(PhenoAge.inputMarkers)))
        // An other-named value is not a marker.
        let other = PhenoAgeReading(value: LabValue(reportID: reportID, subject: .other(name: "Albumin"), value: dec("46"), unit: "g/L", source: .typed),
                                    collectedAt: drawn, timeZoneIdentifier: "Europe/Berlin")
        var withOther = siReadings()
        withOther.removeAll { $0.value.subject == .marker(.albumin) }
        withOther.append(other)
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(withOther), coefficients: pyagingSet), .unavailable(.missingMarkers([.albumin])))
    }

    func testTwoValuesForOneMarkerAreNotResolvedByGuessing() {
        let twice = siReadings() + [reading(.glucose, "5.4", "mmol/L")]
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(twice), coefficients: pyagingSet), .unavailable(.ambiguousMarker(.glucose)))
    }

    func testReadingsFromDifferentDaysAreNotOneDraw() {
        let nextDay = reading(.glucose, "5.0", "mmol/L", at: drawn.addingTimeInterval(86_400))
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(replacing(.glucose, with: nextDay)), coefficients: pyagingSet), .unavailable(.notFromOneDraw))
        let badZone = reading(.glucose, "5.0", "mmol/L", zone: "Mars/Olympus")
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(replacing(.glucose, with: badZone)), coefficients: pyagingSet), .unavailable(.notFromOneDraw))
    }

    func testReadingsFromTheSameLocalDayAreOneDrawWhateverTheTime() {
        let evening = reading(.glucose, "5.0", "mmol/L", at: drawn.addingTimeInterval(10 * 3_600))
        XCTAssertNotNil(PhenoAge.calculate(inputs: inputs(replacing(.glucose, with: evening)), coefficients: pyagingSet).estimate)
        // 22:30 UTC on 11 September is already 12 September in Berlin: the same local day as 08:15 Berlin time.
        let lateUTC = reading(.glucose, "5.0", "mmol/L", at: Date(timeIntervalSince1970: 1_789_165_800), zone: "Europe/Berlin")
        XCTAssertNotNil(PhenoAge.calculate(inputs: inputs(replacing(.glucose, with: lateUTC)), coefficients: pyagingSet).estimate)
    }

    func testAUnitThatCannotBeConvertedLeavesBloodAgeAbsentWithTheConvertersReason() {
        let cases: [(LabMarkerKey, String, String?, LabUnitError)] = [
            (.albumin, "46", nil, .missingUnit),
            (.crp, "20", "nmol/L", .noConversion(marker: .crp, from: "nmol/L", to: "mg/dL", reason: .noCitedFactor)),
            (.lymphocytePercent, "1.8", "10^9/L", .noConversion(marker: .lymphocytePercent, from: "10^9/L", to: "%", reason: .percentageAgainstAbsoluteCount)),
            (.glucose, "90", "mg per dl", .unknownUnit("mg per dl")),
            (.creatinine, "70", "g/L", .unitNotListedForMarker(marker: .creatinine, unit: "g/L"))
        ]
        for (key, value, unit, reason) in cases {
            let result = PhenoAge.calculate(inputs: inputs(replacing(key, with: reading(key, value, unit))), coefficients: pyagingSet)
            XCTAssertEqual(result, .unavailable(.nonConvertibleUnit(marker: key, reason: reason)), key.rawValue)
        }
    }

    func testAResultPrintedAsALimitIsNotTakenAsTheNumber() {
        // "<0.3 mg/L" below detection, or ">200" above the measuring range: the limit is not the result, so blood age
        // says which marker was printed that way instead of computing from the limit.
        let cases: [(LabMarkerKey, LabValueComparator, String, String)] = [
            (.crp, .lessThan, "0.3", "mg/L"), (.glucose, .greaterThan, "20", "mmol/L"), (.albumin, .greaterThanOrEqual, "50", "g/L")
        ]
        for (key, comparator, value, unit) in cases {
            var limit = LabValue(reportID: reportID, subject: .marker(key), value: dec(value), unit: unit, source: .typed)
            limit.comparator = comparator
            let reading = PhenoAgeReading(value: limit, collectedAt: drawn, timeZoneIdentifier: "Europe/Berlin")
            let result = PhenoAge.calculate(inputs: inputs(replacing(key, with: reading)), coefficients: pyagingSet)
            XCTAssertEqual(result, .unavailable(.printedAsLimit(key)), key.rawValue)
        }
    }

    func testAnOutOfRangeInputLeavesBloodAgeAbsentAndNothingIsClamped() {
        let cases: [(LabMarkerKey, String, String)] = [
            (.crp, "0", "mg/dL"), (.crp, "-0.1", "mg/dL"), (.crp, "0", "mg/L"),
            (.albumin, "0", "g/L"), (.creatinine, "-70", "µmol/L"), (.glucose, "0", "mmol/L"),
            (.meanCellVolume, "0", "fL"), (.redCellDistributionWidth, "0", "%"),
            (.alkalinePhosphatase, "0", "U/L"), (.whiteBloodCellCount, "0", "10^3/µL"),
            (.lymphocytePercent, "100.5", "%"), (.lymphocytePercent, "-1", "%")
        ]
        for (key, value, unit) in cases {
            let result = PhenoAge.calculate(inputs: inputs(replacing(key, with: reading(key, value, unit))), coefficients: pyagingSet)
            XCTAssertEqual(result, .unavailable(.outOfRangeInput(key)), "\(key.rawValue) \(value) \(unit)")
        }
        // A lymphocyte percent of exactly 0 or 100 is a number the formula can take.
        for value in ["0", "100"] {
            XCTAssertNotNil(PhenoAge.calculate(inputs: inputs(replacing(.lymphocytePercent, with: reading(.lymphocytePercent, value, "%"))), coefficients: pyagingSet).estimate, value)
        }
    }

    func testTheReferenceRangesAreThoseInPyagingsFeatureRangesFile() {
        // pyaging src/pyaging/data/feature_ranges.json at commit c15cf283, in the units PhenoAge uses.
        let expected: [LabMarkerKey: ClosedRange<Double>] = [
            .albumin: 10...70, .creatinine: 10...3000, .glucose: 1...60, .crp: 0.01...50, .lymphocytePercent: 0...100,
            .meanCellVolume: 40...150, .redCellDistributionWidth: 8...40, .alkalinePhosphatase: 5...5000,
            .whiteBloodCellCount: 0.05...500
        ]
        for key in PhenoAge.inputMarkers { XCTAssertEqual(PhenoAge.referenceRange(for: key), expected[key], key.rawValue) }
        XCTAssertEqual(PhenoAge.oldestRegisteredAgeYears, 122.5)
    }

    func testAValueOutsideTheRegisteredRangeIsNotComputedAndNamesTheMarker() {
        let outside: [(LabMarkerKey, String, String)] = [
            (.albumin, "9.9", "g/L"), (.albumin, "70.1", "g/L"), (.albumin, "0.9", "g/dL"),
            (.creatinine, "9", "µmol/L"), (.creatinine, "3001", "µmol/L"),
            (.glucose, "0.9", "mmol/L"), (.glucose, "61", "mmol/L"),
            (.crp, "0.005", "mg/dL"), (.crp, "51", "mg/dL"), (.crp, "0.05", "mg/L"),
            (.meanCellVolume, "39", "fL"), (.meanCellVolume, "151", "fL"),
            (.redCellDistributionWidth, "7.9", "%"), (.redCellDistributionWidth, "41", "%"),
            (.alkalinePhosphatase, "4.9", "U/L"), (.alkalinePhosphatase, "5001", "U/L"),
            (.whiteBloodCellCount, "0.04", "10^3/µL"), (.whiteBloodCellCount, "501", "10^9/L")
        ]
        for (key, value, unit) in outside {
            let result = PhenoAge.calculate(inputs: inputs(replacing(key, with: reading(key, value, unit))))
            XCTAssertEqual(result, .unavailable(.outsideReferenceRange(key)), "\(key.rawValue) \(value) \(unit)")
        }
        // The ends of each range are inside it.
        let ends: [(LabMarkerKey, String, String)] = [
            (.albumin, "10", "g/L"), (.albumin, "70", "g/L"), (.crp, "0.01", "mg/dL"), (.crp, "50", "mg/dL"),
            (.whiteBloodCellCount, "0.05", "10^3/µL"), (.whiteBloodCellCount, "500", "10^3/µL"), (.meanCellVolume, "40", "fL")
        ]
        for (key, value, unit) in ends {
            XCTAssertNotNil(PhenoAge.calculate(inputs: inputs(replacing(key, with: reading(key, value, unit)))).estimate, "\(key.rawValue) \(value)")
        }
    }

    func testAnAgeBeyondTheRegisteredMaximumIsInvalid() {
        XCTAssertEqual(PhenoAge.calculate(inputs: inputs(age: 122.6)), .unavailable(.invalidChronologicalAge))
        XCTAssertNotNil(PhenoAge.calculate(inputs: inputs(age: 122.5)).estimate)
    }

    func testANonFiniteLinearPredictorGivesNoAge() {
        XCTAssertNil(PhenoAge.phenotypicAge(linearPredictor: .infinity, coefficients: pyagingSet))
        XCTAssertNil(PhenoAge.phenotypicAge(linearPredictor: .nan, coefficients: pyagingSet))
        XCTAssertEqual(PhenoAge.mortalityScore(linearPredictor: .infinity, coefficients: pyagingSet), 1)
    }

    // MARK: US units, sources and attribution

    func testUSUnitInputsConvertThroughTheStepTwoFactorsAndKeepTheSource() throws {
        let vector = try XCTUnwrap(loadFixture().vectors.first { $0.id == "mcp-phenoage-clock-readme-us-units" })
        let us = try readings(from: vector)
        XCTAssertEqual(us.compactMap(\.value.unit), ["g/dL", "mg/dL", "mg/dL", "mg/L", "%", "fL", "%", "U/L", "10^3/µL"])
        let estimate = try XCTUnwrap(PhenoAge.calculate(inputs: PhenoAgeInputs(readings: us, chronologicalAgeYears: 45), coefficients: pyagingSet).estimate)
        let used = Dictionary(uniqueKeysWithValues: estimate.inputs.map { ($0.marker, $0) })
        XCTAssertEqual(try XCTUnwrap(used[.albumin]).value, 42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(used[.creatinine]).value, 0.9 * 88.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(used[.glucose]).value, 85 / 18.016, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(used[.crp]).value, 0.05, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(used[.crp]).unit, "mg/dL")
        XCTAssertEqual(try XCTUnwrap(used[.crp]).sourceUnit, "mg/L")
        XCTAssertEqual(try XCTUnwrap(used[.glucose]).sourceValue, dec("85"))
        XCTAssertFalse(try XCTUnwrap(used[.glucose]).conversionCitations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(used[.lymphocytePercent]).conversionCitations.isEmpty)
        XCTAssertEqual(estimate.inputs.map(\.marker), PhenoAge.inputMarkers)
    }

    func testTheSamePersonInUSAndSIUnitsGivesTheSameResult() throws {
        // The US values come from the SI values through the converter's own inverse, so the two draws are the same
        // person and the only thing under test is the engine's conversion on the way back.
        let usUnits: [LabMarkerKey: String] = [.albumin: "g/dL", .creatinine: "mg/dL", .glucose: "mg/dL", .crp: "mg/L"]
        var us: [PhenoAgeReading] = []
        for si in siReadings() {
            guard case .marker(let key) = si.value.subject, let unit = usUnits[key] else { us.append(si); continue }
            let number = try LabUnitConverter.convert(si.value.value, marker: key, from: try XCTUnwrap(si.value.unit), to: unit)
            us.append(PhenoAgeReading(
                value: LabValue(reportID: reportID, subject: si.value.subject, value: number, unit: unit, source: .typed),
                collectedAt: si.collectedAt, timeZoneIdentifier: si.timeZoneIdentifier))
        }
        XCTAssertEqual(us.compactMap(\.value.unit), ["g/dL", "mg/dL", "mg/dL", "mg/L", "%", "fL", "%", "U/L", "10^3/µL"])
        let usEstimate = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(us, age: 50)).estimate)
        let siEstimate = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(siReadings(), age: 50)).estimate)
        XCTAssertEqual(usEstimate.phenotypicAgeYears, siEstimate.phenotypicAgeYears, accuracy: 1e-5)
        XCTAssertEqual(usEstimate.mortalityScore, siEstimate.mortalityScore, accuracy: 1e-8)
        // The same check by hand at the factors the converter cites: 0.8 mg/dL x 88.4 and 90 mg/dL / 18.016.
        XCTAssertEqual(try LabUnitConverter.convert(dec("0.8"), marker: .creatinine, from: "mg/dL", to: "µmol/L"), dec("70.72"))
        XCTAssertEqual(NSDecimalNumber(decimal: try LabUnitConverter.convert(dec("90"), marker: .glucose, from: "mg/dL", to: "mmol/L")).doubleValue, 90 / 18.016, accuracy: 1e-12)
    }

    func testThePrintedDigitsOfAnInputTravelWithTheResult() throws {
        let readings = replacing(.crp, with: reading(.crp, "0.5", "mg/dL", printed: "0.50"))
        let estimate = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(readings), coefficients: pyagingSet).estimate)
        let crp = try XCTUnwrap(estimate.inputs.first { $0.marker == .crp })
        XCTAssertEqual(crp.sourcePrintedValue, "0.50")
        XCTAssertEqual(estimate.version, "loopr.phenoage.1")
        XCTAssertEqual(PhenoAge.version, "loopr.phenoage.1")
    }

    func testTheContributionsAddUpToTheGapFromChronologicalAge() throws {
        let estimate = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(), coefficients: pyagingSet).estimate)
        XCTAssertEqual(estimate.contributions.count, 10)
        XCTAssertEqual(estimate.contributions.last?.term, .baselineAndAge)
        XCTAssertNil(estimate.contributions.last?.linearPredictorTerm)
        let total = estimate.contributions.reduce(0) { $0 + $1.years }
        XCTAssertEqual(total, estimate.differenceYears, accuracy: 1e-9)
        XCTAssertEqual(estimate.differenceYears, estimate.phenotypicAgeYears - 50, accuracy: 1e-12)
        for contribution in estimate.contributions.dropLast() {
            guard case .marker(let key) = contribution.term else { return XCTFail("expected a marker term") }
            let input = try XCTUnwrap(estimate.inputs.first { $0.marker == key })
            let x = key == .crp ? log(input.value) : input.value
            let beta = try XCTUnwrap(pyagingSet.markerCoefficients[key])
            XCTAssertEqual(try XCTUnwrap(contribution.linearPredictorTerm), beta * x, accuracy: 1e-12, key.rawValue)
            XCTAssertEqual(contribution.years, beta * x / 0.090165, accuracy: 1e-12, key.rawValue)
        }
        // The attribution is exact: every term moves the age by its linear predictor term over the divisor.
        let sumOfTerms = estimate.contributions.dropLast().reduce(0) { $0 + ($1.linearPredictorTerm ?? 0) }
        XCTAssertEqual(estimate.linearPredictor, pyagingSet.intercept + sumOfTerms + pyagingSet.ageCoefficient * 50, accuracy: 1e-12)
    }

    func testAgainstTheNHANESAverageTheShiftsAndTheAverageGapAddUpToTheResult() throws {
        let estimate = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(age: 38.4)).estimate)
        let comparison = try XCTUnwrap(estimate.compared(with: .liu2018NHANESIV))
        XCTAssertEqual(comparison.shifts.map(\.marker), PhenoAge.inputMarkers)
        XCTAssertEqual(comparison.totalYears, estimate.differenceYears, accuracy: 1e-9)
        // The reference blood age is the formula run on the averages at the same age.
        let averages = PhenoAgeReference.liu2018NHANESIV.values
        let averageReadings = PhenoAge.inputMarkers.map { key in
            reading(key, "\(averages[key]!)", LabUnitConverter.phenoAgeUnit(for: key))
        }
        let average = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(averageReadings, age: 38.4)).estimate)
        XCTAssertEqual(comparison.referenceBloodAgeYears, average.phenotypicAgeYears, accuracy: 1e-9)
        // Each shift is what that one marker at the average would change.
        for shift in comparison.shifts {
            let swapped = PhenoAge.inputMarkers.map { key in
                key == shift.marker ? reading(key, "\(averages[key]!)", LabUnitConverter.phenoAgeUnit(for: key))
                    : siReadings().first { $0.value.subject == .marker(key) }!
            }
            let withAverage = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(swapped, age: 38.4)).estimate)
            XCTAssertEqual(shift.years, estimate.phenotypicAgeYears - withAverage.phenotypicAgeYears, accuracy: 1e-9, shift.marker.rawValue)
        }
        // A person at exactly the averages has no marker shift.
        let atAverage = try XCTUnwrap(average.compared(with: .liu2018NHANESIV))
        XCTAssertTrue(atAverage.shifts.allSatisfy { abs($0.years) < 1e-9 })
        XCTAssertEqual(atAverage.referenceGapYears, average.differenceYears, accuracy: 1e-9)
    }

    func testRaisingOneInputMovesTheResultByItsTermOverTheDivisor() throws {
        let base = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(), coefficients: pyagingSet).estimate)
        let higher = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(replacing(.redCellDistributionWidth, with: reading(.redCellDistributionWidth, "14", "%"))), coefficients: pyagingSet).estimate)
        XCTAssertEqual(higher.phenotypicAgeYears - base.phenotypicAgeYears, 0.3306 / 0.090165, accuracy: 1e-9)
        XCTAssertGreaterThan(higher.mortalityScore, base.mortalityScore)
        XCTAssertTrue((0.0...1.0).contains(base.mortalityScore))
    }

    func testOtherMarkersInTheReportAreIgnored() throws {
        let extra = siReadings() + [reading(.apoB, "78", "mg/dL"), reading(.hba1c, "5.2", "%")]
        let plain = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(), coefficients: pyagingSet).estimate)
        let withExtra = try XCTUnwrap(PhenoAge.calculate(inputs: inputs(extra), coefficients: pyagingSet).estimate)
        XCTAssertEqual(plain.phenotypicAgeYears, withExtra.phenotypicAgeYears)
    }

    // MARK: Chronological age

    func testChronologicalAgeIsCompletedYearsPlusTheFractionSinceTheBirthday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let birth = try XCTUnwrap(calendar.date(from: DateComponents(year: 1980, month: 3, day: 15, hour: 9)))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 20)))
        let age = try XCTUnwrap(PhenoAge.chronologicalAgeYears(dateOfBirth: birth, on: day, timeZone: calendar.timeZone))
        XCTAssertEqual(age, 46 + 181.0 / 365.0, accuracy: 1e-12)
        let birthday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 1)))
        XCTAssertEqual(try XCTUnwrap(PhenoAge.chronologicalAgeYears(dateOfBirth: birth, on: birthday, timeZone: calendar.timeZone)), 46, accuracy: 1e-12)
        XCTAssertNil(PhenoAge.chronologicalAgeYears(dateOfBirth: day, on: birth, timeZone: calendar.timeZone))
    }
}
