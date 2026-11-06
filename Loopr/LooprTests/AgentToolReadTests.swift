import AIKit
import Foundation
import Testing
@testable import Loopr

/// What the read tools return: only the records that exist, in a form the model can quote, with sources and charts
/// built from those same records.
@Suite(.serialized)
struct AgentToolReadTests {
    private let suite: AgentFixtures.Suite = { let s = AgentFixtures.Suite(); s.setOnly(Set(AgentDataDomain.allCases)); return s }()
    private let source = FakeAgentSource()
    private let session = AgentToolSession()

    private func executor(consent: CoachSharing = AgentFixtures.everything) -> AgentToolExecutor {
        AgentToolExecutor(readers: AgentReaders(gate: AgentAccessGate(consent: consent, defaults: suite.defaults), source: source),
                          proposals: nil, maker: nil, session: session, conversationID: UUID(), messageID: UUID(),
                          now: AgentFixtures.now, timeZone: AgentFixtures.zone)
    }
    private func run(_ name: String, _ arguments: [String: Any] = [:]) async -> AgentToolOutcome {
        await executor().execute(AgentFixtures.call(name, arguments))
    }
    private func object(_ outcome: AgentToolOutcome) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(outcome.content.utf8)) as? [String: Any])
    }

    // MARK: The day Ask was opened from

    private func executor(selectedDay: String?) -> AgentToolExecutor {
        AgentToolExecutor(readers: AgentReaders(gate: AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: source),
                          proposals: nil, maker: nil, session: session, conversationID: UUID(), messageID: UUID(),
                          now: AgentFixtures.now, timeZone: AgentFixtures.zone, selectedDay: selectedDay)
    }

    @Test func aRangeWithNoEndEndsOnTheDayAskWasOpenedFrom() async throws {
        let past = try object(await executor(selectedDay: "2026-10-12").execute(AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"]])))
        #expect(past["to"] as? String == "2026-10-12", "a chat opened on 12 Oct reads up to that day, not 16 Oct")
        #expect(past["from"] as? String == "2026-09-29")
        let today = try object(await executor(selectedDay: nil).execute(AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"]])))
        #expect(today["to"] as? String == AgentFixtures.today)
    }

    @Test func aChatOpenedOnTodayOrWithAnUnusableDayStillEndsToday() async throws {
        for day in [AgentFixtures.today, "2026-10-17", "Fri 16 Oct", ""] {
            let json = try object(await executor(selectedDay: day).execute(AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"]])))
            #expect(json["to"] as? String == AgentFixtures.today, "\(day)")
        }
    }

    @Test func anExplicitEndWinsOverTheDayAskWasOpenedFrom() async throws {
        let json = try object(await executor(selectedDay: "2026-10-12").execute(
            AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"])))
        #expect(json["to"] as? String == "2026-10-14", "the night before the selected day is still readable, and so is a day after it")
        let later = await executor(selectedDay: "2026-10-12").execute(AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"], "to": "2026-10-20"]))
        #expect(later.isError, "nothing after today can be read")
    }

    @Test func theInstructionNamesThePastDayOnlyWhenThereIsOne() {
        let gate = AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults)
        let past = gate.instructionNote(today: AgentFixtures.today, timeZone: AgentFixtures.zone, selectedDay: "2026-10-12")
        #expect(past.contains("Today is 2026-10-16"))
        #expect(past.contains("opened this chat from the screen for 2026-10-12, a past day"))
        #expect(past.contains("ends on 2026-10-12, not today"))
        let live = gate.instructionNote(today: AgentFixtures.today, timeZone: AgentFixtures.zone)
        #expect(!live.contains("past day"))
        #expect(live == gate.instructionNote(today: AgentFixtures.today, timeZone: AgentFixtures.zone, selectedDay: nil))
    }

    // MARK: Metrics and charts

    @Test func metricsComeBackAsDatedPointsWithTheirUnit() async throws {
        let outcome = await run(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"])
        #expect(!outcome.isError)
        let json = try object(outcome)
        let series = try #require((json["series"] as? [String: Any])?["rmssd"] as? [String: Any])
        #expect(series["unit"] as? String == "ms")
        let points = try #require(series["points"] as? [[Any]])
        #expect(points.count == 14 && points[0][0] as? String == "2026-10-01" && points[0][1] as? Double == 51)
        #expect((json["note"] as? String)?.contains("unknown, not zero") == true)
    }

    @Test func aMetricWithNoReadingsIsNamedNotInventedAsZero() async throws {
        let json = try object(await run(AgentToolName.getMetrics, ["metrics": ["rmssd", "steps"], "from": "2026-10-01", "to": "2026-10-14"]))
        #expect(json["noReadings"] as? [String] == ["steps"])
        #expect((json["series"] as? [String: Any])?["steps"] == nil)
    }

    @Test func theChartIsDrawnFromTheReadValuesNotFromAnythingTheModelSays() async throws {
        let read = try object(await run(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"]))
        let charts = try #require(read["charts"] as? [[String: Any]])
        let id = try #require(charts.first?["chartId"] as? String)
        #expect(id == "metric.rmssd.2026-10-01.2026-10-14")

        let shown = await run(AgentToolName.showChart, ["chartId": id, "title": "Ignore this", "values": [1, 2, 3]])
        #expect(!shown.isError)
        let artifacts = await session.artifacts
        let chart = try #require(artifacts.charts.first)
        let expected = try await source.metricSeries(.rmssd, from: "2026-10-01", to: "2026-10-14").map { AgentChartPoint(day: $0.day, value: $0.value) }
        #expect(chart.points == expected && chart.unit == "ms" && chart.title == "Heart rate variability" && chart.domain == .metrics)
    }

    @Test func aChartThatWasNeverOfferedCanNotBeShown() async {
        let outcome = await run(AgentToolName.showChart, ["chartId": "metric.rmssd.2026-10-01.2026-10-14"])
        #expect(outcome.isError && outcome.content.contains("No chart has that id"))
        #expect(await session.artifacts.charts.isEmpty)
    }

    @Test func onlyThreeChartsFitUnderOneAnswer() async throws {
        _ = await run(AgentToolName.getMetrics, ["metrics": ["rmssd", "sleep_duration"], "from": "2026-10-01", "to": "2026-10-14"])
        _ = await run(AgentToolName.getFood, ["from": "2026-10-10", "to": "2026-10-16"])
        let ids = ["metric.rmssd.2026-10-01.2026-10-14", "metric.sleep_duration.2026-10-01.2026-10-14", "food.energy.2026-10-10.2026-10-16"]
        for id in ids { #expect(!(await run(AgentToolName.showChart, ["chartId": id])).isError, "\(id)") }
        _ = await run(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-02", "to": "2026-10-14"])
        let fourth = await run(AgentToolName.showChart, ["chartId": "metric.rmssd.2026-10-02.2026-10-14"])
        #expect(fourth.isError && fourth.content.contains("3 charts"))
        #expect(await session.artifacts.charts.count == 3)
    }

    @Test func aChartIsRefusedIfItsDomainWasTurnedOffAfterTheRead() async throws {
        _ = await run(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"])
        suite.set(.metrics, false)
        let outcome = await run(AgentToolName.showChart, ["chartId": "metric.rmssd.2026-10-01.2026-10-14"])
        #expect(outcome.denied)
        #expect(await session.artifacts.charts.isEmpty)
    }

    @Test func sourcesListOnlyWhatWasReturned() async throws {
        _ = await run(AgentToolName.getMetrics, ["metrics": ["rmssd", "steps"], "from": "2026-10-01", "to": "2026-10-14"])
        let sources = await session.artifacts.sources
        #expect(sources.count == 1, "steps had no readings, so it is not a source")
        let first = try #require(sources.first)
        #expect(first.domain == .metrics && first.count == 14 && first.recordIDs.count == 14 && first.recordIDs[0] == "rmssd:2026-10-01")
        #expect(first.range == AgentDayRange(from: "2026-10-01", to: "2026-10-14"))
        #expect(first.link == .metric(key: "rmssd", day: "2026-10-14"))
        // Asking again for the same thing does not list it twice.
        _ = await run(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"])
        #expect(await session.artifacts.sources.count == 1)
    }

    @Test func sleepReadsTheSleepMetricsAndLinksToTheNight() async throws {
        let json = try object(await run(AgentToolName.getSleep, ["from": "2026-10-01", "to": "2026-10-14"]))
        #expect(Set((json["series"] as? [String: Any])?.keys.map { $0 } ?? []) == ["sleep_duration"], "only sleep metrics with data appear")
        #expect(await session.artifacts.sources.first?.link == .sleep(day: "2026-10-14"))
        let wrong = await run(AgentToolName.getSleep, ["metrics": ["steps"]])
        #expect(wrong.isError && wrong.content.contains("get_metrics"))
    }

    @Test func comparingPeriodsReturnsMeansCountsAndTheDifference() async throws {
        let json = try object(await run(AgentToolName.comparePeriods, ["metric": "sleep_duration",
            "a": ["from": "2026-10-01", "to": "2026-10-07"], "b": ["from": "2026-10-08", "to": "2026-10-14"]]))
        #expect(json["unit"] as? String == "min")
        #expect((json["a"] as? [String: Any])?["mean"] as? Double == 424)
        #expect((json["b"] as? [String: Any])?["mean"] as? Double == 431)
        #expect((json["a"] as? [String: Any])?["daysWithReadings"] as? Int == 7)
        #expect(json["difference"] as? Double == 7)
        let empty = try object(await run(AgentToolName.comparePeriods, ["metric": "steps",
            "a": ["from": "2026-10-01", "to": "2026-10-07"], "b": ["from": "2026-10-08", "to": "2026-10-14"]]))
        #expect(empty["difference"] == nil && (empty["note"] as? String)?.contains("nothing to compare") == true)
    }

    @Test func comparingChosenDaysReadsTheMetricOnTheLaggedDay() async throws {
        let json = try object(await run(AgentToolName.compareDays, ["metric": "rmssd", "days": ["2026-10-04", "2026-10-09"], "lagDays": 1,
                                                                     "from": "2026-10-01", "to": "2026-10-13"]))
        #expect(json["lagDays"] as? Int == 1)
        let chosen = try #require(json["chosenDays"] as? [String: Any]), other = try #require(json["otherDays"] as? [String: Any])
        #expect(chosen["daysWithReadings"] as? Int == 2 && chosen["mean"] as? Double == 50, "read on 5 and 10 Oct")
        #expect(other["daysWithReadings"] as? Int == 11 && other["mean"] as? Double == 52.64)
        #expect(json["difference"] as? Double == -2.64)
        #expect((json["note"] as? String)?.contains("fewer than 5 days") == true)
        #expect(await session.artifacts.sources.contains { $0.label == "Heart rate variability" })
    }

    @Test func comparingChosenDaysChecksItsArguments() async {
        let cases: [([String: Any], String)] = [
            (["metric": "rmssd", "days": []], "1 to 120"),
            (["metric": "rmssd", "days": ["yesterday"]], "yyyy-MM-dd"),
            (["metric": "rmssd", "days": ["2026-10-04"], "lagDays": 5], "0, 1 or 2"),
            (["metric": "rmssd", "days": ["2026-10-04"], "lagDays": true], "0, 1 or 2"),
            (["metric": "mood", "days": ["2026-10-04"]], "metric must be"),
            (["metric": "rmssd", "days": ["2026-08-01"]], "None of the days")
        ]
        for (arguments, expected) in cases {
            let outcome = await run(AgentToolName.compareDays, arguments)
            #expect(outcome.isError && outcome.content.contains(expected), "\(arguments): \(outcome.content)")
        }
        #expect(source.totalReads == 0)
    }

    @Test func foodCarriesTargetsAndTheExtraNutrientsWhenTheDayHasThem() async throws {
        source.food = [AgentFoodDay(day: "2026-10-15", meals: [], energy: 2400, energyComplete: true, protein: 150, carbs: 250, fat: 70,
            waterMillilitres: nil, caffeineMilligrams: nil, alcoholUnits: 2, fibre: 31, sugar: 42, salt: 5.25, completed: true,
            targets: AgentFoodTargets(goal: "lose", energy: 2100, protein: 160, carbs: nil, fat: nil, waterMillilitres: nil, reason: "Your confirmed lose target."))]
        let days = try #require(try object(await run(AgentToolName.getFood, ["from": "2026-10-15", "to": "2026-10-15"]))["days"] as? [[String: Any]])
        let day = try #require(days.first)
        #expect(day["fibreG"] as? Double == 31 && day["sugarG"] as? Double == 42 && day["saltG"] as? Double == 5.25 && day["completed"] as? Bool == true)
        let targets = try #require(day["targets"] as? [String: Any])
        #expect(targets["energyKcal"] as? Double == 2100 && targets["proteinG"] as? Double == 160 && targets["goal"] as? String == "lose")
        #expect(targets["carbsG"] == nil, "a macro without a target is left out")
    }

    // MARK: Arguments

    @Test func rangesAreCheckedAndTheModelIsToldWhatToFix() async {
        let cases: [(String, [String: Any], String)] = [
            (AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-01-01", "to": "2026-10-14"], "at most 120 days"),
            (AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-10", "to": "2026-10-01"], "must not be after"),
            (AgentToolName.getMetrics, ["metrics": ["rmssd"], "to": "2026-10-20"], "after today"),
            (AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "last week"], "yyyy-MM-dd"),
            (AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-02-30"], "yyyy-MM-dd"),
            (AgentToolName.getMetrics, ["metrics": ["heart_things"]], "is not a metric"),
            (AgentToolName.getMetrics, [:], "metrics is required"),
            (AgentToolName.getMetrics, ["metrics": []], "1 to 8"),
            (AgentToolName.comparePeriods, ["metric": "rmssd", "a": ["from": "2026-10-01"], "b": [:]], "from and to"),
            (AgentToolName.getFood, ["from": "2026-10-16", "to": "2026-10-01"], "must not be after")
        ]
        for (tool, arguments, expected) in cases {
            let outcome = await run(tool, arguments)
            #expect(outcome.isError && !outcome.denied && outcome.content.contains(expected), "\(tool) \(arguments): \(outcome.content)")
        }
        #expect(source.totalReads == 0, "nothing was read for a bad request")
    }

    @Test func theDefaultRangeIsTheLastFourteenDaysEndingToday() async throws {
        let json = try object(await run(AgentToolName.getFood))
        #expect(json["from"] as? String == "2026-10-03" && json["to"] as? String == "2026-10-16")
    }

    @Test func aMalformedCallOrAnUnknownToolIsAnErrorNotACrash() async {
        let bad = AgentToolCall(id: "x", name: AgentToolName.getFood, arguments: "[1,2]")
        #expect(await executor().execute(bad).isError)
        #expect(await run("get_everything").isError)
        #expect(await run(AgentToolName.proposeMeal, [:]).isError, "no proposal store in this executor")
    }

    // MARK: Food, training, journal, cycle

    @Test func foodHasNamesAmountsAndEnergyButNeverPhotos() async throws {
        let outcome = await run(AgentToolName.getFood, ["from": "2026-10-14", "to": "2026-10-16"])
        let json = try object(outcome)
        let days = try #require(json["days"] as? [[String: Any]])
        #expect(days.map { $0["day"] as? String } == ["2026-10-14", "2026-10-15"])
        let dinner = try #require((days[1]["meals"] as? [[String: Any]])?.first)
        #expect(dinner["slot"] as? String == "dinner" && dinner["time"] as? String == "21:30")
        let item = try #require((dinner["items"] as? [[String: Any]])?.first)
        #expect(item["name"] as? String == "Pasta" && item["kcal"] as? Double == 820 && item["estimated"] as? Bool == false)
        #expect(days[1]["energyKcal"] as? Double == 820 && days[0]["waterMl"] as? Double == 1800)
        #expect(!outcome.content.lowercased().contains("photo") || outcome.content.contains("Photos"), "no photo fields")
        #expect(await session.artifacts.sources.first?.link == .foodDay(day: "2026-10-15"))
    }

    @Test func longFoodRangesDropTheMealListUnlessAsked() async throws {
        let short = try object(await run(AgentToolName.getFood, ["from": "2026-10-10", "to": "2026-10-16"]))
        #expect((short["days"] as? [[String: Any]])?.last?["meals"] != nil)
        let long = try object(await run(AgentToolName.getFood, ["from": "2026-08-01", "to": "2026-10-16"]))
        #expect((long["days"] as? [[String: Any]])?.last?["meals"] == nil)
        let asked = try object(await run(AgentToolName.getFood, ["from": "2026-08-01", "to": "2026-10-16", "includeMeals": true]))
        #expect((asked["days"] as? [[String: Any]])?.last?["meals"] != nil)
    }

    @Test func trainingListsSessionsAndTemplatesOnlyOnRequest() async throws {
        let plain = try object(await run(AgentToolName.getTraining, ["from": "2026-10-10", "to": "2026-10-16"]))
        let entry = try #require((plain["entries"] as? [[String: Any]])?.first)
        #expect(entry["name"] as? String == "Upper A" && entry["sets"] as? Int == 18 && entry["volumeKg"] as? Double == 7200)
        #expect(plain["templates"] == nil)
        let withTemplates = try object(await run(AgentToolName.getTraining, ["includeTemplates": true]))
        let template = try #require((withTemplates["templates"] as? [[String: Any]])?.first)
        #expect(template["revision"] as? Int == 3 && template["templateId"] as? String == "7E1C0F52-5D6B-4B3A-9C58-2D1B6B0A1111")
        #expect(((template["exercises"] as? [[String: Any]])?.first?["index"] as? Int) == 0)
        #expect(await session.artifacts.sources.first?.link == .trainSession(id: "session-1"))
    }

    @Test func journalAnswersAreSeparateFromNotes() async throws {
        let answers = try object(await run(AgentToolName.getJournal, ["from": "2026-10-10", "to": "2026-10-16"]))
        #expect(answers["notes"] == nil)
        #expect(((answers["days"] as? [[String: Any]])?.first?["answers"] as? [[String: Any]])?.first?["question"] as? String == "Alcohol")
        #expect(source.count("journalNotes") == 0)

        let withNotes = try object(await run(AgentToolName.getJournal, ["from": "2026-10-10", "to": "2026-10-16", "includeNotes": true]))
        #expect((withNotes["notes"] as? [[String: Any]])?.count == 1)
        let domains = await session.artifacts.sources.map(\.domain)
        #expect(Set(domains) == [.journalAnswers, .journalNotes])
    }

    @Test func askingForNotesWhileTheyAreOffRefusesTheWholeCall() async throws {
        suite.set(.journalNotes, false)
        let outcome = await run(AgentToolName.getJournal, ["includeNotes": true])
        #expect(outcome.denied && outcome.content == "Journal notes is off in Your data, so Ask did not read it.")
        #expect(!outcome.content.contains("Alcohol"), "half an answer is not returned")
        let answersOnly = await run(AgentToolName.getJournal)
        #expect(!answersOnly.denied)
    }

    @Test func cycleRecordsComeBackWithTheirSymptoms() async throws {
        let json = try object(await run(AgentToolName.getCycle, ["from": "2026-10-01", "to": "2026-10-16"]))
        let row = try #require((json["records"] as? [[String: Any]])?.first)
        #expect(row["kind"] as? String == "periodStart" && row["flow"] as? String == "medium" && row["symptoms"] as? [String] == ["cramps"])
        let cycleSource = try #require(await session.artifacts.sources.first)
        #expect(cycleSource.link == nil && cycleSource.domain == .cycle)
    }

    @Test func patternsListTheStrongOnesWithHonestWording() async throws {
        let json = try object(await run(AgentToolName.listPatterns))
        let pattern = try #require((json["patterns"] as? [[String: Any]])?.first)
        #expect(pattern["candidateId"] as? String == "food.lateMeal" && pattern["nightsWith"] as? Int == 9 && pattern["difference"] as? Double == -6)
        #expect((json["note"] as? String)?.contains("not cause") == true)
        #expect(await session.artifacts.sources.first?.link == .patterns)
    }
}
