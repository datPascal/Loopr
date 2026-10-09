import Foundation
import CryptoKit
import StorageKit
import DomainKit
import DesignSystem
import TodayKit
import SleepKit
import WorkoutKit
import JournalKit

public struct WHOOPImportResult: Equatable, Sendable {
    public var days = 0, sleeps = 0, workouts = 0, journalAnswers = 0
    public var unchanged = 0, updatedRows = 0, missingDate = 0, invalidRows = 0
    public init() {}
    public var summary: String {
        func count(_ value: Int, _ noun: String) -> String {
            "\(value.formatted(.number.grouping(.automatic))) \(noun)\(value == 1 ? "" : "s")"
        }
        func list(_ parts: [String]) -> String {
            guard parts.count > 1 else { return parts.first ?? "" }
            return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        var added = [count(days, "day"), count(sleeps, "sleep"), count(workouts, "workout")]
        if journalAnswers > 0 { added.append(count(journalAnswers, "journal answer")) }
        var text = "Added " + list(added) + "."
        if updatedRows > 0 { text += " Updated \(count(updatedRows, "row"))." }
        var skipped: [String] = []
        if unchanged > 0 { skipped.append("\(count(unchanged, "row")) already imported") }
        if missingDate > 0 { skipped.append("\(count(missingDate, "row")) with no date") }
        if invalidRows > 0 { skipped.append("\(count(invalidRows, "row")) with invalid fields") }
        if !skipped.isEmpty { text += " Skipped " + list(skipped) + "." }
        return text
    }
}

public struct WHOOPImportedDay: Codable, Sendable {
    public let today: TodaySummary
    public let sleep: SleepDaySnapshot?
    public let timezone: String
    public let totalEnergyKcal: Double?
}

/// Import-owned records live beside metric_series in the history database.
/// One transaction parses the entire selection and saves its typed product
/// models and trend values. Native repositories resolve band values first.
public struct WHOOPImportStore: Sendable {
    private let database: StorageDatabase
    public init(database: StorageDatabase) throws {
        self.database = database
        try database.performSetupOnce("whoop-export-v1") {
            try database.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS whoop_export_row (
                        id TEXT PRIMARY KEY, kind TEXT NOT NULL, local_day TEXT NOT NULL,
                        start REAL NOT NULL, payload BLOB NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS whoop_export_day_rows ON whoop_export_row(local_day, kind);
                    CREATE INDEX IF NOT EXISTS whoop_export_cycle ON whoop_export_row(kind, start);
                    CREATE TABLE IF NOT EXISTS whoop_export_day (
                        local_day TEXT PRIMARY KEY, payload BLOB NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS whoop_export_workout (
                        id TEXT PRIMARY KEY, local_day TEXT NOT NULL, start REAL NOT NULL, payload BLOB NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS whoop_export_workout_start ON whoop_export_workout(start);
                    CREATE TABLE IF NOT EXISTS whoop_export_journal (
                        id TEXT PRIMARY KEY, local_day TEXT NOT NULL, payload BLOB NOT NULL
                    );
                    """)
            }
        }
    }

    public func apply(csvs: [URL]) throws -> WHOOPImportResult {
        var result = WHOOPImportResult()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try database.write { db in
            var affected = Set<String>()
            // Cycles precede journals so a selection can resolve each journal
            // cycle to its wake day without shifting unrelated dates.
            let sorted = csvs.sorted { priority($0) < priority($1) }
            for url in sorted {
                let known = WHOOPExportKind(rawValue: url.deletingPathExtension().lastPathComponent.lowercased())
                let summary = try WHOOPExportParser.parse(url: url, kind: known) { row in
                    try Task.checkCancellation()
                    let payload = try encoder.encode(row)
                    let old = try Data.fetchOne(db, sql: "SELECT payload FROM whoop_export_row WHERE id = ?", arguments: [row.id])
                    if old == payload { result.unchanged += 1; return }
                    if old != nil { result.updatedRows += 1 }
                    if let old, let previous = try? JSONDecoder().decode(WHOOPExportRow.self, from: old) { affected.insert(previous.day) }
                    if old == nil {
                        switch row.kind {
                        case .cycle: break
                        case .sleep: result.sleeps += 1
                        case .workout: result.workouts += 1
                        case .journal: result.journalAnswers += 1
                        }
                    }
                    try db.execute(sql: """
                        INSERT INTO whoop_export_row(id, kind, local_day, start, payload) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET local_day = excluded.local_day, start = excluded.start, payload = excluded.payload
                        """, arguments: [row.id, row.kind.rawValue, row.day, row.start.timeIntervalSince1970, payload])
                    affected.insert(row.day)
                    if row.kind == .workout {
                        let workout = Self.workout(row)
                        try db.execute(sql: """
                            INSERT INTO whoop_export_workout(id, local_day, start, payload) VALUES (?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET local_day = excluded.local_day, start = excluded.start, payload = excluded.payload
                            """, arguments: [workout.id.uuidString, row.day, row.start.timeIntervalSince1970, try encoder.encode(workout)])
                    }
                }
                result.missingDate += summary.missingDate; result.invalidRows += summary.invalidRows
            }
            // Rebuild journal days when their cycle arrives in a later import.
            let journalRows = try rows(in: db, kind: .journal)
            var journalDays: [String: [WHOOPExportRow]] = [:]
            for row in journalRows {
                let day = try String.fetchOne(db, sql: "SELECT local_day FROM whoop_export_row WHERE kind = ? AND start = ? LIMIT 1",
                                              arguments: [WHOOPExportKind.cycle.rawValue, row.start.timeIntervalSince1970]) ?? row.day
                journalDays[day, default: []].append(row)
                try db.execute(sql: "UPDATE whoop_export_row SET local_day = ? WHERE id = ?", arguments: [day, row.id])
            }
            try db.execute(sql: "DELETE FROM whoop_export_journal")
            for (day, rows) in journalDays {
                guard let entry = Self.journal(rows, day: day) else { continue }
                try db.execute(sql: "INSERT INTO whoop_export_journal(id, local_day, payload) VALUES (?, ?, ?)",
                               arguments: [entry.id.uuidString, day, try encoder.encode(entry)])
            }
            for day in affected {
                let rows = try rows(in: db, day: day)
                guard rows.contains(where: { $0.kind == .cycle || $0.kind == .sleep }) else {
                    try db.execute(sql: "DELETE FROM whoop_export_day WHERE local_day = ?", arguments: [day])
                    try db.execute(sql: "DELETE FROM metric_series WHERE source = ? AND local_day = ?", arguments: [StoredMetricSeriesSource.whoopExport.rawValue, day])
                    continue
                }
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM whoop_export_day WHERE local_day = ?)", arguments: [day]) != true { result.days += 1 }
                let model = Self.day(rows, label: day)
                try db.execute(sql: """
                    INSERT INTO whoop_export_day(local_day, payload) VALUES (?, ?)
                    ON CONFLICT(local_day) DO UPDATE SET payload = excluded.payload
                    """, arguments: [day, try encoder.encode(model)])
                // Only import-owned values are replaced. Band rows stay intact.
                try db.execute(sql: "DELETE FROM metric_series WHERE source = ? AND local_day = ?",
                               arguments: [StoredMetricSeriesSource.whoopExport.rawValue, day])
                for (key, value) in Self.metricValues(rows) {
                    try db.execute(sql: """
                        INSERT INTO metric_series(local_day, metric_key, source, value, updated_at) VALUES (?, ?, ?, ?, ?)
                        """, arguments: [day, key, StoredMetricSeriesSource.whoopExport.rawValue, value, Int64(Date().timeIntervalSince1970)])
                }
            }
        }
        return result
    }

    public func day(_ label: String) throws -> WHOOPImportedDay? {
        try database.read { db in
            guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM whoop_export_day WHERE local_day = ?", arguments: [label]) else { return nil }
            let model = try JSONDecoder().decode(WHOOPImportedDay.self, from: payload)
            // Older saved models marked every export session as still recording.
            // Rebuild those models from the retained import rows, without requiring
            // a reimport or changing the account's stored metric history.
            if model.sleep?.mainSleep?.isPartial == true || model.sleep?.naps.contains(where: \.isPartial) == true {
                let rows = try self.rows(in: db, day: label)
                if !rows.isEmpty { return Self.day(rows, label: label) }
            }
            return model
        }
    }

    public func sleepTrend(endingOn label: String, days: Int = 31) throws -> [SleepTrendPoint] {
        let lower = Self.previous(label, days: days - 1)
        return try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM whoop_export_day WHERE local_day >= ? AND local_day <= ? ORDER BY local_day", arguments: [lower, label]).compactMap { payload in
                let model = try JSONDecoder().decode(WHOOPImportedDay.self, from: payload)
                guard let sleep = model.sleep, let main = sleep.mainSleep else { return nil }
                return SleepTrendPoint(id: "import:\(Self.label(sleep.day))", localDay: Self.label(sleep.day),
                    // SleepTrendPoint uses hours; the import and metric history use minutes.
                    value: sleep.metric("duration")?.numericValue.map { $0 / 60 }, state: .partial, unit: "h", start: main.start, end: main.end,
                    values: SleepTrendPoint.nightValues(sleep))
            }
        }
    }

    public func workouts(from start: Date? = nil, through end: Date? = nil) throws -> [WorkoutRecord] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM whoop_export_workout WHERE start >= ? AND start <= ? ORDER BY start",
                              arguments: [start?.timeIntervalSince1970 ?? -62_135_596_800, end?.timeIntervalSince1970 ?? 253_402_300_799])
                .map { try JSONDecoder().decode(WorkoutRecord.self, from: $0) }
        }
    }

    public func journals() throws -> [JournalEntry] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM whoop_export_journal ORDER BY local_day")
                .map { try JSONDecoder().decode(JournalEntry.self, from: $0) }
        }
    }

    public func removeWorkout(id: UUID) throws {
        try database.write { db in
            if let payload = try Data.fetchOne(db, sql: "SELECT payload FROM whoop_export_workout WHERE id = ?", arguments: [id.uuidString]) {
                let model = try JSONDecoder().decode(WorkoutRecord.self, from: payload)
                let sourceID = String(model.identity.canonicalKey.dropFirst("source:".count))
                try db.execute(sql: "DELETE FROM whoop_export_row WHERE id = ?", arguments: [sourceID])
            }
            try db.execute(sql: "DELETE FROM whoop_export_workout WHERE id = ?", arguments: [id.uuidString])
        }
    }
    public func removeJournal(id: UUID) throws {
        try database.write { db in
            if let day = try String.fetchOne(db, sql: "SELECT local_day FROM whoop_export_journal WHERE id = ?", arguments: [id.uuidString]) {
                try db.execute(sql: "DELETE FROM whoop_export_row WHERE kind = ? AND local_day = ?", arguments: [WHOOPExportKind.journal.rawValue, day])
            }
            try db.execute(sql: "DELETE FROM whoop_export_journal WHERE id = ?", arguments: [id.uuidString])
        }
    }
    public func deleteWorkouts() throws { try database.write { db in try db.execute(sql: "DELETE FROM whoop_export_workout; DELETE FROM whoop_export_row WHERE kind = 'workouts'") } }
    public func deleteJournals() throws { try database.write { db in try db.execute(sql: "DELETE FROM whoop_export_journal; DELETE FROM whoop_export_row WHERE kind = 'journal_entries'") } }

    private func priority(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        return (name == "physiological_cycles.csv" ? "0" : name == "journal_entries.csv" ? "2" : "1") + name
    }
    private func rows(in db: Database, day: String? = nil, kind: WHOOPExportKind? = nil) throws -> [WHOOPExportRow] {
        var sql = "SELECT payload FROM whoop_export_row WHERE 1 = 1"; var args = StatementArguments()
        if let day { sql += " AND local_day = ?"; args += [day] }
        if let kind { sql += " AND kind = ?"; args += [kind.rawValue] }
        sql += " ORDER BY start, id"
        return try Data.fetchAll(db, sql: sql, arguments: args).map { try JSONDecoder().decode(WHOOPExportRow.self, from: $0) }
    }

    public static func label(_ day: DayIdentity) -> String { String(format: "%04d-%02d-%02d", day.year, day.month, day.day) }
    private static func identity(_ label: String) -> DayIdentity {
        let parts = label.split(separator: "-").map { Int($0)! }
        return DayIdentity(year: parts[0], month: parts[1], day: parts[2])
    }
    private static func previous(_ label: String, days: Int) -> String {
        let zone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = identity(label)
        let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        return WHOOPExportParser.dayLabel(calendar.date(byAdding: .day, value: -max(0, days), to: date)!, zone: zone)
    }
    private static func display(_ value: Double?) -> String? { value.map { String(format: "%.1f", $0) } }
    private static func uuid(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    private static func day(_ rows: [WHOOPExportRow], label: String) -> WHOOPImportedDay {
        let cycle = rows.first { $0.kind == .cycle }
        let sleeps = rows.filter { $0.kind == .sleep }
        let main = sleeps.first { !$0.isNap }
        let values = main ?? cycle
        let day = identity(label)
        func number(_ header: String) -> Double? { values?.number(header) ?? cycle?.number(header) }
        let metricDefinitions: [(TodayMetricID, String, String, String, TodayMetricUnitID)] = [
            (.recovery, "Recovery", "Recovery score", "%", .scorePoints),
            (.hrv, "HRV", "Heart rate variability", "ms", .milliseconds),
            (.restingHeartRate, "Resting heart rate", "Resting heart rate", "bpm", .beatsPerMinute),
            (.strain, "Strain", "Day Strain", "", .strainScore),
            (.sleep, "Sleep", "Asleep duration", "min", .minutes)
        ]
        let metrics = metricDefinitions.map { id, title, header, unit, numericUnit in
            let value = number(header)
            return TodayMetricValue(id: id, title: title, value: display(value), unit: unit,
                state: value == nil ? .absent : value == 0 ? .measuredZero : .partial,
                source: "Account export", numericValue: value, numericUnit: numericUnit)
        }
        let today = TodaySummary(day: day, overallState: .partial,
            freshness: TodayFreshness(state: .partial, updatedAt: nil, ageMinutes: nil, detail: "Imported from account export"),
            device: TodayDeviceSnapshot(connection: .unknown, status: .absent), metrics: metrics, sleepNeedMinutes: number("Sleep need"))
        func session(_ row: WHOOPExportRow, main: Bool) -> SleepSessionSummary? {
            let zone = TimeZone(identifier: row.timezone)
            let start = row.kind == .sleep ? row.start : WHOOPExportParser.date(row.text("Sleep onset"), zone: zone)
            guard let start, let end = row.end, end > start, let duration = row.number("Asleep duration") else { return nil }
            return SleepSessionSummary(id: row.id, start: start, end: end, durationMinutes: Int(duration.rounded()),
                                       // Zero is the classifier trust weight, not a sensor measurement.
                                       // An export supplies no Loopr classification evidence.
                                       // Both endpoints are supplied by the completed export row.
                                       isMainSleep: main, isPartial: false, confidence: 0, state: .partial)
        }
        let mainSession = main.flatMap { session($0, main: true) } ?? cycle.flatMap { session($0, main: true) }
        let definitions: [(String, String, String, SleepMetricUnitID, String)] = [
            ("duration", "Time asleep", "Asleep duration", .minutes, "min"),
            ("deep", "Deep sleep", "Deep (SWS) duration", .minutes, "min"),
            ("rem", "REM sleep", "REM duration", .minutes, "min"),
            ("light", "Light sleep", "Light sleep duration", .minutes, "min"),
            ("awake", "Time awake", "Awake duration", .minutes, "min"),
            ("efficiency", "Sleep efficiency", "Sleep efficiency", .percentagePoints, "%"),
            ("performance", "Sleep performance", "Sleep performance", .percentagePoints, "%"),
            ("consistency", "Sleep consistency", "Sleep consistency", .percentagePoints, "%")
        ]
        let sleep: SleepDaySnapshot? = values == nil && sleeps.isEmpty ? nil : SleepDaySnapshot(day: day, state: .partial, mainSleep: mainSession,
            naps: sleeps.filter { $0.id != main?.id }.compactMap { session($0, main: false) },
            metrics: definitions.map { id, title, header, numericUnit, unit in
                let value = number(header)
                return SleepMetricValue(id: id, title: title, value: display(value), unit: unit,
                    state: value == nil ? .absent : value == 0 ? .measuredZero : .partial,
                    source: "Account export", numericValue: value, numericUnit: numericUnit)
            }, needHours: number("Sleep need").map { $0 / 60 }, debtHours: number("Sleep debt").map { $0 / 60 }, source: "Account export")
        return WHOOPImportedDay(today: today, sleep: sleep, timezone: (cycle ?? main ?? rows[0]).timezone, totalEnergyKcal: cycle?.number("Energy burned"))
    }

    private static func metricValues(_ rows: [WHOOPExportRow]) -> [String: Double] {
        let cycle = rows.first { $0.kind == .cycle }
        let sleep = rows.first { $0.kind == .sleep && !$0.isNap }
        // WHOOP daily energy includes basal metabolism. It is preserved on
        // WHOOPImportedDay rather than mixed into Loopr active_energy.
        // WHOOP's own calorie documentation describes the basal share.
        let definitions = ["recovery": "Recovery score", "resting_heart_rate": "Resting heart rate", "rmssd": "Heart rate variability",
                           "strain": "Day Strain", "respiratory_rate": "Respiratory rate",
                           "oxygen_saturation": "Blood oxygen", "sleep_duration": "Asleep duration", "sleep_efficiency": "Sleep efficiency",
                           "deep_sleep": "Deep (SWS) duration", "rem_sleep": "REM duration", "sleep_consistency": "Sleep consistency", "max_heart_rate": "Max HR"]
        return definitions.reduce(into: [:]) { result, item in
            // Metric-history sleep totals use minutes, matching Loopr history units.
            if let value = sleep?.number(item.value) ?? cycle?.number(item.value) {
                result[item.key] = value
            }
        }
    }

    private static func workout(_ row: WHOOPExportRow) -> WorkoutRecord {
        let name = row.text("Activity name")?.lowercased() ?? ""
        let activity: ActivityType = ["running": .run, "cycling": .cycle, "walking": .walk, "hiking": .hike,
                                      "weightlifting": .strength, "strength training": .strength, "swimming": .swim,
                                      "yoga": .yoga, "hiit": .hiit].first { $0.key == name }?.value ?? .other
        return WorkoutRecord(id: uuid(row.id), identity: .make(activity: activity, sourceKey: row.id, startedAt: row.start, endedAt: row.end),
            activity: activity, source: .imported, state: .completed, createdAt: row.start, startedAt: row.start, endedAt: row.end,
            finalizationStage: .activeStateCleared,
            importedSummary: WorkoutImportedSummary(source: "Account export", activityName: row.text("Activity name"),
                strain: row.number("Activity Strain"), energyKcal: row.number("Energy burned"),
                averageHeartRate: row.number("Average HR"), maximumHeartRate: row.number("Max HR"),
                zonePercentages: (1...5).reduce(into: [:]) { values, zone in
                    if let value = row.number("HR Zone \(zone)"), value <= 100 { values[zone] = value }
                }))
    }

    private static func journal(_ rows: [WHOOPExportRow], day: String) -> JournalEntry? {
        // Only exact, binary behavior names have a clean JournalKit mapping.
        // Unrecognized questions/notes remain in the import-owned raw row.
        var yes = Set<String>(); var answers: [String] = []
        let known: [String: String] = ["alcohol": "Alcohol", "caffeine": "Caffeine", "meditation": "Meditation", "stretching": "Stretching"]
        for row in rows {
            guard let question = row.text("Question text"), let behavior = known[question.lowercased()],
                  let answer = row.text("Answered yes") ?? row.text("Answered yes/no"),
                  ["yes", "no", "true", "false", "1", "0"].contains(answer.lowercased()) else { continue }
            if ["yes", "true", "1"].contains(answer.lowercased()) { yes.insert(behavior) }
            answers.append("\(behavior): \(["yes", "true", "1"].contains(answer.lowercased()) ? "Yes" : "No")")
        }
        guard !answers.isEmpty, let first = rows.first else { return nil }
        return JournalEntry(id: uuid("whoop-journal:\(day)"), day: day, behaviors: yes, tags: ["Account export"],
                            note: answers.sorted().joined(separator: "\n"), createdAt: first.start, updatedAt: first.start)
    }
}

public actor WHOOPExportImporter {
    private let store: WHOOPImportStore
    public init(store: WHOOPImportStore) { self.store = store }
    private func folderCSVs(at url: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw WHOOPImportError.noCSV }
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "csv" {
            if WHOOPExportKind(rawValue: file.deletingPathExtension().lastPathComponent.lowercased()) != nil { files.append(file) }
        }
        return files
    }
    public func importFiles(_ urls: [URL], progress: @Sendable (String) async -> Void = { _ in }) async throws -> WHOOPImportResult {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-account-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var csvs: [URL] = []
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        for url in urls {
            try Task.checkCancellation()
            await progress("Reading \(url.lastPathComponent)")
            if url.pathExtension.lowercased() == "zip" {
                let target = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                csvs += try WHOOPZIPReader.extractCSVs(from: url, into: target)
            }
            else if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                csvs += try folderCSVs(at: url)
            } else if url.pathExtension.lowercased() == "csv" { csvs.append(url) }
        }
        guard !csvs.isEmpty else { throw WHOOPImportError.noCSV }
        await progress("Importing history")
        try Task.checkCancellation()
        return try store.apply(csvs: csvs)
    }
}
