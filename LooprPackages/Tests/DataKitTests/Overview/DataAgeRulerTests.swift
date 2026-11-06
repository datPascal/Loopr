import AnalyticsKit
import DesignSystem
@testable import DataKit
import Foundation
import TrainKit
import XCTest

/// The age ruler: its range and ticks, where the pins sit, and why each pin is absent.
final class DataAgeRulerTests: XCTestCase {
    private typealias S = DataOverviewTestSupport

    // MARK: Range and ticks

    func testTheRangeFitsThePinsWithFourYearsEitherSideAtLeastSixteenWideOnEvenYears() {
        // 34 to 38.4 plus 4 either side is 30 to 42.4; padded to 16 wide and rounded out to even years.
        XCTAssertEqual(DataAgeRulerScale.fitted(to: [34.6, 38.4, 34]), DataAgeRulerScale(lower: 28, upper: 46))
        // Wide pins only get the margin.
        XCTAssertEqual(DataAgeRulerScale.fitted(to: [30, 70]), DataAgeRulerScale(lower: 26, upper: 74))
        // One pin is centred in the minimum span.
        XCTAssertEqual(DataAgeRulerScale.fitted(to: [41]), DataAgeRulerScale(lower: 32, upper: 50))
        // The ruler never runs below zero; it shifts up instead.
        XCTAssertEqual(DataAgeRulerScale.fitted(to: [1]), DataAgeRulerScale(lower: 0, upper: 18))
        // Without pins the empty ruler keeps its shape.
        XCTAssertEqual(DataAgeRulerScale.fitted(to: []), .empty)
        XCTAssertEqual(DataAgeRulerScale.fitted(to: [.nan]), .empty)
    }

    func testANarrowRulerHasQuarterYearYearAndDecadeTicksWithLabelsThatNeverBunch() {
        let ticks = DataAgeRulerScale(lower: 28, upper: 46).ticks
        XCTAssertEqual(ticks.count, 73)
        XCTAssertEqual(ticks.filter { $0.kind == .decade }.map(\.value), [30, 40])
        XCTAssertEqual(ticks.filter { $0.kind == .year }.count, 17)
        XCTAssertEqual(ticks.filter { $0.kind == .quarter }.count, 54)
        // Wider than 16 years, labels sit every five (ICP R1-OPT-12: "24" and "26" bunched).
        XCTAssertEqual(ticks.compactMap(\.label), ["30", "35", "40", "45"])
        XCTAssertNil(ticks.first { $0.value == 29 }?.label)
        // At the minimum span of 16, every two years.
        XCTAssertEqual(DataAgeRulerScale(lower: 32, upper: 48).ticks.compactMap(\.label),
                       ["32", "34", "36", "38", "40", "42", "44", "46", "48"])
    }

    func testAWideRulerDropsTheQuartersAndLabelsEveryFiveYears() {
        let ticks = DataAgeRulerScale.empty.ticks
        XCTAssertEqual(ticks.count, 41)
        XCTAssertFalse(ticks.contains { $0.kind == .quarter })
        XCTAssertEqual(ticks.compactMap(\.label), ["20", "25", "30", "35", "40", "45", "50", "55", "60"])
        XCTAssertEqual(ticks.filter { $0.kind == .decade }.map(\.value), [20, 30, 40, 50, 60])
    }

    func testTheScrubSnapsToTenthsAcrossTheWholeRuler() {
        let scale = DataAgeRulerScale(lower: 28, upper: 46)
        XCTAssertEqual(scale.detent.count, 181)
        XCTAssertEqual(scale.detent.value(at: scale.detent.index(for: scale.years(atFraction: 0.5))), 37, accuracy: 1e-9)
        XCTAssertEqual(scale.years(atFraction: 2), 46)
        XCTAssertEqual(scale.fraction(for: 10), 0)
    }

    // MARK: Pins

    func testEachPinSitsAtItsShareOfTheRulerOnItsOwnLane() {
        let scale = DataAgeRulerScale(lower: 28, upper: 46)
        let pins = [DataAgePin(kind: .cardio, years: 34, valueText: "34"),
                    DataAgePin(kind: .real, years: 38.4, valueText: "38.4"),
                    DataAgePin(kind: .blood, years: 34.6, valueText: "34.6")]
        let placed = DataAgePinPlacement.place(pins, on: scale)
        XCTAssertEqual(placed.map(\.kind), [.blood, .real, .cardio])
        XCTAssertEqual(placed.map(\.lane), [0, 1, 2])
        XCTAssertEqual(placed[0].fraction, 6.6 / 18, accuracy: 1e-9)
        XCTAssertEqual(placed[1].fraction, 10.4 / 18, accuracy: 1e-9)
        XCTAssertEqual(placed[2].fraction, 6 / 18, accuracy: 1e-9)
        XCTAssertTrue(placed[0].labelTrailsPin && placed[1].labelTrailsPin)
        // Cardio sits just left of blood's stem, so its label turns left rather than cross it.
        XCTAssertFalse(placed[2].labelTrailsPin)
        XCTAssertTrue(placed[2].showsMethod)
        XCTAssertEqual(pins[2].label, "blood 34.6 · PhenoAge")
        XCTAssertEqual(pins[0].shortLabel, "cardio 34")
    }

    /// ICP R1-LAB-21: blood 28.3, real 38.4, cardio 32. "cardio 32 · VO₂max" ran through the real-age stem.
    func testNoLabelCrossesTheStemOfAPinAboveIt() {
        let pins = [DataAgePin(kind: .blood, years: 28.3, valueText: "28.3"),
                    DataAgePin(kind: .real, years: 38.4, valueText: "38.4"),
                    DataAgePin(kind: .cardio, years: 32, valueText: "32")]
        let scale = DataAgeRulerScale.fitted(to: pins.map(\.years))
        for width in [320.0, 354, 402] {
            let placed = DataAgePinPlacement.place(pins, on: scale, width: width)
            for placement in placed {
                let pin = pins.first { $0.kind == placement.kind }!
                let reach = DataAgePinPlacement.reach(placement.showsMethod ? pin.label : pin.shortLabel, width: width)
                let span = placement.labelTrailsPin ? placement.fraction...(placement.fraction + reach)
                    : (placement.fraction - reach)...placement.fraction
                for above in placed where above.lane < placement.lane {
                    XCTAssertFalse(span.contains(above.fraction) && above.fraction != placement.fraction,
                                   "\(placement.kind) label crosses \(above.kind) at width \(width)")
                }
            }
        }
    }

    func testAPinPastSixtyPercentLabelsToItsLeftAndLanesCloseUpWithoutBloodAge() {
        let scale = DataAgeRulerScale(lower: 28, upper: 46)
        let placed = DataAgePinPlacement.place([DataAgePin(kind: .real, years: 44, valueText: "44"),
                                                DataAgePin(kind: .cardio, years: 30, valueText: "30")], on: scale)
        XCTAssertEqual(placed.map(\.kind), [.real, .cardio])
        XCTAssertEqual(placed.map(\.lane), [0, 1])
        XCTAssertFalse(placed[0].labelTrailsPin)
        XCTAssertTrue(placed[1].labelTrailsPin)
    }

    func testTheRulerFitsItsRangeToThePinsItDraws() {
        let now = S.drawn.addingTimeInterval(43 * 86_400)
        let ruler = DataAgeRuler.make(birthYear: 1988, draws: [S.completeDraw()], vo2Max: .readings(S.vo2Readings(now: now)),
                                      referenceGroup: .male, now: now, calendar: S.calendar)
        XCTAssertEqual(ruler.pins.map(\.kind), [.blood, .real, .cardio])
        XCTAssertEqual(ruler.scale, DataAgeRulerScale.fitted(to: ruler.pins.map(\.years)))
        for placement in ruler.placements {
            let pin = ruler.pins.first { $0.kind == placement.kind }!
            XCTAssertEqual(placement.fraction, ruler.scale.fraction(for: pin.years), accuracy: 1e-12)
        }
    }

    // MARK: Real age

    func testRealAgeCountsFromFirstJulyOfTheBirthYearAndIsAbsentWithoutOne() {
        let years = DataRealAge.years(birthYear: 1988, on: S.date(2026, 10, 25), timeZone: S.berlin)
        // 1 July to 25 October is 116 of the 365 days to the next 1 July.
        XCTAssertEqual(years!, 38 + 116.0 / 365, accuracy: 1e-9)
        XCTAssertNil(DataRealAge.years(birthYear: nil, on: S.date(2026, 10, 25), timeZone: S.berlin))
        XCTAssertNil(DataRealAge.years(birthYear: 2027, on: S.date(2026, 10, 25), timeZone: S.berlin))

        let ruler = DataAgeRuler.make(birthYear: nil, draws: [], vo2Max: .readings([]), referenceGroup: .male,
                                      now: S.date(2026, 10, 25), calendar: S.calendar)
        XCTAssertEqual(ruler.state(.real), .absent(DataAgeRuler.realAgeAbsence))
    }

    // MARK: Blood age

    func testPhenoAgeIsCalledWithTheAgeOnTheDayOfTheDrawNotToday() throws {
        let recorder = PhenoAgeCallRecorder()
        let today = S.drawn.addingTimeInterval(400 * 86_400)
        let ruler = DataAgeRuler.make(birthYear: 1988, draws: [S.completeDraw()], vo2Max: .readings([]), referenceGroup: .male,
                                      now: today, calendar: S.calendar, calculate: recorder.calculate)
        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(recorder.calls.count, 1)
        // 1 July 1988 to 12 September 2026: 38 years and 73 of 365 days.
        XCTAssertEqual(call.chronologicalAgeYears, 38 + 73.0 / 365, accuracy: 1e-9)
        let birth = try XCTUnwrap(DataRealAge.approximateDateOfBirth(birthYear: 1988, timeZone: S.berlin))
        XCTAssertEqual(call.chronologicalAgeYears,
                       try XCTUnwrap(PhenoAge.chronologicalAgeYears(dateOfBirth: birth, on: S.drawn, timeZone: S.berlin)))
        XCTAssertNotEqual(call.chronologicalAgeYears, try XCTUnwrap(ruler.realYears), accuracy: 0.5)
        XCTAssertEqual(call.readings.count, 9)
        XCTAssertEqual(ruler.blood.reading?.ageAtDraw ?? 0, call.chronologicalAgeYears, accuracy: 1e-12)
        XCTAssertEqual(ruler.blood.reading?.estimate.chronologicalAgeYears ?? 0, call.chronologicalAgeYears, accuracy: 1e-12)
    }

    func testBloodAgeComesFromTheNewestReportThatHoldsAllNineMarkers() throws {
        let complete = S.completeDraw(at: S.date(2026, 3, 2))
        let newer = S.report(at: S.date(2026, 9, 12))
        let partial = DataLabDraw(report: newer, values: [S.value(newer, .apoB, "78", "mg/dL"), S.value(newer, .albumin, "46", "g/L")])
        let blood = DataBloodAgeBuilder.make(draws: [partial, complete], birthYear: 1988)
        let reading = try XCTUnwrap(blood.reading)
        XCTAssertEqual(reading.report, complete.report)
        XCTAssertEqual(reading.estimate.inputs.count, 9)
        XCTAssertEqual(reading.estimate.version, PhenoAge.version)
    }

    func testEachBloodAgeAbsenceHasItsReason() {
        XCTAssertEqual(DataBloodAgeBuilder.make(draws: nil, birthYear: 1988).absence, .unreadable)
        XCTAssertEqual(DataBloodAgeBuilder.make(draws: [], birthYear: 1988).absence, .noReport)

        let report = S.report(at: S.drawn)
        let missing = DataLabDraw(report: report, values: Array(S.phenoAgeValues(report).dropFirst(2)))
        XCTAssertEqual(DataBloodAgeBuilder.make(draws: [missing], birthYear: 1988).absence,
                       .missingMarkers([.albumin, .creatinine], report: report))
        // ICP R1-LAB-7: the sentence names what the report has and what is still needed, in a lab's own words.
        let sentence = DataBloodAgeAbsence.missingMarkers([.albumin, .creatinine], report: report).sentence
        XCTAssertTrue(sentence.contains("albumin and creatinine"))
        XCTAssertTrue(sentence.contains("has glucose, C-reactive protein (CRP), lymphocyte percent, mean cell volume (MCV), red cell distribution width (RDW), alkaline phosphatase and white blood cell count"))
        let none = DataBloodAgeAbsence.missingMarkers(PhenoAge.inputMarkers, report: report).sentence
        XCTAssertTrue(none.contains("none of the 9 values"))
        // With no report at all, the count and the panels that hold the nine; the names wait on the method page
        // (UX R2-NEW-07).
        let noReport = DataBloodAgeAbsence.noReport.sentence
        XCTAssertTrue(noReport.contains("9 values"))
        XCTAssertTrue(noReport.contains("full blood count"))
        XCTAssertFalse(noReport.contains("PhenoAge"))

        let complete = S.completeDraw()
        XCTAssertEqual(DataBloodAgeBuilder.make(draws: [complete], birthYear: nil).absence, .noBirthYear)

        // Albumin of 500 g/L is outside the 10 to 70 g/L pyaging registers, so nothing is computed.
        let outOfRange = S.completeDraw(albumin: "500")
        XCTAssertEqual(DataBloodAgeBuilder.make(draws: [outOfRange], birthYear: 1988).absence,
                       .notCalculated(.outsideReferenceRange(.albumin), report: outOfRange.report))

        // A birth year after the draw gives no age at the draw.
        XCTAssertEqual(DataBloodAgeBuilder.make(draws: [complete], birthYear: 2027).absence,
                       .notCalculated(.invalidChronologicalAge, report: complete.report))

        for absence: DataBloodAgeAbsence in [.unreadable, .noReport, .noBirthYear,
                                             .notCalculated(.outOfRangeInput(.crp), report: report)] {
            XCTAssertFalse(absence.sentence.isEmpty)
            XCTAssertFalse(absence.sentence.contains("—"))
        }
    }

    // MARK: Cardio Age

    func testCardioAgeComesFromTheCalculatorWithItsVO2MaxSource() throws {
        let now = S.date(2026, 10, 25)
        let cardio = DataCardioAgeBuilder.make(source: .readings(S.vo2Readings(now: now)), birthYear: 1988,
                                               referenceGroup: .male, now: now, calendar: S.calendar)
        let reading = try XCTUnwrap(cardio.reading)
        XCTAssertEqual(reading.median.value, 44.1, accuracy: 1e-9)
        // Between the 25 (48.0) and 35 (42.4) male medians.
        XCTAssertEqual(reading.years, 25 + (48.0 - 44.1) / (48.0 - 42.4) * 10, accuracy: 1e-9)
        XCTAssertEqual(reading.valueText, "32")
        XCTAssertEqual(reading.result.source, .healthKit)
        XCTAssertEqual(reading.median.sourceLabels, ["Apple Watch"])
    }

    func testEachCardioAgeAbsenceHasItsReason() {
        let now = S.date(2026, 10, 25)
        func make(_ source: DataVO2MaxSource, birthYear: Int? = 1988, group: FriendReferenceGroup? = .male) -> DataCardioAgeAbsence? {
            DataCardioAgeBuilder.make(source: source, birthYear: birthYear, referenceGroup: group, now: now, calendar: S.calendar).absence
        }
        let readings = DataVO2MaxSource.readings(S.vo2Readings(now: now))
        XCTAssertEqual(make(.switchedOff), .switchedOff)
        XCTAssertEqual(make(.unavailable), .unavailable)
        XCTAssertEqual(make(readings, birthYear: nil), .noBirthYear)
        XCTAssertEqual(make(.readings([]), birthYear: nil), .noBirthYearNorReadings)
        XCTAssertEqual(make(readings, group: nil), .noReferenceCurve)
        // ICP R3-LAB-3: with the birth year in but no readings and no sex, the row still names the readings.
        XCTAssertEqual(make(.readings([]), group: nil), .noReferenceCurveNorReadings)
        XCTAssertTrue(DataCardioAgeAbsence.noReferenceCurveNorReadings.sentence.contains("3 VO₂max readings"))
        XCTAssertTrue(DataCardioAgeAbsence.noReferenceCurveNorReadings.sentence.contains("sex in Profile"))
        XCTAssertEqual(make(.readings(Array(S.vo2Readings(now: now).prefix(2)))), .notEnoughSamples)
        XCTAssertEqual(make(.readings([])), .notEnoughSamples)
        // FRIEND version 1 runs from age 25 to 75; at 80 the population is not supported.
        XCTAssertEqual(make(readings, birthYear: 1946), .unsupportedAge)
        for absence in [DataCardioAgeAbsence.switchedOff, .unavailable, .noBirthYear, .noBirthYearNorReadings, .noReferenceCurve, .noReferenceCurveNorReadings, .unsupportedAge, .notEnoughSamples] {
            XCTAssertFalse(absence.sentence.isEmpty)
        }
    }

    // MARK: Hero

    func testTheHeroIsBloodAgeThenCardioAgeThenADesignedEmptyState() {
        let now = S.drawn.addingTimeInterval(43 * 86_400)
        let both = DataAgeRuler.make(birthYear: 1988, draws: [S.completeDraw()], vo2Max: .readings(S.vo2Readings(now: now)),
                                     referenceGroup: .male, now: now, calendar: S.calendar)
        XCTAssertEqual(both.hero.kind, .blood)
        XCTAssertTrue(both.hero.eyebrow.hasPrefix("Blood age · PhenoAge estimate · "))
        XCTAssertEqual(both.hero.value ?? 0, both.blood.reading?.estimate.phenotypicAgeYears ?? -1, accuracy: 1e-12)
        // One decimal and its unit, as the pin prints it, with the age at the draw spelled out (the real-age pin is
        // today's age). The hero said "29" over a pin reading "blood 29.2" (ICP R3-LAB-1).
        XCTAssertEqual(both.hero.fractionDigits, 1)
        XCTAssertEqual(both.hero.unit, "years")
        let atDraw = DataText.oneDecimal(both.blood.reading?.ageAtDraw ?? 0)
        XCTAssertTrue(both.hero.sentence.contains("your age on the day of the draw, \(atDraw)."))
        XCTAssertTrue(both.hero.sentence.contains(DataAgeRuler.birthYearCaveat))
        XCTAssertNil(both.hero.change)

        let cardioOnly = DataAgeRuler.make(birthYear: 1988, draws: [], vo2Max: .readings(S.vo2Readings(now: now)),
                                           referenceGroup: .male, now: now, calendar: S.calendar)
        XCTAssertEqual(cardioOnly.hero.kind, .cardio)
        XCTAssertEqual(cardioOnly.hero.provenance, .appleHealth(source: "Apple Watch"))
        XCTAssertNil(cardioOnly.state(.blood).pin)

        let none = DataAgeRuler.make(birthYear: nil, draws: [], vo2Max: .readings([]), referenceGroup: nil,
                                     now: now, calendar: S.calendar)
        XCTAssertEqual(none.hero.kind, .empty)
        XCTAssertNil(none.hero.value)
        XCTAssertEqual(none.hero.sentence, DataAgeRuler.emptySentence)
        XCTAssertFalse(none.hero.sentence.contains("pin"))
        XCTAssertEqual(none.hero.needs.count, 3)
        XCTAssertTrue(none.pins.isEmpty)
        XCTAssertEqual(none.scale, .empty)
        XCTAssertEqual(none.hero.needs[0], DataBloodAgeAbsence.noReport.sentence)
        XCTAssertEqual(none.hero.needs[1], DataAgeRuler.realAgeAbsence)
        XCTAssertEqual(none.hero.needs[2], DataCardioAgeAbsence.noBirthYearNorReadings.sentence)
    }

    /// ICP R3-LAB-1, R3-NEW-2, R3-UPG-3: the headline said "No age yet" over a ruler that plotted "real 42.4 · birth
    /// year". The hero and the ruler come from one set of pin states, so a ruler with a pin never has an empty hero, and
    /// the hero's number is always one of the ruler's pins.
    func testTheHeadlineAndTheRulerTellOneStory() throws {
        let now = S.drawn.addingTimeInterval(43 * 86_400)
        let realOnly = DataAgeRuler.make(birthYear: 1982, draws: [], vo2Max: .readings([]), referenceGroup: nil,
                                         now: now, calendar: S.calendar)
        XCTAssertEqual(realOnly.pins.map(\.kind), [.real])
        XCTAssertEqual(realOnly.hero.kind, .real)
        let real = try XCTUnwrap(realOnly.state(.real).pin)
        XCTAssertEqual(realOnly.hero.value ?? 0, real.years, accuracy: 1e-12)
        XCTAssertEqual(realOnly.hero.fractionDigits, 1)
        XCTAssertEqual(realOnly.hero.unit, "years")
        XCTAssertTrue(realOnly.hero.spokenLabel.contains("\(real.valueText) years"))
        XCTAssertFalse(realOnly.hero.sentence.contains("No age"))
        // The Cardio Age row still says it needs readings once the birth year is in (ICP R3-LAB-3).
        XCTAssertEqual(realOnly.state(.cardio).absenceSentence, DataCardioAgeAbsence.noReferenceCurveNorReadings.sentence)

        let readings = DataVO2MaxSource.readings(S.vo2Readings(now: now))
        for birthYear in [nil, 1982] as [Int?] {
            for draws in [[], [S.completeDraw()]] as [[DataLabDraw]] {
                for vo2 in [DataVO2MaxSource.readings([]), readings] {
                    for group in [nil, FriendReferenceGroup.male] {
                        let ruler = DataAgeRuler.make(birthYear: birthYear, draws: draws, vo2Max: vo2, referenceGroup: group,
                                                      now: now, calendar: S.calendar)
                        XCTAssertEqual(ruler.hero.kind == .empty, ruler.pins.isEmpty)
                        if let value = ruler.hero.value {
                            XCTAssertTrue(ruler.pins.contains { abs($0.years - value) < 1e-9 }, "hero \(value) is not a pin")
                        } else {
                            XCTAssertTrue(ruler.pins.isEmpty)
                        }
                    }
                }
            }
        }
    }

    /// ICP R1-OPT-12: with an earlier complete draw the hero says how blood age moved since then.
    func testTheHeroShowsTheChangeSinceThePreviousDraw() throws {
        let now = S.drawn.addingTimeInterval(43 * 86_400)
        let earlier = S.completeDraw(at: S.drawn.addingTimeInterval(-120 * 86_400), albumin: "42")
        let latest = S.completeDraw()
        let ruler = DataAgeRuler.make(birthYear: 1988, draws: [earlier, latest], vo2Max: .readings([]), referenceGroup: .male,
                                      now: now, calendar: S.calendar)
        let reading = try XCTUnwrap(ruler.blood.reading)
        let previous = try XCTUnwrap(reading.previous)
        XCTAssertEqual(previous.report, earlier.report)
        let alone = try XCTUnwrap(DataBloodAgeBuilder.make(draws: [earlier], birthYear: 1988).reading)
        XCTAssertEqual(previous.years, alone.estimate.phenotypicAgeYears, accuracy: 1e-12)
        let change = try XCTUnwrap(ruler.hero.change)
        let delta = reading.estimate.phenotypicAgeYears - previous.years
        XCTAssertEqual(change, "Since \(DataText.day(earlier.report.collectedAt, timeZoneIdentifier: "Europe/Berlin")): \(LooprSignedNumber.text(delta, fractionDigits: 1)) years")
        // Two complete reports on the same day are one draw, not a change.
        let sameDay = S.completeDraw(at: S.drawn.addingTimeInterval(-3_600))
        XCTAssertNil(DataBloodAgeBuilder.make(draws: [sameDay, latest], birthYear: 1988).reading?.previous)
    }
}
