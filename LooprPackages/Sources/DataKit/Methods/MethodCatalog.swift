import DesignSystem
import Foundation

/// The method page for every number family Loopr shows (DEC-12.20, App Store guideline 1.4.1).
///
/// Rules for anyone editing this catalog:
/// - Versions are read from the code's own constants, never retyped.
/// - Each source file names its lines and an anchor line inside them. `MethodCatalogTests` reads the repository and
///   fails when a path is gone, an anchor moved out of its range or a listed test suite no longer exists.
/// - References are ones recorded in the code or in `docs/`. Without a paper, the page says it is Loopr's own method.
/// - Copy is plain wellness wording and passes the unslop skill: sentence case, no em dashes, nothing called a
///   diagnosis.
public enum MethodCatalog {
    /// The public repository the "View on GitHub" link opens in Safari. The app makes no request to it.
    public static let repositoryURL = "https://github.com/datPascal/Loopr"

    /// The line every method page carries.
    public static let medicalLine = LooprMedicalLine.text + " If a number worries you, talk to a doctor."

    /// Shown when a method has no published paper.
    public static let ownMethodLine = "Loopr's own method. The rule is written out above, and the code is open."

    public static let entries: [MethodEntry] = heartEntries + sleepEntries + activityEntries + ageEntries
        + foodEntries + routineEntries + labEntries

    private static let byID: [MethodID: MethodEntry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    public static func entry(_ id: MethodID) -> MethodEntry {
        guard let entry = byID[id] else { preconditionFailure("MethodCatalog has no entry for \(id.rawValue)") }
        return entry
    }

    /// The page that explains a metric, by `MetricKey` raw value.
    public static func entry(forMetricKey rawValue: String) -> MethodEntry? {
        entries.first { $0.metricKeys.contains(rawValue) }
    }

    public static func entries(in group: MethodGroup) -> [MethodEntry] {
        entries.filter { $0.group == group }
    }
}

// Short builders that keep the formula tables readable.
func fv(_ text: String) -> LooprFormulaToken { .variable(text) }
func fn(_ text: String) -> LooprFormulaToken { .number(text) }
func fo(_ text: String) -> LooprFormulaToken { .op(text) }
func ff(_ text: String) -> LooprFormulaToken { .function(text) }

/// Repo-relative roots used by the catalog files.
enum MethodPaths {
    static let analytics = "LooprPackages/Sources/AnalyticsKit/"
    static let analyticsTests = "LooprPackages/Tests/AnalyticsKitTests/"
    static let app = "Loopr/Loopr/App/"
    static let daily = "Loopr/Loopr/App/CanonicalDailyAnalytics.swift"
    static let train = "LooprPackages/Sources/TrainKit/Fitness/"
    static let trainTests = "LooprPackages/Tests/TrainKitTests/Fitness/"
    static let food = "LooprPackages/Sources/FoodKit/"
    static let foodTests = "LooprPackages/Tests/FoodKitTests/"
    static let routine = "LooprPackages/Sources/RoutineKit/"
    static let routineTests = "LooprPackages/Tests/RoutineKitTests/"
    static let journal = "LooprPackages/Sources/JournalKit/"
    static let journalTests = "LooprPackages/Tests/JournalKitTests/"
}
