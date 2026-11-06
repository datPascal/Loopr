import DesignSystem
import Foundation

/// Every number family that has a method page (DEC-12.20). The raw value is the page's stable id: it names the
/// accessibility identifier `method-<id>` and the DEBUG launch argument `--loopr-method=<id>`.
public enum MethodID: String, CaseIterable, Hashable, Codable, Sendable {
    case recovery
    case sleepStages = "sleep-stages"
    case sleepNeed = "sleep-need"
    case sleepRegularity = "sleep-regularity"
    case hrv
    case restingHeartRate = "resting-heart-rate"
    case maxHeartRate = "max-heart-rate"
    case respiration
    case skinTemperature = "skin-temperature"
    case oxygen
    case strain
    case trainingLoad = "training-load"
    case stress
    case hourlyStress = "hourly-stress"
    case overnightCheck = "overnight-check"
    case heartRateRecovery = "heart-rate-recovery"
    case activeEnergy = "active-energy"
    case steps
    case cardioAge = "cardio-age"
    case vo2MaxGauge = "vo2max-gauge"
    case phenoAge = "phenoage"
    case looprAge = "loopr-age"
    case proteinPerKilogram = "protein-per-kg"
    case fibre
    case ultraProcessedShare = "ultra-processed-share"
    case plantsPerWeek = "plants-per-week"
    case weeklyDose = "weekly-dose"
    case capacityTests = "capacity-tests"
    case protocolKeptShare = "protocol-kept-share"
    case experimentResult = "experiment-result"
    case patternStrength = "pattern-strength"
    case labUnitConversion = "lab-unit-conversion"
    case labRanges = "lab-ranges"
}

/// The sections of the "How the numbers work" list.
public enum MethodGroup: String, CaseIterable, Sendable {
    case heart, sleep, activity, age, food, routine, labs

    public var title: String {
        switch self {
        case .heart: "Heart and recovery"
        case .sleep: "Sleep"
        case .activity: "Activity and fitness"
        case .age: "Ages"
        case .food: "Food"
        case .routine: "Protocol and patterns"
        case .labs: "Blood tests"
        }
    }
}

/// The version a method stamps on what it stores, read from the code's own constant.
public struct MethodVersion: Hashable, Sendable {
    /// The constant's value, such as `loopr.phenoage.1`.
    public let value: String
    /// The Swift name of the constant, such as `PhenoAge.version`.
    public let symbol: String
    /// Repo-relative path of the file that declares the constant.
    public let file: String

    public init(_ value: String, symbol: String, file: String) {
        self.value = value
        self.symbol = symbol
        self.file = file
    }
}

/// Where an input comes from. Each maps to the provenance chip the app uses for that source.
public enum MethodInputSource: Hashable, Sendable {
    case band
    case appleHealth
    case typed
    case labReport
    case foodLog
    case openFoodFacts
    case photoEstimate
    case phoneTimer
    case protocolRules
    case computed(String)

    public var label: String {
        switch self {
        case .band: "Band"
        case .appleHealth: "Apple Health"
        case .typed: "Typed in"
        case .labReport: "Lab report"
        case .foodLog: "Food log"
        case .openFoodFacts: "Open Food Facts"
        case .photoEstimate: "Photo estimate"
        case .phoneTimer: "Timed on this iPhone"
        case .protocolRules: "Your protocol"
        case .computed(let from): from
        }
    }

    public var provenance: LooprProvenance {
        switch self {
        case .band: .band(device: "Band")
        case .appleHealth: .appleHealth(source: "Apple Health")
        case .typed: .typedIn
        case .labReport: .lab(name: "")
        case .foodLog: .food(.logged)
        case .openFoodFacts: .food(.barcode)
        case .photoEstimate: .food(.photoEstimate)
        case .phoneTimer, .protocolRules, .computed: .onThisPhone
        }
    }
}

public struct MethodInput: Hashable, Sendable {
    public let name: String
    public let unit: String?
    public let sources: [MethodInputSource]

    public init(_ name: String, unit: String? = nil, from sources: MethodInputSource...) {
        self.name = name
        self.unit = unit
        self.sources = sources
    }
}

/// A paper, guideline or upstream implementation the method follows.
public struct MethodReference: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A published paper or guideline the method or its constants come from.
        case paper
        /// Evidence or guidance behind a target or a choice of test, not the calculation itself.
        case background
        /// Open-source code Loopr's version follows or was checked against.
        case implementation
        /// A reference table, list or data source the method reads.
        case data
    }

    public let kind: Kind
    public let authors: String
    public let year: Int?
    public let title: String
    /// Journal, volume and pages, or the repository and commit.
    public let venue: String
    /// A DOI or web address. Nil when none is recorded in the repository.
    public let link: URL?
    /// What Loopr takes from it, in one sentence.
    public let use: String

    public init(_ kind: Kind = .paper, authors: String, year: Int?, title: String, venue: String, link: String? = nil,
                use: String) {
        self.kind = kind
        self.authors = authors
        self.year = year
        self.title = title
        self.venue = venue
        self.link = link.flatMap(URL.init(string:))
        self.use = use
    }

    /// "Levine and colleagues, 2018".
    public var citation: String {
        [authors, year.map(String.init)].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A source file and the lines that hold a method's core calculation.
///
/// Line numbers move when the file changes, so each one carries an `anchor`: a line of code that must sit inside the
/// range. `MethodCatalogTests` reads the file and fails when the anchor has moved out.
public struct MethodSourceFile: Hashable, Sendable {
    /// Repo-relative path.
    public let path: String
    public let lines: ClosedRange<Int>
    /// The function or type at those lines, as people would search for it.
    public let symbol: String
    /// Text from one line inside `lines`, compared after trimming whitespace.
    public let anchor: String

    public init(_ path: String, lines: ClosedRange<Int>, symbol: String, anchor: String) {
        self.path = path
        self.lines = lines
        self.symbol = symbol
        self.anchor = anchor
    }

    /// The file on GitHub, opened at the line range.
    public var gitHubURL: URL {
        // Every character of a repo path is URL-safe apart from spaces, which no catalogued path has.
        URL(string: MethodCatalog.repositoryURL + "/blob/main/" + path + LooprCodeCardFormat.fragment(lines))!
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// A test suite that checks the method. The catalog states which suites exist; it never states a run result.
public struct MethodTestSuite: Hashable, Sendable {
    /// The type name: an `XCTestCase` subclass or a Swift Testing suite.
    public let name: String
    /// Repo-relative path of the file that declares it.
    public let path: String

    public init(_ name: String, in path: String) {
        self.name = name
        self.path = path
    }
}

public struct MethodFormula: Hashable, Sendable {
    public let lines: [LooprFormulaLine]
    /// What the symbols mean, in a sentence or two.
    public let caption: String

    public init(_ lines: [LooprFormulaLine], caption: String) {
        self.lines = lines
        self.caption = caption
    }
}

/// Everything a method page says about one number family.
public struct MethodEntry: Hashable, Sendable, Identifiable {
    public let id: MethodID
    public let group: MethodGroup
    /// What the number is called on screen: "Blood age".
    public let title: String
    /// The method's own name when it has one: "PhenoAge".
    public let methodName: String?
    /// Nil when the code keeps no version constant for this number.
    public let version: MethodVersion?
    /// What it is, in one plain sentence.
    public let summary: String
    /// The rule written out, a few sentences. Metric pages add the metric catalog's own text in the app.
    public let rule: [String]
    public let formula: MethodFormula?
    public let inputs: [MethodInput]
    /// Papers, implementations and data. Without a paper, the page says it is Loopr's own method.
    public let references: [MethodReference]
    /// The first file holds the core calculation.
    public let sources: [MethodSourceFile]
    public let testSuites: [MethodTestSuite]
    /// What it cannot tell you, and what makes it wrong.
    public let limits: [String]
    /// True when the page carries `MethodCatalog.medicalLine`. Every page does (LV-10.6); a page opts out only by passing false.
    public let showsMedicalLine: Bool
    /// `MetricKey` raw values this page explains. The app checks every key has a page.
    public let metricKeys: [String]
    /// The hero's unit when a value is passed.
    public let unit: String?

    public init(id: MethodID, group: MethodGroup, title: String, methodName: String? = nil, version: MethodVersion?,
                summary: String, rule: [String], formula: MethodFormula? = nil, inputs: [MethodInput],
                references: [MethodReference] = [], sources: [MethodSourceFile], testSuites: [MethodTestSuite],
                limits: [String], showsMedicalLine: Bool = true, metricKeys: [String] = [], unit: String? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.methodName = methodName
        self.version = version
        self.summary = summary
        self.rule = rule
        self.formula = formula
        self.inputs = inputs
        self.references = references
        self.sources = sources
        self.testSuites = testSuites
        self.limits = limits
        self.showsMedicalLine = showsMedicalLine
        self.metricKeys = metricKeys
        self.unit = unit
    }

    /// True when no published paper defines the method: Loopr wrote the rule, perhaps following open-source code.
    public var isLooprOwnMethod: Bool { !references.contains { $0.kind == .paper } }

    /// "Blood age · PhenoAge".
    /// The methods list's one line: the method's name and the first sentence of the summary, never a version id
    /// (ICP R1-OPT-23). "PhenoAge · From 9 blood values and your age."
    public var listLine: String {
        let first = summary.range(of: ". ").map { String(summary[..<$0.lowerBound]) + "." } ?? summary
        return [methodName, first].compactMap { $0 }.joined(separator: " · ")
    }

    public var eyebrow: String {
        [title, methodName].compactMap { $0 }.joined(separator: " · ")
    }
}
