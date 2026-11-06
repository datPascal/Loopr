import AnalyticsKit
@testable import DataKit
import DesignSystem
import DomainKit
import Foundation
import JournalKit
import RoutineKit
import Testing

/// The repository root, read from this file's own location: Tests/DataKitTests/Methods/ is three folders under
/// LooprPackages, which sits in the root.
private let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private func lines(of path: String) throws -> [String] {
    let url = repositoryRoot.appendingPathComponent(path)
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
}

/// LV-08b step 3: a method page for every number (DEC-12.20).
struct MethodCatalogTests {
    @Test func everyMethodHasOneEntry() {
        let ids = MethodCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate method ids")
        #expect(Set(ids) == Set(MethodID.allCases))
        for id in MethodID.allCases { #expect(MethodCatalog.entry(id).id == id) }
    }

    /// The families checklist 21 LV-08b.3 names.
    @Test func theNamedFamiliesAreCovered() {
        let required: [MethodID] = [
            .recovery, .sleepStages, .sleepRegularity, .hrv, .restingHeartRate, .respiration, .skinTemperature, .strain,
            .trainingLoad, .stress, .overnightCheck, .heartRateRecovery, .cardioAge, .vo2MaxGauge, .phenoAge, .looprAge,
            .proteinPerKilogram, .fibre, .ultraProcessedShare, .plantsPerWeek, .weeklyDose, .capacityTests,
            .protocolKeptShare, .experimentResult, .patternStrength, .labUnitConversion
        ]
        let present = Set(MethodCatalog.entries.map(\.id))
        for id in required { #expect(present.contains(id), "\(id.rawValue) has no method page") }
    }

    @Test func eachMetricKeyBelongsToOnePage() {
        let keys = MethodCatalog.entries.flatMap(\.metricKeys)
        #expect(Set(keys).count == keys.count, "a metric key is claimed by two pages")
        for key in keys { #expect(MethodCatalog.entry(forMetricKey: key) != nil) }
        #expect(MethodCatalog.entry(forMetricKey: "recovery")?.id == .recovery)
        #expect(MethodCatalog.entry(forMetricKey: "rmssd")?.id == .hrv)
        #expect(MethodCatalog.entry(forMetricKey: "not-a-metric") == nil)
    }

    @Test(arguments: MethodCatalog.entries)
    func everyPageSaysWhatTheMethodNeeds(_ entry: MethodEntry) {
        #expect(!entry.summary.isEmpty)
        #expect(!entry.rule.isEmpty, "\(entry.id.rawValue) has no rule written out")
        #expect(!entry.inputs.isEmpty)
        #expect(!entry.sources.isEmpty)
        #expect(!entry.limits.isEmpty)
    }

    @Test(arguments: MethodCatalog.entries)
    func everySourcePathExistsAndItsAnchorSitsInsideTheLines(_ entry: MethodEntry) throws {
        for source in entry.sources {
            let text = try lines(of: source.path)
            #expect(source.lines.lowerBound >= 1 && source.lines.upperBound <= text.count,
                    "\(source.path) has \(text.count) lines, the catalog cites \(source.lines)")
            let range = text[max(source.lines.lowerBound - 1, 0)..<min(source.lines.upperBound, text.count)]
            let anchor = source.anchor.trimmingCharacters(in: .whitespaces)
            #expect(range.contains { $0.trimmingCharacters(in: .whitespaces).contains(anchor) },
                    "\(entry.id.rawValue): \(source.symbol) moved out of \(source.path) \(source.lines)")
        }
    }

    @Test(arguments: MethodCatalog.entries)
    func everyListedTestSuiteExists(_ entry: MethodEntry) throws {
        for suite in entry.testSuites {
            let text = try lines(of: suite.path).joined(separator: "\n")
            let pattern = "(class|struct|enum|actor)\\s+\(suite.name)\\b"
            #expect(text.range(of: pattern, options: .regularExpression) != nil, "\(suite.name) is not declared in \(suite.path)")
        }
    }

    @Test(arguments: MethodCatalog.entries)
    func versionFilesDeclareTheirConstant(_ entry: MethodEntry) throws {
        guard let version = entry.version else { return }
        let text = try lines(of: version.file).joined(separator: "\n")
        let member = try #require(version.symbol.split(separator: ".").last)
        #expect(text.contains(member), "\(version.file) does not declare \(version.symbol)")
    }

    @Test func versionsEqualTheCodeConstants() {
        let expected: [MethodID: String?] = [
            .recovery: WellnessAlgorithm.readinessVersion,
            .sleepStages: SleepAlgorithm.version, .sleepNeed: SleepAlgorithm.version, .sleepRegularity: SleepAlgorithm.version,
            .hrv: AnalyticsAlgorithmVersion.hrv,
            .restingHeartRate: AnalyticsAlgorithmVersion.nocturnal, .maxHeartRate: AnalyticsAlgorithmVersion.nocturnal,
            .respiration: AnalyticsAlgorithmVersion.respiration,
            .skinTemperature: VitalsAlgorithmVersion.skinTemperature,
            .oxygen: nil,
            .strain: ActivityAlgorithm.version, .steps: ActivityAlgorithm.version,
            .trainingLoad: TrainingLoad.algorithmVersion,
            .stress: WellnessAlgorithm.version,
            .hourlyStress: HourlyStress.version,
            .overnightCheck: OvernightVitalsCheck.algorithmVersion,
            .heartRateRecovery: TimedHeartRateRecovery.algorithmVersion,
            .activeEnergy: WorkoutAlgorithm.version,
            .cardioAge: "FRIEND reference \(FriendReferenceCurve.version1.referenceVersion)",
            .vo2MaxGauge: nil,
            .phenoAge: PhenoAge.version,
            .looprAge: nil,
            .proteinPerKilogram: nil, .fibre: nil, .ultraProcessedShare: nil, .plantsPerWeek: nil,
            .weeklyDose: nil, .capacityTests: nil, .protocolKeptShare: nil,
            .experimentResult: ExperimentPolicy.standard.version,
            .patternStrength: PatternPolicy.default.algorithmVersion,
            .labUnitConversion: nil, .labRanges: nil
        ]
        #expect(Set(expected.keys) == Set(MethodID.allCases))
        for entry in MethodCatalog.entries {
            #expect(entry.version?.value == expected[entry.id] ?? nil, "\(entry.id.rawValue) version")
        }
    }

    /// ICP R1-OPT-23: the list shows a plain line for every method, Blood oxygen included, and no version id.
    @Test func everyListLineIsPlainWords() {
        for entry in MethodCatalog.entries {
            #expect(!entry.listLine.isEmpty, "\(entry.id.rawValue)")
            if let version = entry.version?.value, version.contains(".") {
                #expect(!entry.listLine.contains(version), "\(entry.id.rawValue) shows \(version)")
            }
            #expect(!entry.listLine.contains("loopr."), "\(entry.id.rawValue): \(entry.listLine)")
        }
        #expect(MethodCatalog.entry(.phenoAge).listLine == "PhenoAge · From 9 blood values and your age.")
    }

    @Test func phenoAgeFormulaUsesThePublishedConstants() throws {
        let c = PhenoAgeCoefficients.published
        let formula = try #require(MethodCatalog.entry(.phenoAge).formula)
        let numbers = Set(formula.lines.flatMap(\.tokens).filter { $0.kind == .number }.compactMap { Double($0.text) })
        for constant in [abs(c.intercept), c.ageCoefficient, c.gamma, c.horizonMonths, c.offsetYears, c.scale, c.divisor] {
            #expect(numbers.contains(constant), "the formula does not show \(constant)")
        }
        #expect(formula.lines.count == 3)
        // The marker weights are listed in the caption, each as the coefficient the engine uses.
        for key in PhenoAge.inputMarkers {
            let weight = try #require(c.markerCoefficients[key])
            #expect(formula.caption.contains(MethodCatalog.signed(weight)), "\(key.rawValue) weight missing from the caption")
        }
        #expect(formula.lines[2].plainText.hasPrefix("PhenoAge = 141.50225 + ln(−0.00553 · ln(1 − M)) / 0.090165"))
        #expect(MethodCatalog.entry(.phenoAge).inputs.count == PhenoAge.inputMarkers.count + 1)
    }

    @Test func phenoAgeWaterfallSumsToTheGapAgainstRealAge() throws {
        let estimate = try #require(PhenoAge.calculate(inputs: Self.phenoAgeInputs).estimate)
        let waterfall = try #require(MethodWaterfall.phenoAge(estimate))
        // The average person at your age, then the nine markers.
        #expect(waterfall.model.steps.count == 10)
        #expect(waterfall.model.steps.first?.id == "reference")
        #expect(abs(waterfall.model.sum - estimate.differenceYears) < 1e-9)
        #expect(abs(waterfall.model.start - estimate.chronologicalAgeYears) < 1e-12)
        #expect(abs(waterfall.model.end - estimate.phenotypicAgeYears) < 1e-9)
        let total = try #require(waterfall.model.bars.last)
        #expect(total.isTotal && abs(total.to - estimate.phenotypicAgeYears) < 1e-9)
        let value = MethodPageValue.phenoAge(estimate)
        #expect(value.value == estimate.phenotypicAgeYears && value.fractionDigits == 1)
    }

    /// R1-LAB-1: a bar is a marker's distance from a cited average, never the raw formula term (RDW once read +47.7).
    @Test func phenoAgeWaterfallBarsAreMeasuredAgainstTheNHANESAverage() throws {
        let estimate = try #require(PhenoAge.calculate(inputs: Self.phenoAgeInputs).estimate)
        let waterfall = try #require(MethodWaterfall.phenoAge(estimate))
        let reference = PhenoAgeReference.liu2018NHANESIV
        let c = PhenoAgeCoefficients.published
        for step in waterfall.model.steps.dropFirst() {
            let key = try #require(LabMarkerKey(rawValue: step.id))
            let input = try #require(estimate.inputs.first { $0.marker == key })
            let average = try #require(reference.values[key])
            let x = key == .crp ? log(input.value) : input.value
            let r = key == .crp ? log(average) : average
            #expect(abs(step.value - (try #require(c.markerCoefficients[key])) * (x - r) / c.divisor) < 1e-9, "\(key.rawValue)")
            // A marker at RDW 13 against an average of 12.7 moves blood age by about a year, not by tens of years.
            #expect(abs(step.value) < 5, "\(key.rawValue) \(step.value)")
            #expect(step.label.contains("average"))
        }
        // RDW 13 % against 12.7 %: 0.3306 * 0.3 / 0.090165, about 1.1 years.
        let rdw = try #require(waterfall.model.steps.first { $0.id == LabMarkerKey.redCellDistributionWidth.rawValue })
        #expect(abs(rdw.value - 0.3306 * 0.3 / 0.090165) < 1e-6)
        #expect(waterfall.note.contains("NHANES IV") && waterfall.note.contains("not targets"))
        #expect(!waterfall.note.contains("\u{2014}"))
    }

    @Test func recoveryWaterfallSumsToTheDistanceFromFifty() throws {
        let split = WellnessAnalytics.recoveryDecomposition([
            RecoverySignalReading(signal: .hrv, value: 58, baseline: [44, 48, 51, 53, 50, 47, 55, 49, 52, 46]),
            RecoverySignalReading(signal: .restingHeartRate, value: 51, baseline: [55, 54, 56, 53, 55, 54, 57, 55, 54, 56]),
            RecoverySignalReading(signal: .respiratoryRate, value: 14.6,
                                  baseline: [14.6, 14.8, 14.7, 14.9, 14.5, 14.7, 14.8, 14.6, 14.7, 14.9])
        ])
        let score = try #require(split.score)
        let waterfall = try #require(MethodWaterfall.recovery(split))
        #expect(waterfall.model.start == 50)
        #expect(abs(waterfall.model.end - score) < 1e-9)
        #expect(waterfall.model.steps.count == 3)
    }

    @Test func recoveryWithoutAScoreHasNoWaterfall() {
        let split = WellnessAnalytics.recoveryDecomposition([
            RecoverySignalReading(signal: .hrv, value: 58, baseline: [50]),
            RecoverySignalReading(signal: .restingHeartRate, value: 51, baseline: [55])
        ])
        #expect(MethodWaterfall.recovery(split) == nil)
        #expect(MethodPageValue.recovery(split) == nil)
    }

    @Test func gitHubLinksOpenTheFileAtItsLines() throws {
        let source = try #require(MethodCatalog.entry(.phenoAge).sources.first)
        #expect(source.gitHubURL.absoluteString
            == "https://github.com/datPascal/Loopr/blob/main/LooprPackages/Sources/AnalyticsKit/Age/PhenoAge.swift#L191-L219")
        for entry in MethodCatalog.entries {
            for source in entry.sources { #expect(source.gitHubURL.host == "github.com") }
        }
    }

    @Test func pagesThatCouldReadAsAVerdictCarryTheMedicalLine() {
        for id in [MethodID.phenoAge, .recovery, .cardioAge, .looprAge, .overnightCheck, .skinTemperature, .labUnitConversion, .labRanges] {
            #expect(MethodCatalog.entry(id).showsMedicalLine, "\(id.rawValue)")
        }
        #expect(MethodCatalog.medicalLine == "Loopr is not a medical device. If a number worries you, talk to a doctor.")
    }

    /// Plain wellness copy: no em dashes, no exclamation marks, nothing called a diagnosis except "not a diagnosis".
    @Test(arguments: MethodCatalog.entries)
    func copyStaysPlain(_ entry: MethodEntry) {
        let strings = [entry.title, entry.summary] + entry.rule + entry.limits + entry.inputs.map(\.name)
            + entry.references.map(\.use) + [entry.formula?.caption].compactMap { $0 }
        for text in strings {
            #expect(!text.contains("—"), "em dash in \(entry.id.rawValue): \(text)")
            #expect(!text.contains("!"), "exclamation mark in \(entry.id.rawValue): \(text)")
            let lowered = text.lowercased().replacingOccurrences(of: "not a diagnosis", with: "")
            for banned in ["diagnos", "abnormal", "dangerous", "medical-grade", "clinically accurate", "delve", "crucial", "leverage"] {
                #expect(!lowered.contains(banned), "\(banned) in \(entry.id.rawValue): \(text)")
            }
        }
        let first = entry.title.prefix(1)
        #expect(first == first.uppercased(), "titles start in capitals")
        let rest = entry.title.split(separator: " ").dropFirst()
        #expect(!rest.contains { word in
            guard let letter = word.first, letter.isUppercase else { return false }
            return word.count > 1 && word.dropFirst().allSatisfy(\.isLowercase) && !["Loopr", "FRIEND"].contains(String(word))
        }, "title case in \(entry.title)")
    }

    static var phenoAgeInputs: PhenoAgeInputs {
        let reportID = UUID()
        let drawn = Date(timeIntervalSince1970: 1_789_193_700)
        let rows: [(LabMarkerKey, String, String)] = [
            (.albumin, "46", "g/L"), (.creatinine, "70", "µmol/L"), (.glucose, "5.0", "mmol/L"), (.crp, "0.5", "mg/dL"),
            (.lymphocytePercent, "30", "%"), (.meanCellVolume, "90", "fL"), (.redCellDistributionWidth, "13", "%"),
            (.alkalinePhosphatase, "70", "U/L"), (.whiteBloodCellCount, "7", "10^3/µL")
        ]
        return PhenoAgeInputs(readings: rows.map { key, value, unit in
            PhenoAgeReading(value: LabValue(reportID: reportID, subject: .marker(key),
                                            value: Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!,
                                            unit: unit, source: .typed),
                            collectedAt: drawn, timeZoneIdentifier: "Europe/Berlin")
        }, chronologicalAgeYears: 50)
    }
}
