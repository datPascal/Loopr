import Foundation

/// One recognised line of text with its box, in the shape the camera's text recognition gives. The box is
/// normalised to the page (0 to 1) with its origin at the bottom left, the way Vision reports it, so the app can map
/// an observation straight in: its top candidate's string and confidence, and `boundingBox`.
public struct LabTextLine: Sendable, Equatable {
    public let text: String
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double
    /// Recognition confidence from 0 to 1.
    public let confidence: Double

    public init(text: String, minX: Double, minY: Double, width: Double, height: Double, confidence: Double) {
        self.text = text
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
        self.confidence = confidence
    }

    var midY: Double { minY + height / 2 }
}

/// Why Loopr wants a person to look at one scanned value. Each is a fact about the page, never about the result.
public enum LabReviewReason: String, Sendable, Hashable, CaseIterable {
    /// The number had a separator that could be a decimal or a thousands mark ("1,234").
    case separatorUnclear
    /// A letter O was read as a zero.
    case letterReadAsZero
    /// The text recognition was unsure of the row.
    case faintRow
    /// The range beside the value could not be read cleanly.
    case rangeUnclear
    /// No unit was printed beside the value.
    case unitMissing
    /// A unit was printed, but not one this marker is reported in, or not one Loopr knows.
    case unitUnknown
}

/// A report read from camera text, ready to review. Nothing here is a judgement: values keep the lab's own unit,
/// range and flag as printed, and a row the parser could not read is counted, never filled in.
public struct LabReportDraft: Sendable, Equatable {
    public let report: LabReport
    public let values: [LabValue]
    /// The printed text of each row that looked like a result but whose value could not be read.
    public let skippedRows: [String]
    /// False when no collection date was printed; `report.collectedAt` is then the capture time.
    public let collectedDateFound: Bool
    /// The label the date sat under as printed, such as "Probenentnahme".
    public let collectedDateLabel: String?
    /// Why each value that needs a look needs it, by value id.
    public let reviewReasons: [UUID: [LabReviewReason]]
    /// The name as printed on the page, by value id, so a screen can show it beside the catalog name.
    public let printedNames: [UUID: String]

    public init(report: LabReport, values: [LabValue], skippedRows: [String], collectedDateFound: Bool,
                collectedDateLabel: String?, reviewReasons: [UUID: [LabReviewReason]] = [:], printedNames: [UUID: String] = [:]) {
        self.report = report
        self.values = values
        self.skippedRows = skippedRows
        self.collectedDateFound = collectedDateFound
        self.collectedDateLabel = collectedDateLabel
        self.reviewReasons = reviewReasons
        self.printedNames = printedNames
    }

    public var valuesRead: Int { values.count }
    public var valuesNeedingReview: Int { values.filter(\.needsReview).count }
    public var rowsSkipped: Int { skippedRows.count }
}

/// Reads English and German lab report text into a draft report and values.
///
/// Lines are grouped into rows by vertical position, then each row is read left to right as a name, a value, a
/// unit, a flag and the lab's reference range. A row can hold two tests side by side. The parser never converts
/// units, never fills in a missing unit, never keeps a unit that the marker is not reported in, and never judges a
/// value. A name that is not in `LabMarkerAliases` becomes an "other" value under its printed text.
public enum LabReportParser {
    public struct Options: Sendable, Equatable {
        /// A row whose lowest recognition confidence is below this needs a look.
        public var lowConfidenceThreshold: Double
        /// Two lines share a row when their middles are within this fraction of the smaller line height.
        public var rowTolerance: Double

        public init(lowConfidenceThreshold: Double = 0.6, rowTolerance: Double = 0.5) {
            self.lowConfidenceThreshold = lowConfidenceThreshold
            self.rowTolerance = rowTolerance
        }
    }

    /// - Parameters:
    ///   - capturedAt: When the photo was taken. It stands in for the collection date only when none is printed.
    ///   - timeZone: The zone a printed date and time are read in.
    public static func parse(
        lines: [LabTextLine],
        capturedAt: Date,
        timeZone: TimeZone,
        reportID: UUID = UUID(),
        makeValueID: () -> UUID = { UUID() },
        options: Options = Options()
    ) -> LabReportDraft {
        let rows = mergeWrappedNames(buildRows(lines, options: options))
        let style = LabDecimalStyle.detect(in: rows.map(\.text))
        let reader = LabRowReader(style: style, options: options)

        var values: [LabValue] = []
        var reasons: [UUID: [LabReviewReason]] = [:]
        var names: [UUID: String] = [:]
        var skipped: [String] = []
        var firstResultRow = rows.count
        var nonResultRows = Set<Int>()
        for (index, row) in rows.enumerated() {
            var produced = false
            var position = 0
            while position < row.tokens.count {
                let result = reader.read(row.tokens, from: position)
                switch result.kind {
                case .value(let parsed):
                    let id = makeValueID()
                    values.append(LabValue(
                        id: id, reportID: reportID, subject: parsed.subject, assay: parsed.assay, value: parsed.number,
                        printedValue: parsed.printedValue, comparator: parsed.comparator, unit: parsed.unit,
                        referenceRange: parsed.range, flagText: parsed.flag,
                        source: .scan, scanConfidence: parsed.confidence, needsReview: parsed.needsReview))
                    if !parsed.reasons.isEmpty { reasons[id] = parsed.reasons }
                    names[id] = parsed.printedName
                    produced = true
                case .skipped(let text):
                    skipped.append(text)
                    produced = true
                case .ignored:
                    break
                }
                position = max(result.next, position + 1)
            }
            if produced { firstResultRow = min(firstResultRow, index) } else { nonResultRows.insert(index) }
        }

        let header = LabReportHeaderReader.read(
            rows: rows.map(\.text), firstResultRow: firstResultRow, nonResultRows: nonResultRows,
            capturedAt: capturedAt, timeZone: timeZone)
        let report = LabReport(
            id: reportID, collectedAt: header.collectedAt ?? capturedAt, timeZoneIdentifier: timeZone.identifier,
            labName: header.labName, fasting: header.fasting, source: .scan, createdAt: capturedAt, note: nil)
        return LabReportDraft(
            report: report, values: values, skippedRows: skipped,
            collectedDateFound: header.collectedAt != nil, collectedDateLabel: header.dateLabel,
            reviewReasons: reasons, printedNames: names)
    }

    // MARK: Rows

    struct Row {
        var tokens: [LabToken]
        var midY: Double
        var height: Double
        var text: String { tokens.map(\.text).joined(separator: " ") }
    }

    private static func buildRows(_ lines: [LabTextLine], options: Options) -> [Row] {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.midY, -$0.minX) > ($1.midY, -$1.minX) }
        var groups: [[LabTextLine]] = []
        for line in usable {
            if let first = groups.last?.first,
               abs(first.midY - line.midY) <= min(first.height, line.height) * options.rowTolerance {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.map { group in
            let cells = group.sorted { $0.minX < $1.minX }
            return Row(tokens: cells.flatMap { LabToken.tokenise($0.text, confidence: $0.confidence) },
                       midY: group.map(\.midY).reduce(0, +) / Double(group.count),
                       height: group.map(\.height).max() ?? 0)
        }
    }

    /// A name that wraps over two lines ("Alkalische" above "Phosphatase 64 U/L"), or a name alone on a line above its
    /// value, joins into one row when the lines are neighbours.
    private static func mergeWrappedNames(_ rows: [Row]) -> [Row] {
        var merged: [Row] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            if index + 1 < rows.count {
                let next = rows[index + 1]
                let close = row.midY - next.midY <= max(row.height, next.height) * 2.5
                let texts = row.tokens.map(\.text)
                if close, !texts.isEmpty, texts.count <= 4, !texts.contains(where: LabRowReader.isNumberShape) {
                    let normalised = LabNameMatcher.normalise(texts.joined())
                    var join = false
                    if LabMarkerAliases.table[normalised] != nil {
                        join = next.tokens.first.map { LabRowReader.isNumberShape($0.text) } ?? false
                    } else if LabMarkerAliases.wrappedNamePrefixes.contains(normalised) {
                        let combined = (row.tokens + next.tokens).map(\.text)
                        if let match = LabNameMatcher.match(combined, from: 0), match.length > texts.count { join = true }
                    }
                    if join {
                        merged.append(Row(tokens: row.tokens + next.tokens, midY: next.midY, height: max(row.height, next.height)))
                        index += 2
                        continue
                    }
                }
            }
            merged.append(row)
            index += 1
        }
        return merged
    }
}
