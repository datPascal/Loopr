import Foundation

/// What the top of a report says: the collection date, the lab, whether the person fasted. Anything not printed
/// stays nil; nothing is inferred.
struct LabReportHeader: Sendable, Equatable {
    var collectedAt: Date?
    /// The label the date sat under, as printed ("Probenentnahme").
    var dateLabel: String?
    var labName: String?
    var fasting: Bool?
}

enum LabReportHeaderReader {
    /// Rows are the text of one printed row each, top to bottom. `firstResultRow` is the index of the first row that
    /// held a result; the lab name is looked for above it.
    static func read(rows: [String], firstResultRow: Int, nonResultRows: Set<Int>, capturedAt: Date, timeZone: TimeZone) -> LabReportHeader {
        var header = LabReportHeader()
        var bestPriority = 0
        for row in rows {
            guard let priority = datePriority(of: row), priority > bestPriority,
                  let date = firstDate(in: row, capturedAt: capturedAt, timeZone: timeZone) else { continue }
            header.collectedAt = date
            header.dateLabel = dateLabel(in: row)
            bestPriority = priority
        }
        header.labName = labName(rows: rows, before: firstResultRow)
        header.fasting = fasting(rows: rows, indices: nonResultRows)
        return header
    }

    // MARK: Date

    /// 3 for the collection itself, 2 for receipt, 1 for a bare "Datum" or "Date". Birth dates and report dates are
    /// never the collection date, so they return nil.
    private static func datePriority(of row: String) -> Int? {
        let folded = LabNameMatcher.normalise(row)
        for never in ["geburtsdatum", "geboren", "birth", "befunddatum", "reported", "reportdate", "ausgabedatum", "gedruckt",
                      "printed", "freigabe", "validiert", "validated", "approved", "verified", "berichtsdatum"] where folded.contains(never) {
            return nil
        }
        for collected in ["probenentnahme", "entnahme", "abnahme", "probenahme", "collected", "collection", "drawn", "sampled", "entnommen"]
        where folded.contains(collected) { return 3 }
        for received in ["eingangsdatum", "probeneingang", "auftragseingang", "eingang", "received"] where folded.contains(received) { return 2 }
        for generic in ["datum", "date"] where folded.contains(generic) { return 1 }
        return nil
    }

    private static func dateLabel(in row: String) -> String? {
        let labels = ["Probenentnahme", "Blutentnahme", "Entnahmedatum", "Entnahme", "Abnahme", "Probenahme", "Collected", "Collection date",
                      "Date collected", "Specimen collected", "Eingangsdatum", "Probeneingang", "Received", "Datum", "Date"]
        let folded = LabNameMatcher.normalise(row)
        return labels.first { folded.contains(LabNameMatcher.normalise($0)) }
    }

    private static let monthNames: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "maer": 3, "apr": 4, "mai": 5, "may": 5, "jun": 6, "jul": 7, "aug": 8,
        "sep": 9, "okt": 10, "oct": 10, "nov": 11, "dez": 12, "dec": 12
    ]

    private struct Match {
        let year: Int, month: Int, day: Int
        let end: String.Index
    }

    private static func firstDate(in row: String, capturedAt: Date, timeZone: TimeZone) -> Date? {
        let text = row.lowercased().replacingOccurrences(of: "ä", with: "a").replacingOccurrences(of: "ß", with: "ss")
        guard let match = dateMatch(in: text) else { return nil }
        var hour = 12, minute = 0
        let tail = String(text[match.end...])
        if let time = try? NSRegularExpression(pattern: #"^\s*(?:um|at|,|-|uhr)?\s*(\d{1,2}):(\d{2})"#),
           let found = time.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
           let h = Range(found.range(at: 1), in: tail).flatMap({ Int(tail[$0]) }),
           let m = Range(found.range(at: 2), in: tail).flatMap({ Int(tail[$0]) }), h < 24, m < 60 {
            hour = h
            minute = m
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: match.year, month: match.month, day: match.day, hour: hour, minute: minute)
        guard match.year >= 1990, let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == match.year, back.month == match.month, back.day == match.day else { return nil }
        // A date after the capture day is a misread, not a collection date.
        guard date <= capturedAt.addingTimeInterval(86_400) else { return nil }
        return date
    }

    private static func dateMatch(in text: String) -> Match? {
        func int(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            Range(match.range(at: group), in: text).flatMap { Int(text[$0]) }
        }
        func year(_ value: Int) -> Int { value < 100 ? 2000 + value : value }
        let full = NSRange(text.startIndex..., in: text)
        func end(_ match: NSTextCheckingResult) -> String.Index { Range(match.range, in: text)?.upperBound ?? text.endIndex }

        // 2026-09-12
        if let regex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#),
           let m = regex.firstMatch(in: text, range: full), let y = int(m, 1), let mo = int(m, 2), let d = int(m, 3) {
            return Match(year: y, month: mo, day: d, end: end(m))
        }
        // 12.09.2026 or 12.09.26, always day first
        if let regex = try? NSRegularExpression(pattern: #"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})(?![\d.])"#),
           let m = regex.firstMatch(in: text, range: full), let d = int(m, 1), let mo = int(m, 2), let y = int(m, 3) {
            return Match(year: year(y), month: mo, day: d, end: end(m))
        }
        // 12 sep 2026, 12. september 2026, 12 sept. 2026
        if let regex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\.?\s*(jan|feb|mar|maer|apr|mai|may|jun|jul|aug|sep|okt|oct|nov|dez|dec)[a-z]*\.?,?\s*(\d{4})(?!\d)"#),
           let m = regex.firstMatch(in: text, range: full), let d = int(m, 1), let y = int(m, 3),
           let name = Range(m.range(at: 2), in: text).map({ String(text[$0]) }), let mo = monthNames[name] {
            return Match(year: y, month: mo, day: d, end: end(m))
        }
        // september 12, 2026
        if let regex = try? NSRegularExpression(pattern: #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})(?!\d)"#),
           let m = regex.firstMatch(in: text, range: full), let d = int(m, 2), let y = int(m, 3),
           let name = Range(m.range(at: 1), in: text).map({ String(text[$0]) }), let mo = monthNames[name] {
            return Match(year: y, month: mo, day: d, end: end(m))
        }
        // 12/09/2026 or 09/12/2026: only when one part is above 12 can the order be told apart.
        if let regex = try? NSRegularExpression(pattern: #"(?<![\d/])(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})(?![\d/])"#),
           let m = regex.firstMatch(in: text, range: full), let a = int(m, 1), let b = int(m, 2), let y = int(m, 3) {
            if a > 12, b <= 12 { return Match(year: year(y), month: b, day: a, end: end(m)) }
            if b > 12, a <= 12 { return Match(year: year(y), month: a, day: b, end: end(m)) }
        }
        return nil
    }

    // MARK: Lab name

    /// Report titles that contain "labor" without naming a lab.
    private static let titles: Set<String> = [
        "laborbefund", "laborwerte", "laborergebnis", "laborergebnisse", "laborbericht", "labor", "laboratory", "laboratoryreport",
        "labreport", "labresults", "laboratoryresults", "laborwerteubersicht", "befund", "laborauftrag", "laboratorytestresults"
    ]

    private static func labName(rows: [String], before firstResultRow: Int) -> String? {
        let limit = min(firstResultRow, rows.count)
        let labelPattern = try? NSRegularExpression(pattern: #"^\s*(?:labor|laboratory|lab)\s*:\s*(.+)$"#, options: .caseInsensitive)
        for row in rows[0..<limit] {
            let range = NSRange(row.startIndex..., in: row)
            if let m = labelPattern?.firstMatch(in: row, range: range), let name = Range(m.range(at: 1), in: row) {
                let value = row[name].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        for row in rows[0..<limit] {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            let folded = LabNameMatcher.normalise(trimmed)
            guard !trimmed.isEmpty, !titles.contains(folded) else { continue }
            let words = trimmed.lowercased()
            let names = ["labor", "laborat", "diagnostik", "diagnostic", "mvz"]
            let hasName = names.contains { words.contains($0) } || words.range(of: #"\blabs?\b"#, options: .regularExpression) != nil
            let isFieldRow = words.contains(":") || words.contains("labor-nr") || words.contains("laborleiter") || words.contains("labnr")
            if hasName, !isFieldRow, trimmed.contains(where: { $0.isLetter }) { return trimmed }
        }
        return nil
    }

    // MARK: Fasting

    private static func fasting(rows: [String], indices: Set<Int>) -> Bool? {
        var answer: Bool?
        for index in indices.sorted() where index < rows.count {
            let folded = LabNameMatcher.normalise(rows[index])
            for no in ["nichtnuchtern", "nonfasting", "notfasting", "nonfasted", "unfasted", "nuchternnein", "fastingno"] where folded.contains(no) {
                return false
            }
            if folded.contains("nuchtern") || folded.contains("fasting") || folded.contains("fasted") { answer = true }
        }
        return answer
    }
}
