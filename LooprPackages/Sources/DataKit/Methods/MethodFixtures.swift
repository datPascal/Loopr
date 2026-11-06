#if DEBUG
import AnalyticsKit
import Foundation

/// DEBUG-only values for method page captures and UI tests. Never reachable in a release build.
public enum MethodFixtures {
    /// The pyaging test row (`tests/predict/test_crp_transform.py` at commit c15cf283, CRP set to 0.5 mg/dL), the
    /// first vector in `AnalyticsKitTests/Fixtures/PhenoAge/vectors.json`. Age 50.
    public static var phenoAgeInputs: PhenoAgeInputs {
        let reportID = UUID(uuidString: "00000000-0000-0000-0000-0000000008B3")!
        let drawn = Date(timeIntervalSince1970: 1_789_193_700)
        let rows: [(LabMarkerKey, String, String)] = [
            (.albumin, "46", "g/L"), (.creatinine, "70", "µmol/L"), (.glucose, "5.0", "mmol/L"), (.crp, "0.5", "mg/dL"),
            (.lymphocytePercent, "30", "%"), (.meanCellVolume, "90", "fL"), (.redCellDistributionWidth, "13", "%"),
            (.alkalinePhosphatase, "70", "U/L"), (.whiteBloodCellCount, "7", "10^3/µL")
        ]
        let readings = rows.map { key, value, unit in
            PhenoAgeReading(
                value: LabValue(reportID: reportID, subject: .marker(key),
                                value: Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!, unit: unit, source: .typed),
                collectedAt: drawn, timeZoneIdentifier: "Europe/Berlin")
        }
        return PhenoAgeInputs(readings: readings, chronologicalAgeYears: 50)
    }

    public static var phenoAge: PhenoAgeEstimate? { PhenoAge.calculate(inputs: phenoAgeInputs).estimate }

    /// Ten earlier nights and a rested night, as in `RecoveryDecompositionTests`.
    public static var recovery: RecoveryDecomposition {
        WellnessAnalytics.recoveryDecomposition([
            RecoverySignalReading(signal: .hrv, value: 58, baseline: [44, 48, 51, 53, 50, 47, 55, 49, 52, 46]),
            RecoverySignalReading(signal: .restingHeartRate, value: 51, baseline: [55, 54, 56, 53, 55, 54, 57, 55, 54, 56]),
            RecoverySignalReading(signal: .respiratoryRate, value: 14.6,
                                  baseline: [14.6, 14.8, 14.7, 14.9, 14.5, 14.7, 14.8, 14.6, 14.7, 14.9])
        ])
    }

    /// The value a DEBUG launch shows for a method, when the method has one.
    public static func value(for id: MethodID) -> MethodPageValue? {
        switch id {
        case .phenoAge: phenoAge.map { MethodPageValue.phenoAge($0, labName: "Fixture lab") }
        case .recovery: MethodPageValue.recovery(recovery)
        default: nil
        }
    }
}
#endif
