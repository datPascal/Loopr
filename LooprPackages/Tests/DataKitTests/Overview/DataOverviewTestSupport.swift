import AnalyticsKit
import DataKit
import Foundation
import TrainKit

/// Shared fakes for the Data overview tests: a Berlin calendar, a blood draw on 12 September 2026 and helpers.
enum DataOverviewTestSupport {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar
    }

    /// 12 September 2026, 08:15 in Berlin.
    static let drawn = Date(timeIntervalSince1970: 1_789_193_700)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func decimal(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    static func report(at date: Date, lab: String? = "Riverside Lab", id: UUID = UUID()) -> LabReport {
        LabReport(id: id, collectedAt: date, timeZoneIdentifier: "Europe/Berlin", labName: lab, fasting: true, source: .typed,
                  createdAt: date.addingTimeInterval(3_600))
    }

    static func value(_ report: LabReport, _ key: LabMarkerKey, _ text: String, _ unit: String,
                      range: LabReferenceRange = .none) -> LabValue {
        LabValue(reportID: report.id, subject: .marker(key), value: decimal(text), unit: unit, referenceRange: range, source: .typed)
    }

    /// The nine PhenoAge inputs in SI units, all inside pyaging's registered ranges.
    static func phenoAgeValues(_ report: LabReport, albumin: String = "46") -> [LabValue] {
        [value(report, .albumin, albumin, "g/L"), value(report, .creatinine, "84", "\u{00B5}mol/L"),
         value(report, .glucose, "4.9", "mmol/L"), value(report, .crp, "0.6", "mg/L"),
         value(report, .lymphocytePercent, "31", "%"), value(report, .meanCellVolume, "89", "fL"),
         value(report, .redCellDistributionWidth, "12.6", "%"), value(report, .alkalinePhosphatase, "62", "U/L"),
         value(report, .whiteBloodCellCount, "5.4", "10^9/L")]
    }

    static func completeDraw(at date: Date = drawn, albumin: String = "46", lab: String? = "Riverside Lab") -> DataLabDraw {
        let report = report(at: date, lab: lab)
        return DataLabDraw(report: report, values: phenoAgeValues(report, albumin: albumin))
    }

    static func vo2(_ value: Double, daysBefore now: Date, _ days: Double) -> VO2MaxReading {
        VO2MaxReading(value: value, date: now.addingTimeInterval(-days * 86_400), sourceLabel: "Apple Watch", isConsumerEstimate: true)
    }

    /// Three readings on distinct days 32 days apart: a valid 42-day median of 44.1.
    static func vo2Readings(now: Date) -> [VO2MaxReading] {
        [vo2(43.8, daysBefore: now, 35), vo2(44.1, daysBefore: now, 20), vo2(44.4, daysBefore: now, 3)]
    }

    static func series(_ id: String, system: DataBodySystem = .cardiovascular, cadence: DataSeriesCadence = .daily,
                       higherIsBetter: Bool? = true, points: [DataPoint]) -> DataSeries {
        DataSeries(id: id, title: id, system: system, source: cadence == .lab ? .lab : .band, cadence: cadence,
                   higherIsBetter: higherIsBetter, points: points,
                   valueText: { String(format: "%.1f", $0) }, deltaText: { String(format: "%+.1f", $0) })
    }

    /// One value a day from `fromDaysAgo` to `toDaysAgo` days before `now`, from `value(daysAgo)`.
    static func daily(now: Date, from fromDaysAgo: Int, to toDaysAgo: Int, value: (Int) -> Double) -> [DataPoint] {
        stride(from: fromDaysAgo, through: toDaysAgo, by: -1).map { daysAgo in
            DataPoint(date: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!.addingTimeInterval(12 * 3_600),
                      value: value(daysAgo))
        }
    }
}

/// Records what the PhenoAge engine was called with.
final class PhenoAgeCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PhenoAgeInputs] = []

    var calls: [PhenoAgeInputs] { lock.withLock { recorded } }

    var calculate: DataBloodAgeBuilder.Calculate {
        { [self] inputs in
            lock.withLock { recorded.append(inputs) }
            return PhenoAge.calculate(inputs: inputs)
        }
    }
}
