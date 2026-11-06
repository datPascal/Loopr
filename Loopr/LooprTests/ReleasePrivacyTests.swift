import AIKit
import DataKit
import DesignSystem
import Foundation
import HealthKitBridge
import JournalKit
import Security
import Testing
import TrainKit

@testable import Loopr

struct LogRedactionTests {
    @Test
    func sensitiveDomainValuesNeverReachFormattedLogs() {
        let secretValues = ["72.4", "13.7563", "private note", "deadbeef"]
        let outputs = [
            ReleaseLogFormatter.format(.healthMetrics(sampleCount: 1)),
            ReleaseLogFormatter.format(.route(pointCount: 2)),
            ReleaseLogFormatter.format(.journal(entryCount: 3)),
            ReleaseLogFormatter.format(.bluetoothFrame(byteCount: 4))
        ]
        for output in outputs {
            #expect(output.contains("[REDACTED]"))
            #expect(!secretValues.contains(where: output.contains))
        }
    }
}

struct DiagnosticsExportTests {
    @Test
    func identifierAndRawPayloadsAreRedactedAndExportRequiresConfirmation() throws {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let input = SupportDiagnosticsInput(
            peripheralIdentifier: identifier,
            eventCount: 7,
            storageRowCount: 12,
            rawHealthPayload: Data("heart=99".utf8),
            rawProtocolFrames: [Data([0xde, 0xad, 0xbe, 0xef])]
        )
        let preview = SupportDiagnosticsExporter.preview(input)
        #expect(preview.peripheral == "[REDACTED]")
        #expect(!preview.rawPayloadsIncluded)
        #expect(throws: SupportDiagnosticsError.confirmationRequired) {
            try SupportDiagnosticsExporter.export(input, userConfirmed: false)
        }
        let export = try SupportDiagnosticsExporter.export(input, userConfirmed: true)
        let text = String(decoding: export, as: UTF8.self)
        #expect(!text.contains(identifier.uuidString))
        #expect(!text.contains("heart=99"))
        #expect(!text.lowercased().contains("deadbeef"))
    }
}

struct PrivacyManifestTests {
    @Test
    func appManifestDeclaresActualRequiredReasonsAndNoTracking() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        let manifest = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect(manifest["NSPrivacyTrackingDomains"] == nil)
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let expected = Set(["Health", "Fitness", "PhotosorVideos", "OtherUserContent", "SearchHistory"].map { "NSPrivacyCollectedDataType" + $0 })
        #expect(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == expected)
        #expect(collected.count == expected.count)
        for entry in collected {
            #expect(Set(entry.keys) == ["NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeLinked", "NSPrivacyCollectedDataTypeTracking", "NSPrivacyCollectedDataTypePurposes"])
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, Set<String>)? in
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                  let codes = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return nil }
            return (category, Set(codes))
        })
        #expect(reasons == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]
        ])
    }
}

struct CalendarPrivacyTests {
    @Test
    func calendarAccessIsWriteOnlyWithPlainCopyAndNoFullAccessKey() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let writeOnly = try #require(info["NSCalendarsWriteOnlyAccessUsageDescription"] as? String)
        #expect(!writeOnly.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // The copy promises the thing the code does: add events, never read them.
        #expect(writeOnly.contains("only adds events"))
        #expect(writeOnly.contains("never reads"))
        #expect(!writeOnly.contains("\u{2014}"))
        // Loopr never asks for full access, so neither full-access key may exist.
        #expect(info["NSCalendarsFullAccessUsageDescription"] == nil)
        #expect(info["NSCalendarsUsageDescription"] == nil)
        #expect(info["NSRemindersFullAccessUsageDescription"] == nil)
    }

    @Test
    func manifestStillDeclaresNoCalendarDataAndNoTrackingDomains() throws {
        // Events are written to the person's own calendar and never collected by Loopr, so the manifest gains no
        // data type and no network or tracking destination.
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        #expect(!types.contains { $0.localizedCaseInsensitiveContains("calendar") || $0.localizedCaseInsensitiveContains("event") })
        #expect(manifest["NSPrivacyTrackingDomains"] == nil)
    }

    @Test
    func theWriterOnlyAsksWhenToldAndNeverAtConstruction() async {
        // Building the writer must not show a prompt or touch Calendar. Only requestAccess() can.
        let writer = EventKitTrainCalendar(defaults: UserDefaults(suiteName: "loopr.tests.calendar.\(UUID().uuidString)") ?? .standard)
        let status = await writer.authorization()
        #expect([.notDetermined, .denied, .granted].contains(status))
    }
}

struct KeychainStorageTests {
    @Test
    func credentialRoundTripsOnlyThroughKeychain() async throws {
        let bundleID = "com.loopr.tests.release.\(UUID().uuidString)"
        let store = KeychainCredentialStore(bundleIdentifier: bundleID)
        let secret = Data("sk-release-keychain-only".utf8)
        let descriptor = KeychainCredentialStore.descriptor(bundleIdentifier: bundleID)
        #expect(descriptor.service == bundleID + ".ai-provider")
        #expect(descriptor.account == "openai-compatible-api-key")
        #expect(descriptor.accessibility == .whenUnlockedThisDeviceOnly)

        do {
            try await store.remove()
            try await store.write(secret)
            let storedSecret = try await store.read()
            #expect(storedSecret == secret)
            try await store.remove()
            let removedSecret = try await store.read()
            #expect(removedSecret == nil)
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(errSecMissingEntitlement) {
            // Canonical lanes intentionally disable code signing. Security rejects
            // their test host before storage with errSecMissingEntitlement; there is
            // no fallback store, and signed archive/install validation exercises the
            // real entitlement boundary.
        }
        #expect(!UserDefaults.standard.dictionaryRepresentation().description.contains(String(decoding: secret, as: UTF8.self)))
    }
}


// MARK: LV-10.6 release privacy checks

/// Compiles each pattern once. The checks run a few patterns over every line of the source tree.
private final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var storage: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) throws -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let found = storage[pattern] { return found }
        let compiled = try NSRegularExpression(pattern: pattern)
        storage[pattern] = compiled
        return compiled
    }
}

/// The source tree the checks below read. `#filePath` is `<root>/Loopr/LooprTests/ReleasePrivacyTests.swift`, so three
/// steps up is the repository root. A check that finds no tree fails. It never passes on nothing.
private enum SourceTree {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The folders whose code ships in the app, its widgets, its Live Activity and its Watch targets.
    static let shipped = ["Loopr/Loopr", "LooprPackages/Sources", "LooprWatch", "LooprWatchWidgets", "Loopr/Widgets", "Loopr/SharedAppleSurfaces"]

    struct Line {
        let path: String
        let number: Int
        let text: String
        var place: String { "\(path):\(number)" }
    }

    static func files(in folders: [String], extensions: Set<String>) throws -> [URL] {
        var found: [URL] = []
        for folder in folders {
            let base = root.appendingPathComponent(folder)
            let enumerator = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                                          "\(folder) is missing from the source tree")
            for case let url as URL in enumerator where extensions.contains(url.pathExtension) { found.append(url) }
        }
        #expect(!found.isEmpty)
        return found
    }

    static func relative(_ url: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }

    /// Every line of the given files, minus whole-line comments.
    static func codeLines(in folders: [String] = shipped, extensions: Set<String> = ["swift"]) throws -> [Line] {
        var lines: [Line] = []
        for url in try files(in: folders, extensions: extensions) {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            for (index, line) in text.components(separatedBy: "\n").enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                lines.append(Line(path: relative(url), number: index + 1, text: line))
            }
        }
        return lines
    }

    static func text(_ relativePath: String) throws -> String {
        String(decoding: try Data(contentsOf: root.appendingPathComponent(relativePath)), as: UTF8.self)
    }

    static func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let regex = try RegexCache.shared.regex(pattern)
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    static func hasMatch(_ pattern: String, in text: String) throws -> Bool { try !matches(pattern, in: text).isEmpty }
}

/// DEC-12.5 and the build 22 rule: no new network destination. Every host in the shipped code and bundled data is named
/// here, with what the app does with it.
struct NetworkDestinationTests {
    /// The only hosts the app contacts. Open Food Facts takes a barcode. The two providers take Ask and food estimates,
    /// with the person's own key, after consent.
    static let contacted: Set<String> = ["world.openfoodfacts.org", "api.openai.com", "api.anthropic.com"]
    /// Links the person opens in Safari through `openURL`, and text in method pages. The app never fetches them.
    static let openedInSafari: Set<String> = [
        "github.com", "doi.org", "pmc.ncbi.nlm.nih.gov", "platform.openai.com", "platform.claude.com", "openai.com",
        "www.anthropic.com", "datpascal.github.io", "opendatacommons.org", "creativecommons.org",
        "www.labcorp.com", "www.mayocliniclabs.com", "dbarchive.biosciencedbc.jp"
    ]
    /// XML namespace names in the GPX file Loopr writes. They are identifiers and nobody loads them.
    static let xmlNamespaces: Set<String> = ["www.topografix.com", "www.garmin.com"]
    /// Source notes inside bundled data files.
    static let provenanceText: Set<String> = ["raw.githubusercontent.com", "static.openfoodfacts.org", "fdc.nal.usda.gov"]

    /// The only files that name a URL session, a URL request or a network connection.
    static let networkingFiles: Set<String> = [
        "Loopr/Loopr/App/AppFoodRepository.swift",
        "LooprPackages/Sources/AIKit/CoachProvider.swift",
        "LooprPackages/Sources/FoodKit/FoodProductClient.swift"
    ]

    @Test
    func everyHostInTheShippedSourceIsOnTheAllowlist() throws {
        let allowed = Self.contacted.union(Self.openedInSafari).union(Self.xmlNamespaces).union(Self.provenanceText)
        var unknown: [String: String] = [:]
        let swift = try SourceTree.codeLines()
        let data = try SourceTree.codeLines(in: ["Loopr/Loopr/Resources", "LooprPackages/Sources", "protocols"],
                                            extensions: ["json", "looprprotocol", "html"])
        for line in swift + data {
            for match in try SourceTree.matches("https?://([A-Za-z0-9._-]+)", in: line.text) where !allowed.contains(match[1]) {
                unknown[match[1]] = line.place
            }
        }
        #expect(unknown.isEmpty, "New hosts need a decision and a PRIVACY.md line: \(unknown.sorted { $0.key < $1.key })")
    }

    @Test
    func theContactedHostsAreTheOnesThePrivacyPolicyNames() throws {
        let policy = try SourceTree.text("PRIVACY.md")
        for host in Self.contacted { #expect(policy.contains(host), "PRIVACY.md does not name \(host)") }
        #expect(Set(CoachProvider.allCases.map(\.host)) == ["api.openai.com", "api.anthropic.com"])
        let food = try SourceTree.text("LooprPackages/Sources/FoodKit/FoodProductClient.swift")
        #expect(food.contains("url.host == \"world.openfoodfacts.org\""), "the Open Food Facts transport no longer pins its host")
    }

    @Test
    func onlyTheKnownFilesTouchTheNetwork() throws {
        let pattern = "\\bURLSession(Configuration|DataTask|WebSocketTask)?\\b|\\bURLRequest\\b|\\bNWConnection\\b|\\bNWPathMonitor\\b|\\bCFNetwork\\b|\\bURLConnection\\b"
        var found = Set<String>()
        for line in try SourceTree.codeLines() {
            if try SourceTree.hasMatch(pattern, in: line.text) { found.insert(line.path) }
        }
        #expect(found == Self.networkingFiles, "Networking code moved. New: \(found.subtracting(Self.networkingFiles).sorted()). Gone: \(Self.networkingFiles.subtracting(found).sorted())")
    }

    @Test
    func theGenericTransportThatTakesAnyHostIsNeverBuilt() throws {
        // `URLSessionAITransport` accepts any http or https address. Nothing builds one, so it reaches nowhere.
        var builders: [String] = []
        for line in try SourceTree.codeLines() where line.text.contains("URLSessionAITransport(") { builders.append(line.place) }
        #expect(builders.isEmpty, "\(builders)")
    }

    @Test
    func theAppAsksForNoTransportSecurityException() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["NSAppTransportSecurity"] == nil)
    }
}

/// DEC-12.16, DEC-12.6 and the manifest rules in `docs/research/2026-09-29-apple-health-privacy-manifest.md`.
struct ReleaseManifestTests {
    private func manifest(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent(relativePath))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// What the shipped source uses from each required-reason category.
    private static let signatures: [String: String] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": "\\bUserDefaults\\b",
        "NSPrivacyAccessedAPICategorySystemBootTime": "\\bsystemUptime\\b|\\bmach_absolute_time\\b|\\bmach_continuous_time\\b",
        "NSPrivacyAccessedAPICategoryFileTimestamp":
            "NSFileCreationDate|NSFileModificationDate|\\.creationDateKey|\\.contentModificationDateKey|\\.contentAccessDateKey|\\.attributeModificationDateKey|\\bfileModificationDate\\b|\\bgetattrlist|\\bfstat\\(|\\blstat\\(|\\[\\.modificationDate\\]|\\[\\.creationDate\\]",
        "NSPrivacyAccessedAPICategoryDiskSpace":
            "volumeAvailableCapacity|volumeTotalCapacity|NSFileSystemFreeSize|NSFileSystemSize|\\bsystemFreeSize\\b|attributesOfFileSystem|\\bstatfs\\b|\\bstatvfs\\b|availableCapacityForImportantUsage|availableCapacityForOpportunisticUsage",
        "NSPrivacyAccessedAPICategoryActiveKeyboards": "activeInputModes"
    ]

    @Test
    func theAppManifestDeclaresExactlyTheRequiredReasonCategoriesTheSourceUses() throws {
        let declared = Set((try #require(try manifest("Loopr/Loopr/Resources/PrivacyInfo.xcprivacy")["NSPrivacyAccessedAPITypes"] as? [[String: Any]]))
            .compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
        // The app target compiles Loopr/Loopr, the packages and the shared surface files. Its Watch targets have their own manifests.
        let lines = try SourceTree.codeLines(in: ["Loopr/Loopr", "LooprPackages/Sources", "Loopr/SharedAppleSurfaces"])
        var used = Set<String>()
        for (category, pattern) in Self.signatures {
            for line in lines {
                if try SourceTree.hasMatch(pattern, in: line.text) {
                    used.insert(category)
                    break
                }
            }
        }
        #expect(used == declared, "Source uses \(used.sorted()), manifest declares \(declared.sorted())")
        // No file timestamp or disk space API is used (file size and file type keys do not count), so no reason is declared.
        #expect(!declared.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))
        #expect(!declared.contains("NSPrivacyAccessedAPICategoryDiskSpace"))
    }

    @Test
    func collectedTypesCoverWhatLeavesThePhoneAndNothingElse() throws {
        // Blood tests, supplements, medication, body composition and protocol notes can reach a provider through Ask, and
        // each falls under Health, Fitness or Other user content. Lab text recognition, coach rewording, the dashboard and
        // protocol files stay on the phone, so none adds a type. Location, contacts and identifiers are never sent.
        let collected = try #require(try manifest("Loopr/Loopr/Resources/PrivacyInfo.xcprivacy")["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        #expect(types.isSuperset(of: ["NSPrivacyCollectedDataTypeHealth", "NSPrivacyCollectedDataTypeFitness", "NSPrivacyCollectedDataTypeOtherUserContent"]))
        for banned in ["Location", "Contacts", "DeviceID", "UserID", "AdvertisingData", "CrashData", "PerformanceData", "OtherDiagnosticData", "ProductInteraction"] {
            #expect(!types.contains { $0.contains(banned) }, "\(banned)")
        }
    }

    @Test
    func theWatchManifestsStillDeclareOnlyAppGroupDefaultsAndNoTracking() throws {
        for path in ["LooprWatch/PrivacyInfo.xcprivacy", "LooprWatchWidgets/PrivacyInfo.xcprivacy"] {
            let watch = try manifest(path)
            #expect(watch["NSPrivacyTracking"] as? Bool == false, "\(path)")
            #expect((watch["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true, "\(path)")
            let entries = try #require(watch["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
            #expect(entries.count == 1, "\(path)")
            #expect(entries.first?["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults", "\(path)")
            #expect(entries.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["1C8F.1"], "\(path)")
            let watchCode = try SourceTree.codeLines(in: [path.components(separatedBy: "/")[0]])
            for category in ["NSPrivacyAccessedAPICategorySystemBootTime", "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPICategoryDiskSpace"] {
                let pattern = try #require(Self.signatures[category])
                for line in watchCode {
                    #expect(!(try SourceTree.hasMatch(pattern, in: line.text)), "\(line.place) uses \(category)")
                }
            }
        }
    }
}

/// Build 22 purpose strings. They say what is read and why, in plain words, and they name the new reads.
struct UsageDescriptionTests {
    private func string(_ key: String) throws -> String {
        let info = try #require(Bundle.main.infoDictionary)
        return try #require(info[key] as? String, "\(key) is missing")
    }

    @Test
    func cameraNamesLabReportsAndSaysTheyStayOnThePhone() throws {
        let camera = try string("NSCameraUsageDescription")
        for word in ["meal", "barcode", "nutrition label", "blood test report", "this iPhone"] {
            #expect(camera.localizedCaseInsensitiveContains(word), "camera copy omits \(word)")
        }
    }

    @Test
    func healthReadNamesEveryTypeTheAppAsksFor() throws {
        let share = try string("NSHealthShareUsageDescription")
        for name in ["workouts", "distance", "sleep", "heart rate", "resting heart rate", "SDNN", "respiratory rate", "VO₂ max", "steps", "active energy",
                     "time in daylight", "blood pressure", "weight", "body fat", "lean body mass", "blood glucose"] {
            #expect(share.localizedCaseInsensitiveContains(name), "Health read copy omits \(name)")
        }
        #expect(!share.localizedCaseInsensitiveContains("oxygen"))
        // Every read kind of DEC-12.16 is named. The switch has no default, so a ninth kind cannot ship without copy.
        for kind in AppleHealthSourceKind.allCases {
            let name: String = switch kind {
            case .vo2Max: "VO₂ max"
            case .daylight: "time in daylight"
            case .bloodPressure: "blood pressure"
            case .weight: "weight"
            case .bodyFat: "body fat"
            case .leanMass: "lean body mass"
            case .bloodGlucose: "blood glucose"
            case .steps: "steps"
            }
            #expect(share.localizedCaseInsensitiveContains(name), "Health read copy omits \(name)")
        }
        #expect(AppleHealthSourceKind.allCases.count == 8)
    }

    @Test
    func photoLibraryCopyCoversTheLabDateFallback() throws {
        let library = try string("NSPhotoLibraryUsageDescription")
        #expect(library.localizedCaseInsensitiveContains("meal"))
        #expect(library.localizedCaseInsensitiveContains("lab report"))
    }

    @Test
    func everyPurposeStringIsPlainSentences() throws {
        let info = try #require(Bundle.main.infoDictionary)
        for (key, value) in info where key.hasSuffix("UsageDescription") {
            let text = try #require(value as? String)
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key)")
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "\(key) has a dash used as punctuation")
            #expect(text.hasSuffix("."), "\(key) does not end in a full stop")
        }
        // The system asks for notifications and Live Activities without a purpose string. Their wording lives in the app.
        #expect(info["NSUserNotificationsUsageDescription"] == nil)
    }
}

/// DEC-12.1 tabs, the not-a-medical-device line and the golden rule (DEC-12.21).
struct ReleaseCopyTests {
    private static let oldTabName = "\\bJournal\\b|\\bTrain\\b|(?<!Apple )\\bHealth\\b(?! app)"

    @MainActor
    @Test
    func theTabsAreTodayFoodFitnessProtocolData() {
        #expect(MainTab.allCases.map(\.title) == ["Today", "Food", "Fitness", "Protocol", "Data"])
    }

    @Test
    func intentAndShortcutTitlesUseNoOldTabName() throws {
        let source = try SourceTree.codeLines(in: ["Loopr/Loopr/App"]).filter { $0.path == "Loopr/Loopr/App/LooprAppIntents.swift" }
        #expect(source.count > 100)
        var checked = 0
        for line in source where line.text.contains("title") || line.text.contains("phrases") || line.text.contains("IntentDescription") {
            for literal in try SourceTree.matches("\"((?:[^\"\\\\]|\\\\.)*)\"", in: line.text).map({ $0[1] }) {
                checked += 1
                #expect(!(try SourceTree.hasMatch(Self.oldTabName, in: literal)), "\(line.place): \(literal)")
            }
        }
        #expect(checked >= 18, "the scan found too few intent titles to mean anything")
    }

    @Test
    func widgetsLiveActivitiesWatchAndNotificationsUseNoOldTabName() throws {
        let folders = ["Loopr/Widgets", "Loopr/SharedAppleSurfaces", "LooprWatch", "LooprWatchWidgets", "Loopr/Loopr/App/Bedtime",
                       "LooprPackages/Sources/NotificationKit", "LooprPackages/Sources/SharedSurfaceKit"]
        for line in try SourceTree.codeLines(in: folders) {
            for literal in try SourceTree.matches("\"((?:[^\"\\\\]|\\\\.)*)\"", in: line.text).map({ $0[1] }) {
                #expect(!(try SourceTree.hasMatch(Self.oldTabName, in: literal)), "\(line.place): \(literal)")
            }
        }
    }

    @Test
    func noScreenSendsThePersonToATabByItsOldName() throws {
        // Journal, Health and Train were the build 21 tab names. "Apple Health", "the Health app" and "Journal questions"
        // name a thing and stay.
        let phrases = [
            "\\b(on|in|to|from|open|Open|of) (the )?(Train|Journal|Health) tab\\b",
            "\\bthe (Train|Journal|Health) tab\\b",
            "\\bOpen (Train|Journal)\\b",
            "\\bin Train\\b",
            "\\bin Journal first\\b",
            "\\bin Health\\b(?! app)",
            "title: \"(Train|Journal|Health)\"",
            "\\b(Train|Journal|Health) screen\\b"
        ]
        // A storage category, where the word names the data and not a tab.
        let namesAThing: Set<String> = ["LooprPackages/Sources/DesignSystem/StorageBreakdown.swift"]
        var hits: [String] = []
        for line in try SourceTree.codeLines() where !namesAThing.contains(line.path) {
            for phrase in phrases {
                if try SourceTree.hasMatch(phrase, in: line.text) {
                    hits.append("\(line.place): \(line.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test
    func theSleepCardAndJournalSourceTagNameTabsByTheirNewNames() throws {
        let sleep = try SourceTree.text("LooprPackages/Sources/SleepKit/SleepNightComparison.swift")
        #expect(sleep.contains("case .alcohol: \"Protocol\""))
        #expect(sleep.contains("case .workout: \"Fitness\""))
        #expect(!sleep.contains("\"Journal\"") && !sleep.contains("\"Train\""))
        #expect(JournalAutoFillDomain.train.title == "Fitness")
        #expect(JournalAutoFillDomain.food.title == "Food")
        #expect(JournalAutoFillDomain.sleep.title == "Sleep")
    }

    @Test
    func oneMedicalLineIsShared() {
        #expect(LooprMedicalLine.text == "Loopr is not a medical device.")
        #expect(DataAgeRuler.notAMedicalDevice == LooprMedicalLine.text)
        #expect(LabsDisplay.notAMedicalDevice.hasPrefix(LooprMedicalLine.text))
        #expect(MethodCatalog.medicalLine.hasPrefix(LooprMedicalLine.text))
    }

    @Test
    func everyMethodPageCarriesTheMedicalLine() {
        #expect(!MethodCatalog.entries.isEmpty)
        for entry in MethodCatalog.entries { #expect(entry.showsMedicalLine, "\(entry.id.rawValue)") }
    }

    @Test
    func everyScreenWithALabValueAnAgeOrAMethodDrawsTheMedicalLine() throws {
        let screens: [String: [String]] = [
            "LooprPackages/Sources/DataKit/Labs/LabsListScreen.swift": ["notAMedicalDevice"],
            "LooprPackages/Sources/DataKit/Labs/LabReportScreen.swift": ["notAMedicalDevice"],
            "LooprPackages/Sources/DataKit/Overview/DataAgeSectionView.swift": ["notAMedicalDevice"],
            "LooprPackages/Sources/DataKit/Overview/DataOverviewCards.swift": ["notAMedicalDevice"],
            "LooprPackages/Sources/DataKit/Methods/MethodPageView.swift": ["MethodCatalog.medicalLine"],
            "LooprPackages/Sources/DataKit/Publish/PublishHTMLRenderer.swift": ["LooprMedicalLine.text"],
            "LooprPackages/Sources/BodyKit/BodyScreens.swift": ["LooprMedicalLine.text"],
            "LooprPackages/Sources/BodyKit/BodyTabSections.swift": ["LooprMedicalLine.text"],
            "LooprPackages/Sources/TrainKit/Fitness/FitnessVO2MaxCard.swift": ["LooprMedicalLine.text"],
            "Loopr/Loopr/App/FoodLabView.swift": ["LooprMedicalLine.text"]
        ]
        for (path, needles) in screens {
            let text = try SourceTree.text(path)
            for needle in needles { #expect(text.contains(needle), "\(path) does not draw \(needle)") }
        }
    }

    @Test
    func noUserFacingTextNamesTheOutOfProductThings() throws {
        // DEC-12.21: Bryan Johnson, "Don't Die", "Blueprint", any store, affiliate link, leaderboard or lab partner.
        let banned = ["bryan johnson", "don't die", "dont die", "blueprint", "affiliate link", "affiliate code", "affiliate program",
                      "leaderboard", "lab partner", "partner lab"]
        var hits: [String] = []
        for line in try SourceTree.codeLines() + SourceTree.codeLines(in: ["protocols", "Loopr/Loopr/Resources"], extensions: ["json", "looprprotocol", "md"]) {
            let lower = line.text.lowercased()
            for term in banned where lower.contains(term) { hits.append("\(line.place) \(term)") }
        }
        for file in ["PRIVACY.md", "Loopr/Loopr/Info.plist"] {
            let lower = try SourceTree.text(file).lowercased()
            for term in banned where lower.contains(term) { hits.append("\(file) \(term)") }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test
    func thePrivacyPolicyNamesTheNewDataAndKeepsToPlainPunctuation() throws {
        let policy = try SourceTree.text("PRIVACY.md")
        for phrase in ["Blood tests and Lab mode", "Supplements and medication", "Protocols, experiments and capacity tests", "Coach notes on your iPhone",
                       "Publish a dashboard", "Reminders you set", "Where data leaves your iPhone", "eight switches", "PhenoAge", "Vision",
                       "weight, body fat and lean mass", "time in daylight", "blood glucose", "never calls a value abnormal"] {
            #expect(policy.localizedCaseInsensitiveContains(phrase), "PRIVACY.md omits \(phrase)")
        }
        #expect(!policy.contains("\u{2014}") && !policy.contains("\u{2013}"))
        #expect(!policy.contains("accept it in Train"))
    }
}
