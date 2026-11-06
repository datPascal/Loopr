import AnalyticsKit
import Combine
import DataKit
import DesignSystem
import FoodKit
import Foundation
import UIKit

/// Lab mode in the Food camera (DEC-12.6). A photo of a blood test report is read on this iPhone with Vision,
/// parsed by `LabReportParser`, checked by the person and saved to the lab store with source scan.
///
/// There is no provider, no photo consent and no network on this path. Values keep the lab's own unit, range and
/// flag. A value with no unit stays without one. Nothing here judges a value or computes blood age.
@MainActor
final class FoodLabModel: ObservableObject {
    enum Stage: Equatable { case live, reading, review, saving, saved, problem }
    enum Problem: Equatable {
        /// The page held no value that could be read. `skippedRows` looked like results but could not be read.
        case empty(skippedRows: Int)
        /// Text recognition failed.
        case unreadable
    }
    /// The report a session saved, with what it holds so far.
    struct PageSession: Equatable {
        let reportID: UUID
        /// The collection day, `yyyy-MM-dd` in the report's zone.
        let day: String
        let collectedAt: Date
        var pages: Int
        var values: [LabValue]
    }

    enum EditOutcome: Equatable {
        case confirmed
        /// The text is not a plain number.
        case invalidNumber
        /// A marker needs the unit printed on the report before it can be confirmed.
        case unitNeeded
        /// The unit is not one this marker is reported in.
        case unitNotListed
    }

    @Published private(set) var stage: Stage = .live {
        didSet { if (oldValue == .live) != (stage == .live) { onActiveChange?(stage != .live) } }
    }
    /// Called when the read starts showing over the camera, and when it goes back to the viewfinder.
    var onActiveChange: (@MainActor (Bool) -> Void)?
    @Published private(set) var draft: LabReportDraft?
    /// The values as read, with the person's corrections.
    @Published private(set) var values: [LabValue] = []
    @Published private(set) var report: FoodLensReport?
    /// Where each value's row sits on the page, from the top (0) to the bottom (1). Nil when no line matched.
    @Published private(set) var rows: [Double?] = []
    /// When the blood was drawn: as printed, or the photo's date when the page prints none.
    @Published var collectedAt = Date(timeIntervalSince1970: 0)
    @Published private(set) var problem: Problem?
    /// The value whose edit row is open.
    @Published var editing: Int?
    @Published private(set) var saveError: String?
    @Published private(set) var savedCount = 0
    /// The report just saved, so the confirmation can open it in the blood tests.
    @Published private(set) var savedReportID: UUID?
    /// True when the save added this page to a report already saved, instead of starting a new one.
    @Published private(set) var savedIntoExisting = false
    /// How many values the report holds after the save.
    @Published private(set) var savedReportTotal = 0
    /// Values on this page that the report already held, left out of the save.
    @Published private(set) var savedRepeats = 0
    /// What the save changed: blood age from the draw, or what it still needs, and the tests that are new.
    @Published private(set) var outcome: LabSaveOutcome?
    /// The report this camera session saved last. The next page read in the session adds to it when it was drawn on the
    /// same day, so the two pages of one report make one report and blood age can use both.
    @Published private(set) var session: PageSession?
    /// Pages of an imported PDF still to read, in order.
    @Published private(set) var queuedPages: [FoodPhoto] = []
    /// Which page of an imported PDF is on screen, and how many it has. Nil for a photo.
    @Published private(set) var pdfPage: (index: Int, count: Int)?
    /// Values whose dots have reached their chip.
    @Published private(set) var landed: Set<Int> = []
    /// True once the sweep and the chip flight have played for this read. They play once.
    @Published private(set) var flightFinished = false
    private(set) var capturedAt: Date?
    /// True when the page printed no date and took the date of the page saved before it in this session.
    @Published private(set) var dateFromSession = false
    let timeZone: TimeZone
    private let reader: FoodLabReader
    private let minimumReading: Duration
    private var generation = UUID()

    /// - Parameter minimumReading: how long "Reading" stays on screen at least, so a fast read is still seen.
    init(timeZone: TimeZone, reader: FoodLabReader = .vision, minimumReading: Duration = .seconds(1.1)) {
        self.timeZone = timeZone; self.reader = reader; self.minimumReading = minimumReading
    }

    // MARK: Reading

    /// Holds the pages of an imported PDF. The first is read now by the caller; the rest wait for "Read page 2".
    func queue(pages: [FoodPhoto]) {
        queuedPages = Array(pages.dropFirst())
        pdfPage = pages.count > 1 ? (1, pages.count) : nil
    }

    /// Reads the next page of an imported PDF. Nil when none is left.
    @discardableResult
    func readNextPage() -> Task<Void, Never>? {
        guard !queuedPages.isEmpty else { return nil }
        let next = queuedPages.removeFirst()
        if let page = pdfPage { pdfPage = (page.index + 1, page.count) }
        return Task { await read(next) }
    }

    /// Lifts the page out of the photo, reads it and parses it.
    func read(_ photo: FoodPhoto) async {
        let id = UUID(); generation = id
        clear()
        capturedAt = photo.reference.capturedAt
        stage = .reading
        let started = ContinuousClock.now
        let lifted = await reader.lift(photo.bytes)
        guard generation == id else { return }
        report = lifted
        do {
            let lines = try await reader.recognize(lifted)
            try await Task.sleep(until: started.advanced(by: minimumReading), clock: .continuous)
            guard generation == id else { return }
            accept(lines, capturedAt: photo.reference.capturedAt)
        } catch {
            guard generation == id, !(error is CancellationError), !Task.isCancelled else { return }
            problem = .unreadable; stage = .problem
        }
    }

    /// Parses lines read from a page captured at `capturedAt`.
    func accept(_ lines: [LabTextLine], capturedAt: Date) {
        let draft = LabReportParser.parse(lines: lines, capturedAt: capturedAt, timeZone: timeZone)
        self.capturedAt = capturedAt
        self.draft = draft
        values = draft.values
        rows = Self.rowPositions(for: draft.values, lines: lines)
        collectedAt = draft.report.collectedAt
        // A later page of a report rarely prints the date again: it takes the date of the page saved before it.
        dateFromSession = false
        if !draft.collectedDateFound, let session {
            collectedAt = session.collectedAt
            dateFromSession = true
        }
        guard !draft.values.isEmpty else {
            problem = .empty(skippedRows: draft.rowsSkipped); stage = .problem
            return
        }
        stage = .review
    }

    /// Back to the viewfinder, dropping the read. The session's saved report stays, so the next page adds to it. A PDF
    /// that is left behind stops waiting.
    func reset() {
        generation = UUID()
        clear()
        queuedPages = []; pdfPage = nil
        stage = .live
    }

    private func clear() {
        draft = nil; values = []; report = nil; rows = []; problem = nil; editing = nil; saveError = nil
        dateFromSession = false
        savedCount = 0; savedReportID = nil; savedIntoExisting = false; savedReportTotal = 0; savedRepeats = 0; outcome = nil
        landed = []; flightFinished = false; capturedAt = nil
    }

    // MARK: Summary

    var needsReviewCount: Int { values.filter(\.needsReview).count }
    var readLine: String { values.count == 1 ? "1 value read" : "\(values.count) values read" }
    var reviewLine: String {
        switch needsReviewCount {
        case 0: "None need a look"
        case 1: "1 needs a look"
        case let count: "\(count) need a look"
        }
    }
    /// "24 values read · 2 need a look"
    var summary: String { "\(readLine) · \(reviewLine)" }
    var skippedLine: String? {
        switch draft?.rowsSkipped ?? 0 {
        case 0: nil
        case 1: "1 row could not be read"
        case let count: "\(count) rows could not be read"
        }
    }
    /// The rows that could not be read, as printed, so the person knows which tests to type in.
    var skippedRows: [String] { draft?.skippedRows ?? [] }

    /// The day the shown page will be saved under, `yyyy-MM-dd` in this zone.
    var collectedDay: String? { Self.day(of: collectedAt, in: timeZone) }

    /// True when saving adds this page to the report saved just before it in this session.
    var addsToSession: Bool { session != nil && session?.day == collectedDay }

    /// Says where this page will go when a page was already saved in this session.
    var sessionLine: String? {
        guard let session else { return nil }
        let day = collectedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timeZone))
        if addsToSession {
            return "Adds to the \(day) report you saved a moment ago, as page \(session.pages + 1)."
        }
        return "This page has another collection day than the page before, so it saves as its own report."
    }
    /// True when the page printed no collection date, so the photo's date stands in.
    var dateMissing: Bool { draft.map { !$0.collectedDateFound } ?? false }
    var labName: String? { draft?.report.labName }
    /// Blood age needs all nine from one draw: a page that adds to the session's report counts with it.
    var bloodAgeReady: Bool { Self.bloodAgeReady(addsToSession ? Self.merged(session?.values ?? [], values) : values) }

    /// The session's values with this page's, a repeat of a value already there counted once.
    static func merged(_ saved: [LabValue], _ page: [LabValue]) -> [LabValue] {
        func key(_ value: LabValue) -> String {
            "\(value.subject)|\(value.value)|\(value.comparator?.rawValue ?? "")|\((value.unit ?? "").lowercased())"
        }
        var seen = Set(saved.map(key))
        return saved + page.filter { seen.insert(key($0)).inserted }
    }

    // MARK: Why a value needs a look

    /// Why Loopr wants a look at one value, from the read. Empty when it is fine or was confirmed.
    func reasons(at index: Int) -> [LabReviewReason] {
        guard values.indices.contains(index), values[index].needsReview else { return [] }
        let read = draft?.reviewReasons[values[index].id] ?? []
        // A value moved to another test may have lost its unit.
        if read.isEmpty, values[index].unit == nil { return [.unitMissing] }
        return read
    }

    /// The name as printed on the page, when it differs from the name Loopr shows.
    func printedName(at index: Int) -> String? {
        guard values.indices.contains(index), let printed = draft?.printedNames[values[index].id] else { return nil }
        let shown = values[index].subject.displayName
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return fold(printed) == fold(shown) || fold(printed) == fold(values[index].assay ?? "") ? nil : printed
    }

    /// One plain sentence per reason, for the edit row.
    static func sentence(for reason: LabReviewReason) -> String {
        switch reason {
        case .separatorUnclear: "The mark in this number could be a decimal point or a thousands mark. Check it on the report."
        case .letterReadAsZero: "Loopr read a letter O as a zero here. Check the digits on the report."
        case .faintRow: "The photo of this row is hard to read. Check the number and the unit."
        case .rangeUnclear: "The lab's range beside it is hard to read. Check it on the report."
        case .unitMissing: "Loopr found no unit beside the value. Pick the one printed on the report."
        case .unitUnknown: "The unit beside it is not one this test is reported in. Pick the one printed on the report."
        }
    }
    /// What VoiceOver says about the read.
    var spokenSummary: String {
        var parts = ["\(readLine), \(reviewLine.lowercased())."]
        if let skippedLine { parts.append("\(skippedLine).") }
        if bloodAgeReady { parts.append("Blood age can be calculated.") }
        return parts.joined(separator: " ")
    }

    /// True when the values hold every PhenoAge input once, each in a unit the PhenoAge engine converts. This only
    /// checks the inputs. Blood age itself is worked out elsewhere, never here.
    static func bloodAgeReady(_ values: [LabValue]) -> Bool {
        PhenoAge.inputMarkers.allSatisfy { key in
            let matching = values.filter { $0.subject == .marker(key) }
            // A result printed as a limit ("<0.3") is not a number PhenoAge takes.
            guard matching.count == 1, let value = matching.first, value.comparator == nil else { return false }
            return (try? LabUnitConverter.phenoAgeValue(value)) != nil
        }
    }

    // MARK: Editing

    /// The units the value's marker is reported in. Empty for a test Loopr has no entry for: its unit stays as printed.
    func unitChoices(at index: Int) -> [String] {
        guard values.indices.contains(index), case .marker(let key) = values[index].subject else { return [] }
        return key.marker.units
    }

    /// The catalog unit the printed unit stands for, or nil when none was printed.
    func unitSymbol(at index: Int) -> String? {
        guard values.indices.contains(index) else { return nil }
        return values[index].unit.flatMap(LabUnitText.symbol(forPrinted:))
    }

    /// The number as the screen shows it, in the app's number locale like every other lab screen (ICP R3-LAB-2).
    func valueText(at index: Int, locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        guard values.indices.contains(index) else { return "" }
        return (values[index].comparator?.symbol ?? "") + Self.localised(values[index].displayValue, locale: locale)
    }

    static func localised(_ dotted: String, locale: Locale) -> String {
        dotted.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    /// Confirms or corrects one value. A decimal comma or a decimal point both read as the decimal mark, as on the
    /// typed entry form (`LabEntryNumber.parse`), whatever the phone's region; the unit must be one the marker
    /// is reported in. An unchanged unit keeps the lab's printed spelling. A test Loopr has no entry for keeps its
    /// unit as printed, with or without one.
    @discardableResult
    func confirm(_ index: Int, value text: String, unit symbol: String?) -> EditOutcome {
        guard values.indices.contains(index) else { return .invalidNumber }
        // A result printed as a limit keeps its sign: "<0.3".
        let split = LabValueComparator.split(text)
        guard let parsed = LabEntryNumber.parse(split.rest) else { return .invalidNumber }
        let number = (value: parsed.value, printedValue: parsed.printed)
        var value = values[index]
        if case .marker(let key) = value.subject {
            guard let symbol else { return .unitNeeded }
            guard key.marker.units.contains(symbol) else { return .unitNotListed }
            if value.unit.flatMap(LabUnitText.symbol(forPrinted:)) != symbol { value.unit = symbol }
        }
        value.value = number.value
        value.printedValue = number.printedValue
        value.comparator = split.comparator
        value.needsReview = false
        values[index] = value
        editing = nil
        return .confirmed
    }

    /// Drops one value from the read: a wrong match or a repeat. Nothing of it is saved.
    func remove(_ index: Int) {
        guard values.indices.contains(index), stage == .review else { return }
        values.remove(at: index)
        if rows.indices.contains(index) { rows.remove(at: index) }
        landed = Set(landed.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
        editing = nil
    }

    /// Changes which test a value is, when the name was matched to the wrong one. The number stays. A unit the new
    /// test is not reported in is cleared, and the value waits for a look until the person picks one.
    func reassign(_ index: Int, to subject: LabValueSubject) {
        guard values.indices.contains(index), values[index].subject != subject else { return }
        var value = values[index]
        value.subject = subject
        value.assay = nil
        if case .marker(let key) = subject {
            let symbol = value.unit.flatMap(LabUnitText.symbol(forPrinted:))
            if symbol.map({ !key.marker.units.contains($0) }) ?? true {
                value.unit = nil
                value.needsReview = true
            }
        }
        values[index] = value
    }

    // MARK: Flight

    func land(_ index: Int) { landed.insert(index) }

    func finishFlight() {
        landed = Set(values.indices)
        flightFinished = true
    }

    // MARK: Saving

    /// Writes the page, with source scan, in one transaction. Nil means storage is not open.
    ///
    /// A page drawn on the same day as the page saved before it in this session adds to that report. Otherwise a saved
    /// scanned report from the same lab on the same day takes the page (the other page of it, scanned another time).
    /// Anything else starts a new report. A value the report already holds is not saved twice.
    /// - Parameter birthYear: the profile's birth year, so the saved card can say whether blood age came out of it.
    func save(to store: LabStore?, birthYear: @escaping @Sendable () async -> Int? = { nil }) async {
        guard stage == .review, let draft else { return }
        guard let store else {
            saveError = "Storage isn't ready on this iPhone yet. Try again in a moment."
            return
        }
        stage = .saving; saveError = nil; editing = nil
        var report = draft.report
        report.collectedAt = collectedAt
        let final = report, page = values, zone = timeZone
        let sessionTarget = addsToSession ? session?.reportID : nil
        do {
            let result = try await Task.detached(priority: .userInitiated) { () throws -> SaveResult in
                try Self.write(final, values: page, sessionTarget: sessionTarget, to: store)
            }.value
            let year = await birthYear()
            let outcome = try? await Task.detached(priority: .utility) { () throws -> LabSaveOutcome in
                let reports = try store.reports()
                var all: [LabValue] = []
                for each in reports { all += try store.values(reportID: each.id) }
                return LabSaveOutcome.make(reportID: result.reportID, reports: reports, values: all, birthYear: year)
            }.value
            savedCount = result.added.count
            savedRepeats = page.count - result.added.count
            savedReportID = result.reportID
            savedIntoExisting = result.intoExisting
            savedReportTotal = result.total
            self.outcome = outcome
            let day = Self.day(of: final.collectedAt, in: zone) ?? ""
            if let current = session, current.reportID == result.reportID {
                session = PageSession(reportID: current.reportID, day: current.day, collectedAt: current.collectedAt,
                                      pages: current.pages + 1, values: current.values + result.added)
            } else {
                session = PageSession(reportID: result.reportID, day: day, collectedAt: final.collectedAt, pages: 1,
                                      values: result.added)
            }
            stage = .saved
        } catch {
            saveError = "These values could not be saved. Try again."
            stage = .review
        }
    }

    nonisolated struct SaveResult: Sendable {
        let reportID: UUID
        let added: [LabValue]
        let intoExisting: Bool
        /// Values in the report after the save.
        let total: Int
    }

    /// Where a page goes, and the write itself. Runs off the main actor.
    nonisolated static func write(_ report: LabReport, values: [LabValue], sessionTarget: UUID?,
                                  to store: LabStore) throws -> SaveResult {
        var target = sessionTarget
        if target == nil, let lab = normalisedLab(report.labName), let day = report.collectedDay {
            target = try store.reports().first { stored in
                stored.source == .scan && stored.collectedDay == day && normalisedLab(stored.labName) == lab
            }?.id
        }
        if let target, try store.report(id: target) != nil {
            let moved = values.map { value -> LabValue in var copy = value; copy.reportID = target; return copy }
            let added = try store.appendValues(moved, toReport: target)
            return SaveResult(reportID: target, added: added, intoExisting: true, total: try store.values(reportID: target).count)
        }
        try store.saveReport(report, values: values)
        return SaveResult(reportID: report.id, added: values, intoExisting: false, total: values.count)
    }

    nonisolated static func normalisedLab(_ name: String?) -> String? {
        guard let name else { return nil }
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }

    nonisolated static func day(of date: Date, in zone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: Saved

    /// "29 values saved", or for a page that added to a report, "16 values added".
    var savedTitle: String {
        let noun = savedCount == 1 ? "value" : "values"
        return savedIntoExisting ? "\(savedCount) \(noun) added" : "\(savedCount) \(noun) saved"
    }

    /// Where they went, when they joined a report already saved.
    var savedPlaceLine: String? {
        guard savedIntoExisting else { return nil }
        var line = "They joined the report from the same day, which now holds \(savedReportTotal) values."
        if savedRepeats > 0 {
            line += savedRepeats == 1 ? " Loopr left out 1 value the report already had."
                : " Loopr left out \(savedRepeats) values the report already had."
        }
        return line
    }

    // MARK: Rows

    /// Where each value's row sits on the page, from the top: the first line, at or below the previous value's row,
    /// holding the value's printed digits with either decimal mark. Nil when no line matches.
    static func rowPositions(for values: [LabValue], lines: [LabTextLine]) -> [Double?] {
        let ordered = lines.sorted { $0.minY + $0.height / 2 > $1.minY + $1.height / 2 }
        var cursor = 0
        return values.map { value in
            let dotted = value.displayValue
            let forms = [dotted, dotted.replacingOccurrences(of: ".", with: ",")]
            for index in cursor..<ordered.count {
                let words = ordered[index].text.split(whereSeparator: \.isWhitespace).map(String.init)
                guard words.contains(where: { word in forms.contains { Self.word(word, starts: $0) } }) else { continue }
                cursor = index
                let line = ordered[index]
                return min(max(1 - (line.minY + line.height / 2), 0), 1)
            }
            return nil
        }
    }

    /// The word is the number, or the number glued to a unit ("4,9mmol/l").
    private static func word(_ word: String, starts number: String) -> Bool {
        // A limit prints its sign before the digits: "<0,3".
        let word = String(word.drop(while: { "<>≤≥=".contains($0) }))
        guard word.hasPrefix(number) else { return false }
        guard let next = word.dropFirst(number.count).first else { return true }
        return !next.isNumber && next != "." && next != ","
    }
}
