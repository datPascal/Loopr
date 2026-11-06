import Foundation
import RoutineKit
import StorageKit
import Testing

struct ProtocolTemplateTests {
    private func rules(_ template: ProtocolTemplate) throws -> [ProtocolRule] { try template.load().file.rules }

    @Test func theFiveTemplatesLoadAndValidate() throws {
        #expect(ProtocolTemplate.allCases.map(\.title) == ["A gentle start", "Sleep first", "Fitness for the long run", "Everything at once",
                                                          "Start empty"])
        for template in ProtocolTemplate.allCases {
            let preview = try template.load()
            #expect(preview.file.name == template.title && preview.file.version == 1 && preview.ignoredFields.isEmpty, "\(template)")
            #expect(preview.file.author == nil && preview.file.lineage == nil && preview.file.experiments.isEmpty)
            #expect(template.fileName.hasSuffix(".looprprotocol"))
            // Saving a template again gives the same file, so the bundled files are already in canonical form.
            #expect(try ProtocolFileCodec.validate(try ProtocolFileCodec.encode(preview.file)).file == preview.file)
        }
        #expect(try ProtocolTemplate.allCases.map { try rules($0).count } == [3, 6, 6, 12, 0])
    }

    /// ICP R2-NEW-07, R2-DES-02, R2-SEN-05: every rule in every template says why it is there in one plain sentence of
    /// at most 16 words, so no screen has to cut it short, and keeps its source apart in `evidence`. The plain
    /// punctuation of the rest of the app holds for both.
    @Test func everyTemplateRuleHasAShortWhyAndASource() throws {
        for template in ProtocolTemplate.allCases {
            for rule in try rules(template) {
                let key = rule.key.rawValue
                let why = try #require(rule.why, "\(template) \(key) has no why")
                #expect(why.hasSuffix(".") && !why.dropLast().contains("."), "\(key): one sentence")
                #expect(why.split(separator: " ").count <= 16, "\(key): \(why.split(separator: " ").count) words")
                let evidence = try #require(rule.evidence, "\(template) \(key) has no evidence")
                #expect(!evidence.isEmpty && evidence.count <= ProtocolFile.maximumEvidenceLength && evidence.hasSuffix("."), "\(key)")
                for text in [why, evidence] {
                    for mark in ["\u{2014}", "\u{2013}", "(", ")", ";", "!", "\u{201C}", "\u{201D}", "optimal", "best", "should"] {
                        #expect(!text.lowercased().contains(mark), "\(key) contains \(mark)")
                    }
                }
            }
        }
    }

    /// ICP R2-VET-05: a template's why never names the rule's own number, so it does not argue with a person who
    /// changed the target, and it never says the rule matches another setting that can change.
    @Test func aTemplateWhyNeverArguesWithTheTarget() throws {
        for template in ProtocolTemplate.allCases {
            for rule in try rules(template) {
                let why = try #require(rule.why)
                #expect(!why.contains("matches your"), "\(rule.key.rawValue)")
                if let value = rule.target.value, rule.target.metric.flatMap(RoutineMetric.init(rawValue:))?.isTimeOfDay != true {
                    let amount = value.rounded() == value ? String(Int(value)) : String(value)
                    let words = why.replacingOccurrences(of: ",", with: "").split(separator: " ").map(String.init)
                    #expect(!words.contains(amount), "\(rule.key.rawValue) names its number \(amount)")
                }
                #expect(!why.contains(":"), "\(rule.key.rawValue) names a clock time")
            }
        }
    }

    /// ICP R2-NEW-07: the drink rule is kind. It speaks of sleep and leaves the warnings to its source.
    @Test func theDrinkRuleIsKind() throws {
        for template in [ProtocolTemplate.gentleStart, .everythingAtOnce] {
            let alcohol = try #require(try rules(template).first { $0.key == "alcohol" })
            #expect(alcohol.why == "Fewer drinks usually means better sleep.")
            #expect(alcohol.evidence?.contains("WHO") == true, "the warning stays in the source")
        }
    }

    /// ICP R3-NEW-05: the steps rule's source gives both age bands from Paluch et al. 2022, so a 34-year-old reading
    /// "Walk 6,000 steps" learns that the benefit levelled off later for them.
    @Test func theStepsEvidenceNamesBothAgeBands() throws {
        for template in [ProtocolTemplate.gentleStart, .everythingAtOnce] {
            let steps = try #require(try rules(template).first { $0.key == "steps" })
            let evidence = try #require(steps.evidence)
            #expect(evidence.contains("6,000 to 8,000 steps a day for adults 60 and over"), "\(template)")
            #expect(evidence.contains("For adults under 60 it levelled off later, at about 8,000 to 10,000."), "\(template)")
        }
    }

    /// The same rule in two templates gives the same reason.
    @Test func aRuleSharedBetweenTemplatesHasOneWhy() throws {
        var seen: [RuleKey: String] = [:]
        for template in ProtocolTemplate.allCases {
            for rule in try rules(template) {
                guard let why = rule.why else { continue }
                if let earlier = seen[rule.key] { #expect(earlier == why, "\(rule.key.rawValue)") }
                seen[rule.key] = why
            }
        }
    }

    /// ICP R1-SEN-14: a beginner's list of three, checked by the band and Apple Health where they can, with one tick.
    @Test func aGentleStartHasThreeRulesTwoOfThemCheckedForThePerson() throws {
        #expect(ProtocolTemplate.recommended == .gentleStart && ProtocolTemplate.gentleStart.title == "A gentle start")
        let all = try Dictionary(uniqueKeysWithValues: rules(.gentleStart).map { ($0.key.rawValue, $0) })
        #expect(Set(all.keys) == ["in-bed", "steps", "alcohol"])
        let sleep = try rules(.sleepFirst).first { $0.key == "in-bed" }
        #expect(all["in-bed"]?.target == sleep?.target && all["in-bed"]?.source == .band && all["in-bed"]?.isEvening == true)
        #expect(all["steps"]?.target == RuleTarget(kind: .atLeast, metric: "steps", value: 6_000, unit: "steps"))
        #expect(all["steps"]?.source == .appleHealth && all["steps"]?.cadence == nil)
        #expect(all["alcohol"]?.source == .manual && all["alcohol"]?.target.kind == .done && all["alcohol"]?.isEvening == true)
        #expect(try rules(.gentleStart).filter { $0.source == .manual }.count == 1, "the first evening asks one question")
    }

    @Test func everyTemplateRuleIsUniqueAndUsesTheVocabulary() throws {
        for template in ProtocolTemplate.allCases {
            let all = try rules(template)
            #expect(Set(all.map(\.key)).count == all.count, "\(template)")
            for rule in all where rule.source != .manual {
                let metric = try #require(rule.target.metric.flatMap(RoutineMetric.init(rawValue:)), "\(template) \(rule.key.rawValue)")
                #expect(metric.source == rule.source)
            }
        }
    }

    @Test func sleepFirstHasTheSixSleepRules() throws {
        let all = try Dictionary(uniqueKeysWithValues: rules(.sleepFirst).map { ($0.key.rawValue, $0) })
        #expect(Set(all.keys) == ["in-bed", "screens-off", "kitchen-closes", "no-late-caffeine", "daylight", "track-sleep-hr"])
        let inBed = try #require(all["in-bed"]), kitchen = try #require(all["kitchen-closes"])
        #expect(inBed.target == RuleTarget(kind: .atMost, metric: "in_bed_time", value: 1_350, unit: "min") && inBed.source == .band && inBed.isEvening)
        // The kitchen closes between 3 and 4 hours before the bed time.
        let gap = try #require(inBed.target.value) - #require(kitchen.target.value)
        #expect((180...240).contains(gap) && kitchen.target.metric == "last_meal_time" && kitchen.source == .food)
        #expect(all["no-late-caffeine"]?.target == RuleTarget(kind: .atMost, metric: "last_caffeine_time", value: 840, unit: "min"))
        #expect(all["screens-off"]?.source == .manual && all["screens-off"]?.target.kind == .done)
        #expect(all["daylight"]?.source == .appleHealth && all["daylight"]?.target.metric == "daylight_minutes")
        #expect(all["track-sleep-hr"]?.target.metric == "sleep_hr" && all["track-sleep-hr"]?.target.kind == .done)
    }

    @Test func fitnessForTheLongRunHasWeeklyTargetsAndMonthlyRetests() throws {
        let all = try Dictionary(uniqueKeysWithValues: rules(.fitnessForTheLongRun).map { ($0.key.rawValue, $0) })
        let zone2 = try #require(all["zone-2"])
        #expect(zone2.target.metric == "zone2_minutes" && zone2.target.value == 150 && zone2.cadence == RuleCadence(unit: .week))
        #expect(all["strength"]?.target.value == 2 && all["strength"]?.cadence == RuleCadence(unit: .week))
        #expect(all["hard-minutes"]?.target.metric == "zone45_minutes" && all["mobility"]?.target.metric == "mobility_sessions")
        for key in ["grip-retest", "balance-retest"] {
            let retest = try #require(all[key])
            #expect(retest.group == .tests && retest.source == .manual && retest.cadence == RuleCadence(unit: .month, every: 1), "\(key)")
        }
    }

    @Test func everythingAtOnceCoversEveryGroupAndTestsBloodEverySixMonths() throws {
        let all = try rules(.everythingAtOnce)
        #expect(Set(all.map(\.group)) == [.sleep, .food, .fitness, .supplements, .tests])
        let blood = try #require(all.first { $0.key == "blood-test" })
        #expect(blood.group == .tests && blood.cadence == RuleCadence(unit: .month, every: 6) && blood.source == .manual)
        #expect(all.first { $0.key == "alcohol" }?.target == RuleTarget(kind: .atMost, metric: "alcohol_drinks", value: 1, unit: "drinks"))
        #expect(all.first { $0.key == "supplements" }?.group == .supplements)
    }

    @Test func startEmptyHasNoRulesAndImportsAsAnEmptyProtocol() throws {
        let preview = try ProtocolTemplate.startEmpty.load()
        #expect(preview.file.rules.isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "template-tests")
        defer { try? database.databasePool.close() }
        let store = RoutineStore(database: database)
        let imported = try store.importFile(preview, at: Date(timeIntervalSince1970: 1_790_000_000), activate: true)
        #expect(try store.activeProtocol()?.routineProtocol.id == imported.id && store.latestVersion(protocolID: imported.id)?.rules.isEmpty == true)
    }

    @Test func everyTemplateImportsAsAForkOfItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "template-tests")
        defer { try? database.databasePool.close() }
        let store = RoutineStore(database: database)
        for (index, template) in ProtocolTemplate.allCases.enumerated() {
            let preview = try template.load()
            let imported = try store.importFile(preview, at: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))
            #expect(imported.lineage == ProtocolLineage(forkedFromName: template.title, forkedFromVersion: 1))
            #expect(try store.latestVersion(protocolID: imported.id)?.rules == preview.file.rules)
        }
        #expect(try store.protocols().count == ProtocolTemplate.allCases.count && store.activeProtocol() == nil, "templates never take over the active protocol")
    }

    @Test func templateWordsAreShortSentenceCaseAndFreeOfNamesAndBrands() throws {
        let banned = ["blueprint", "don't die", "dont die", "bryan", "johnson", "whoop", "!", "\u{2014}", "\u{2013}"]
        for template in ProtocolTemplate.allCases {
            let text = try #require(String(data: try template.data(), encoding: .utf8)).lowercased()
            for word in banned { #expect(!text.contains(word), "\(template) contains \(word)") }
            for rule in try rules(template) {
                let title = rule.title
                // Sentence case: the first letter is a capital, or the title starts with a number.
                let first = try #require(title.first)
                #expect(first.isUppercase || first.isNumber, "\(title)")
                #expect(title.count <= 40, "\(title)")
                // Sentence case: no word after the first starts with a capital, apart from "Zone" style proper names we do not use.
                let later = title.split(separator: " ").dropFirst()
                #expect(later.allSatisfy { $0.first?.isUppercase != true }, "\(title)")
                #expect(!title.hasSuffix(".") && !title.contains("  "))
            }
        }
    }
}
