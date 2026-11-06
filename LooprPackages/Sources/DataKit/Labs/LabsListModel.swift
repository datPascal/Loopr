import AnalyticsKit
import DesignSystem
import Foundation
import RoutineKit

/// One row of the reports list.
public struct LabReportSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let collectedAt: Date
    public let timeZoneIdentifier: String
    public let labName: String?
    public let fasting: Bool?
    public let source: LabEntrySource
    public let valueCount: Int
    /// Scanned values the person has not checked yet.
    public let needsReviewCount: Int

    public init(report: LabReport, values: [LabValue]) {
        id = report.id
        collectedAt = report.collectedAt
        timeZoneIdentifier = report.timeZoneIdentifier
        labName = report.labName
        fasting = report.fasting
        source = report.source
        valueCount = values.count
        needsReviewCount = values.filter(\.needsReview).count
    }

    public var title: String {
        LabsDisplay.day(collectedAt, timeZoneIdentifier: timeZoneIdentifier)
    }

    /// "Labor Berlin · 8 values · fasting".
    public var subtitle: String {
        var parts: [String] = []
        let lab = labName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        parts.append(lab.isEmpty ? "Lab not named" : lab)
        parts.append(LabsDisplay.valueCount(valueCount))
        switch fasting {
        case true?: parts.append("fasting")
        case false?: parts.append("not fasting")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    /// "2 need a look", or nil when every value is checked.
    public var needsLookText: String? {
        needsReviewCount == 0 ? nil : (needsReviewCount == 1 ? "1 needs a look" : "\(needsReviewCount) need a look")
    }
}

/// What the blood tests list shows: reports newest first, lab clock results, and the tests the protocol asks for.
public struct LabsListSnapshot: Equatable, Sendable {
    public let reports: [LabReportSummary]
    public let clockResults: [LabClockResult]
    public let tests: LabTestsDueSummary
    /// Tests that already have a waiting reminder.
    public let remindedTests: Set<RuleKey>
    /// Every catalog marker with a value, newest value first in each, as the rows of "Your markers" (Data ICP R3: Blood
    /// as an area). Each row carries the marker's whole history, so it opens the marker page.
    public var markers: [LabValueRow]
    /// The markers by body system, once any has a value.
    public var starMap: DataStarMap?

    public init(reports: [LabReportSummary], clockResults: [LabClockResult], tests: LabTestsDueSummary = .empty,
                remindedTests: Set<RuleKey> = [], markers: [LabValueRow] = [], starMap: DataStarMap? = nil) {
        self.reports = reports
        self.clockResults = clockResults
        self.tests = tests
        self.remindedTests = remindedTests
        self.markers = markers
        self.starMap = starMap
    }

    /// The marker rows under their body systems, in catalog order.
    public var markerGroups: [LabValueGroup] {
        LabBodySystem.allCases.compactMap { system in
            let rows = markers.filter { $0.value.subject.markerKey?.marker.bodySystem == system }
            return rows.isEmpty ? nil : LabValueGroup(system: system, rows: rows)
        }
    }

    /// The marker row for one catalog marker, for a route that opens it from elsewhere in Data.
    public func marker(_ key: LabMarkerKey) -> LabValueRow? {
        markers.first { $0.value.subject.markerKey == key }
    }

    /// Groups values under their reports and sorts newest collection first, the later-created first on a tie.
    public static func make(reports: [LabReport], values: [LabValue], clockResults: [LabClockResult],
                            tests: LabTestsDueSummary = .empty, remindedTests: Set<RuleKey> = []) -> LabsListSnapshot {
        let byReport = Dictionary(grouping: values, by: \.reportID)
        let summaries = reports
            .sorted { ($0.collectedAt, $0.createdAt) > ($1.collectedAt, $1.createdAt) }
            .map { LabReportSummary(report: $0, values: byReport[$0.id] ?? []) }
        let clocks = clockResults.sorted { ($0.collectedAt, $0.createdAt) > ($1.collectedAt, $1.createdAt) }
        return LabsListSnapshot(reports: summaries, clockResults: clocks, tests: tests, remindedTests: remindedTests)
    }

    public var valueTotal: Int { reports.reduce(0) { $0 + $1.valueCount } }
    public var needsLookTotal: Int { reports.reduce(0) { $0 + $1.needsReviewCount } }
    public var hasResults: Bool { !reports.isEmpty || !clockResults.isEmpty }

    /// "2 reports · 43 values".
    public var summaryLine: String {
        var parts = [LabsDisplay.reportCount(reports.count), LabsDisplay.valueCount(valueTotal)]
        if !clockResults.isEmpty { parts.append(clockResults.count == 1 ? "1 lab clock" : "\(clockResults.count) lab clocks") }
        return parts.joined(separator: " · ")
    }
}

/// One point of a marker's own history.
public struct LabHistoryPoint: Equatable, Hashable, Sendable {
    public let date: Date
    public let value: Double
}

/// One value row on a report.
public struct LabValueRow: Identifiable, Equatable, Hashable, Sendable {
    public let value: LabValue
    /// The same marker in earlier reports and this one, in the same unit, oldest first. Empty when there is
    /// nothing earlier to compare with.
    public let history: [LabHistoryPoint]
    /// Every stored value of this marker or other name, in any report and any unit, oldest first. The marker page
    /// draws these.
    public let entries: [LabHistoryEntry]
    public var id: UUID { value.id }
    public var name: String { value.subject.displayName }

    public init(value: LabValue, history: [LabHistoryPoint], entries: [LabHistoryEntry] = []) {
        self.value = value
        self.history = history
        self.entries = entries
    }
}

/// Values under one body system, or under "Other tests".
public struct LabValueGroup: Identifiable, Equatable, Sendable {
    public let system: LabBodySystem?
    public let rows: [LabValueRow]
    public var id: String { system?.rawValue ?? "other" }
    public var title: String { system?.displayName ?? "Other tests" }
}

/// A report opened: its header, its values grouped by body system, and whether blood age used it.
public struct LabReportDetail: Equatable, Sendable {
    public let report: LabReport
    public let groups: [LabValueGroup]
    public let usedForBloodAge: Bool
    /// Blood age from this report, when it fed blood age.
    public var bloodAge: DataBloodAgeReading?
    /// Why this report gives no blood age, when it holds some of the nine inputs but blood age could not use it.
    public var bloodAgeNote: String?

    public init(report: LabReport, groups: [LabValueGroup], usedForBloodAge: Bool, bloodAge: DataBloodAgeReading? = nil,
                bloodAgeNote: String? = nil) {
        self.report = report
        self.groups = groups
        self.usedForBloodAge = usedForBloodAge
        self.bloodAge = bloodAge
        self.bloodAgeNote = bloodAgeNote
    }

    /// Every value row, in the order the screen lists them.
    public var rows: [LabValueRow] { groups.flatMap(\.rows) }

    public var valueCount: Int { groups.reduce(0) { $0 + $1.rows.count } }
    public var needsReviewCount: Int { groups.reduce(0) { $0 + $1.rows.filter(\.value.needsReview).count } }

    /// - Parameter history: every stored value of one marker or other name, oldest first.
    public static func make(report: LabReport, values: [LabValue], usedForBloodAge: Bool,
                            history: (LabValueSubject) -> [LabHistoryEntry]) -> LabReportDetail {
        func row(_ value: LabValue) -> LabValueRow { Self.row(value, collectedAt: report.collectedAt, all: history(value.subject)) }
        var groups: [LabValueGroup] = []
        for system in LabBodySystem.allCases {
            let rows = values.filter { $0.subject.markerKey?.marker.bodySystem == system }.map(row)
            if !rows.isEmpty { groups.append(LabValueGroup(system: system, rows: rows)) }
        }
        let others = values.filter { $0.subject.markerKey == nil }.map(row)
        if !others.isEmpty { groups.append(LabValueGroup(system: nil, rows: others)) }
        return LabReportDetail(report: report, groups: groups, usedForBloodAge: usedForBloodAge)
    }

    /// One value with the same marker's earlier values in its unit, up to `collectedAt`, and every stored value.
    static func row(_ value: LabValue, collectedAt: Date, all: [LabHistoryEntry]) -> LabValueRow {
        let unit = normalized(value.unit)
        let points = all
            .filter { normalized($0.value.unit) == unit && $0.report.collectedAt <= collectedAt }
            .map { LabHistoryPoint(date: $0.report.collectedAt, value: NSDecimalNumber(decimal: $0.value.value).doubleValue) }
        return LabValueRow(value: value, history: points.count >= 2 ? points : [], entries: all)
    }

    static func normalized(_ unit: String?) -> String {
        (unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// One marker's page (`labs-marker-screen`): every stored value of it, oldest first, and the points a chart can draw.
/// Only values in the opened value's unit are drawn, so a chart never mixes mg/dL with mmol/L; values in another unit
/// are listed with their own unit. Nothing here judges a value.
public struct LabMarkerHistory: Equatable, Sendable {
    public struct Point: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let date: Date
        /// "12 Sep 2026", on the day in the report's own zone.
        public let dayText: String
        public let value: Double
        public let printed: String
        /// The lab's range bounds for that draw: printed as numbers, or one bound from a range printed as "<90".
        public let low: Double?
        public let high: Double?
        public let flag: String?
        public let isLimit: Bool
        public let isOpened: Bool
    }

    public let name: String
    public let unit: String?
    /// Values in the opened unit, oldest first.
    public let points: [Point]
    /// Every stored value, newest first, for the list under the chart.
    public let entries: [LabHistoryEntry]
    /// Values left off the chart because the lab printed them in another unit.
    public let otherUnitCount: Int

    public static func make(row: LabValueRow, locale: Locale = LooprUnitFormatter.displayLocale) -> LabMarkerHistory {
        let unit = LabReportDetail.normalized(row.value.unit)
        let all = row.entries
        let drawn = all.filter { LabReportDetail.normalized($0.value.unit) == unit }
        let points = drawn.map { entry -> Point in
            let range = entry.value.referenceRange
            // A range printed as text ("<90", "> 40") gives one bound for the band.
            var low = range.low.map { NSDecimalNumber(decimal: $0).doubleValue }
            var high = range.high.map { NSDecimalNumber(decimal: $0).doubleValue }
            if low == nil, high == nil, let text = range.text {
                let split = LabValueComparator.split(text)
                if let sign = split.comparator, let bound = LabEntryNumber.parse(split.rest) {
                    let number = NSDecimalNumber(decimal: bound.value).doubleValue
                    switch sign {
                    case .lessThan, .lessThanOrEqual: high = number
                    case .greaterThan, .greaterThanOrEqual: low = number
                    }
                }
            }
            return Point(id: entry.value.id, date: entry.report.collectedAt,
                         dayText: LabsDisplay.day(entry.report.collectedAt, timeZoneIdentifier: entry.report.timeZoneIdentifier),
                         value: NSDecimalNumber(decimal: entry.value.value).doubleValue,
                         printed: LabsDisplay.valueText(entry.value, locale: locale),
                         low: low, high: high,
                         flag: LabsDisplay.flagText(entry.value), isLimit: entry.value.isLimit,
                         isOpened: entry.value.id == row.value.id)
        }
        return LabMarkerHistory(name: row.name, unit: row.value.unit, points: points, entries: Array(all.reversed()),
                                otherUnitCount: all.count - drawn.count)
    }

    /// What the trend can say. With one draw there is nothing to compare yet, so the page says so instead of
    /// drawing a chart of one dot (ICP R2-LAB-8, R2-LAB-9).
    public var trendLine: String {
        guard let last = points.last else { return "No values in this unit to draw." }
        guard points.count >= 2, let first = points.first else {
            return "First draw, on \(last.dayText). A second draw shows how it moves."
        }
        return "\(points.count) draws, from \(first.dayText) to \(last.dayText)."
    }

    /// How the newest draw moved from the one before, in the unit and digits the lab printed: "Down 13 mg/dL from
    /// 12 Sep 2023 to 14 Nov 2023." Nil with one draw, and when either draw is a limit such as "<0.3", which is not an
    /// exact number and so has no exact change (ICP R3-LAB-7).
    public var changeLine: String? {
        guard points.count >= 2 else { return nil }
        let last = points[points.count - 1], previous = points[points.count - 2]
        guard !last.isLimit, !previous.isLimit else { return nil }
        func digits(_ printed: String) -> Int { printed.split(separator: ".").dropFirst().first?.count ?? 0 }
        let fraction = max(digits(last.printed), digits(previous.printed))
        let delta = last.value - previous.value
        let span = "from \(previous.dayText) to \(last.dayText)."
        let scale = pow(10, Double(fraction))
        guard (abs(delta) * scale).rounded() > 0 else { return "No change \(span)" }
        let amount = LooprUnitFormatter.number(abs(delta), digits: fraction) ?? ""
        return "\(delta > 0 ? "Up" : "Down") \(amount)\(unit.map { " \($0)" } ?? "") \(span)"
    }

    /// What VoiceOver says about the chart.
    public var spokenSummary: String {
        guard let first = points.first, let last = points.last else { return "No values to draw." }
        let unitText = unit.map { " \($0)" } ?? ""
        if points.count == 1 { return "One value, \(last.printed)\(unitText)." }
        var text = "\(points.count) values from \(first.dayText) to \(last.dayText). "
            + "First \(first.printed)\(unitText), latest \(last.printed)\(unitText)."
        if let changeLine { text += " " + changeLine }
        if otherUnitCount > 0 {
            text += otherUnitCount == 1 ? " 1 in another unit is listed below." : " \(otherUnitCount) in another unit are listed below."
        }
        return text
    }
}

/// What a save added, said on Lab mode's saved card: blood age from the draw, or what it still needs, and the
/// markers that are new to the blood tests. Nothing here judges a value.
public struct LabSaveOutcome: Equatable, Sendable {
    public enum BloodAge: Equatable, Sendable {
        /// Blood age came out of this draw.
        case calculated(DataBloodAgeReading)
        /// The draw holds some of the nine inputs; these are still missing.
        case needs([LabMarkerKey])
        /// All nine are here, but blood age is absent for another reason, in its own words.
        case absent(String)
        /// The draw holds none of the nine, so blood age is not part of this save.
        case notInvolved
    }

    public let bloodAge: BloodAge
    /// Markers and other tests saved for the first time.
    public let firstValues: [LabValueSubject]

    /// - Parameters:
    ///   - reportID: the report just saved or added to.
    ///   - reports, values: everything stored, after the save.
    public static func make(reportID: UUID, reports: [LabReport], values: [LabValue], birthYear: Int?,
                            calculate: DataBloodAgeBuilder.Calculate = DataBloodAgeBuilder.published) -> LabSaveOutcome {
        let own = values.filter { $0.reportID == reportID }
        let firstValues = own.map(\.subject).reduce(into: [LabValueSubject]()) { list, subject in
            guard !list.contains(subject) else { return }
            let earlier = values.contains { $0.reportID != reportID && LabSaveOutcome.same($0.subject, subject) }
            if !earlier { list.append(subject) }
        }
        guard let report = reports.first(where: { $0.id == reportID }) else {
            return LabSaveOutcome(bloodAge: .notInvolved, firstValues: firstValues)
        }
        let draw = DataLabDraw(report: report, values: own)
        let missing = draw.missingPhenoAgeMarkers
        if missing.count == PhenoAge.inputMarkers.count {
            return LabSaveOutcome(bloodAge: .notInvolved, firstValues: firstValues)
        }
        if !missing.isEmpty { return LabSaveOutcome(bloodAge: .needs(missing), firstValues: firstValues) }
        let result = LabBloodAgeSource.bloodAge(reports: reports, values: values, birthYear: birthYear, calculate: calculate)
        if let reading = result.reading, reading.report.id == reportID {
            return LabSaveOutcome(bloodAge: .calculated(reading), firstValues: firstValues)
        }
        // A newer complete draw feeds blood age, or this one could not be used: say why in the blood age words.
        let single = DataBloodAgeBuilder.make(draws: [draw], birthYear: birthYear, calculate: calculate)
        if let reading = single.reading { return LabSaveOutcome(bloodAge: .calculated(reading), firstValues: firstValues) }
        return LabSaveOutcome(bloodAge: .absent(single.absence?.sentence ?? DataBloodAgeAbsence.noReport.sentence),
                              firstValues: firstValues)
    }

    private static func same(_ a: LabValueSubject, _ b: LabValueSubject) -> Bool {
        switch (a, b) {
        case let (.marker(x), .marker(y)): return x == y
        case let (.other(x), .other(y)):
            return x.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
                == y.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
        default: return false
        }
    }

    /// "Blood age 34.6, from the 13 Nov draw.", "Blood age needs 2 more from this draw: RDW and MCV.", or nil.
    public var bloodAgeLine: String? {
        switch bloodAge {
        case .calculated(let reading):
            let day = DataText.day(reading.report.collectedAt, timeZoneIdentifier: reading.report.timeZoneIdentifier)
            return "Blood age \(DataText.oneDecimal(reading.estimate.phenotypicAgeYears)), from the \(day) draw."
        case .needs(let keys):
            let names = DataText.list(keys.map(DataBloodAgeMarkers.name))
            let count = keys.count == 1 ? "1 more value" : "\(keys.count) more values"
            return "Blood age needs \(count) from this draw: \(names). If \(keys.count == 1 ? "it is" : "they are") on another page, read that page next."
        case .absent(let sentence):
            return sentence
        case .notInvolved:
            return nil
        }
    }

    /// "New in your blood tests: ApoB, ferritin and 3 more.", or nil when every test had a value before.
    public var firstValuesLine: String? {
        guard !firstValues.isEmpty else { return nil }
        let names = firstValues.map { $0.displayName }
        let shown = names.count > 4 ? Array(names.prefix(3)) + ["\(names.count - 3) more"] : names
        return "New in your blood tests: \(DataText.list(shown))."
    }
}

/// The one blood age rule, shared by the Data root's ruler and the blood tests screens (DEC-12.7). Blood age is PhenoAge
/// from the newest report that holds all nine inputs, computed with the age on the day of that draw. This builds the
/// reports into draws and hands them to `DataBloodAgeBuilder`, so there is one rule for which draws count, which report
/// feeds it, and why blood age is absent when a marker is missing, the birth year is unknown or PhenoAge refuses.
public enum LabBloodAgeSource {
    /// The Data root's blood age for these stored reports and values, or the reason it is absent.
    public static func bloodAge(reports: [LabReport], values: [LabValue], birthYear: Int?,
                                calculate: DataBloodAgeBuilder.Calculate = DataBloodAgeBuilder.published) -> DataBloodAge {
        let byReport = Dictionary(grouping: values, by: \.reportID)
        let draws = reports.map { DataLabDraw(report: $0, values: byReport[$0.id] ?? []) }
        return DataBloodAgeBuilder.make(draws: draws, birthYear: birthYear, calculate: calculate)
    }

    /// The report blood age used, so a detail page can say it fed blood age. Nil when blood age is absent.
    public static func reportID(reports: [LabReport], values: [LabValue], birthYear: Int?,
                                calculate: DataBloodAgeBuilder.Calculate = DataBloodAgeBuilder.published) -> UUID? {
        bloodAge(reports: reports, values: values, birthYear: birthYear, calculate: calculate).reading?.report.id
    }
}

public extension LabStore {
    /// Every report as a list row, newest first.
    func listSnapshot(tests: LabTestsDueSummary = .empty, remindedTests: Set<RuleKey> = [], now: Date = Date(),
                      calendar: Calendar = .current) throws -> LabsListSnapshot {
        let stored = try self.reports()
        var storedValues: [LabValue] = []
        for report in stored { storedValues += try self.values(reportID: report.id) }
        var snapshot = LabsListSnapshot.make(reports: stored, values: storedValues, clockResults: try self.clockResults(),
                                             tests: tests, remindedTests: remindedTests)
        // The newest value of each catalog marker, with its history, for "Your markers".
        let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        var newest: [LabMarkerKey: (value: LabValue, report: LabReport)] = [:]
        for value in storedValues {
            guard let key = value.subject.markerKey, let report = byID[value.reportID] else { continue }
            if let current = newest[key], (current.report.collectedAt, current.report.createdAt) >= (report.collectedAt, report.createdAt) { continue }
            newest[key] = (value, report)
        }
        snapshot.markers = try LabMarkerCatalog.markers.compactMap { marker in
            guard let latest = newest[marker.key] else { return nil }
            return LabReportDetail.row(latest.value, collectedAt: latest.report.collectedAt,
                                       all: try self.history(for: .marker(marker.key)))
        }
        let draws = stored.map { report in DataLabDraw(report: report, values: storedValues.filter { $0.reportID == report.id }) }
        let map = DataStarMapRule.make(DataLabSeries.series(draws), now: now, calendar: calendar)
        snapshot.starMap = map.measuredCount > 0 ? map : nil
        return snapshot
    }

    /// A report with its values grouped by body system. Nil when the report is gone.
    func detail(reportID: UUID, birthYear: Int?) throws -> LabReportDetail? {
        guard let report = try self.report(id: reportID) else { return nil }
        let stored = try self.reports()
        var storedValues: [LabValue] = []
        for each in stored { storedValues += try self.values(reportID: each.id) }
        let own = storedValues.filter { $0.reportID == reportID }
        var histories: [LabValueSubject: [LabHistoryEntry]] = [:]
        for subject in Set(own.map(\.subject)) { histories[subject] = try self.history(for: subject) }
        let blood = LabBloodAgeSource.bloodAge(reports: stored, values: storedValues, birthYear: birthYear)
        let fed = blood.reading?.report.id == reportID
        var detail = LabReportDetail.make(report: report, values: own, usedForBloodAge: fed) { histories[$0] ?? [] }
        if fed { detail.bloodAge = blood.reading }
        detail.bloodAgeNote = fed ? nil : Self.bloodAgeNote(report: report, values: own, birthYear: birthYear)
        return detail
    }

    /// Why a report that holds some of the nine inputs gives no blood age, said without blaming the lab. Nil when it
    /// holds none of them.
    static func bloodAgeNote(report: LabReport, values: [LabValue], birthYear: Int?) -> String? {
        let draw = DataLabDraw(report: report, values: values)
        let missing = draw.missingPhenoAgeMarkers
        guard missing.count < PhenoAge.inputMarkers.count else { return nil }
        if !missing.isEmpty {
            let names = DataText.list(missing.map(DataBloodAgeMarkers.name))
            let pronoun = missing.count == 1 ? "it is" : "they are"
            return "Blood age needs \(names) from this draw too. If \(pronoun) on another page of this report, scan that page or type \(missing.count == 1 ? "it" : "them") in."
        }
        return DataBloodAgeBuilder.make(draws: [draw], birthYear: birthYear).absence?.sentence
    }
}
