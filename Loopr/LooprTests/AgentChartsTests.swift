import AIKit
import DesignSystem
import Foundation
import Testing
@testable import Loopr

/// FT-05.3: the chart under an answer draws the values the app read. Nothing the model writes reaches it.
@MainActor
@Suite(.serialized)
struct AgentChartsTests {
    private static let perth: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = AgentFixtures.zone
        return calendar
    }()

    private func snapshot(id: String = "metric.sleep_duration.a.b", kind: AgentChartKind = .bars, days: [(String, Double)],
                          highlighted: [String] = [], domain: AgentDataDomain = .metrics) -> AgentChartSnapshot {
        AgentChartSnapshot(id: id, title: "Sleep duration", unit: "min", domain: domain,
                           points: days.map { AgentChartPoint(day: $0.0, value: $0.1) }, kind: kind, highlightedDays: highlighted)
    }

    // MARK: The values are the app's

    @Test func theChartDrawsTheAppsValuesWhenTheAnswerQuotesOtherNumbers() async throws {
        let calls = [AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"], id: "c1"),
                     // The model also tries to hand the chart its own numbers. The tool takes an id and nothing else.
                     AgentFixtures.call(AgentToolName.showChart, ["chartId": "metric.rmssd.2026-10-01.2026-10-14", "points": [["day": "2026-10-14", "value": 99]], "values": [99, 12]], id: "c2")]
        let rig = try await AttachmentRig.make([.toolCalls(calls), .final("Your HRV sat at 99 ms all fortnight and fell to 12 ms last night.")])
        defer { rig.cleanup() }
        await rig.ask("How is my HRV?")

        let reply = try #require(rig.reply)
        #expect(reply.text.contains("99 ms"), "the model's words are shown as written")
        let chart = try #require(reply.chartSnapshots.first)
        // The fake holds 14 readings, 1 to 14 Oct, so the whole series is what the read returned. It is read from the
        // stored property: calling the fake's async method straight from a main-actor test crashes in the runtime's isolation cast.
        let appValues = try #require(rig.source.metrics[.rmssd])
        #expect(appValues.count == 14)
        #expect(chart.points == appValues.map { AgentChartPoint(day: $0.day, value: $0.value) })
        #expect(chart.points.allSatisfy { $0.value != 99 && $0.value != 12 })

        // And what the card draws is those same values.
        #expect(AgentChartPlan.renderer(for: chart) == .trendLine)
        #expect(AgentChartPlan.linePoints(for: chart, calendar: Self.perth).map(\.value) == appValues.map(\.value))
    }

    @Test func theBarsDrawTheAppsValuesInOrderWithGapsForMissingDays() throws {
        let chart = snapshot(days: [("2026-10-12", 420), ("2026-10-13", 380), ("2026-10-15", 455)])
        let bars = AgentChartPlan.bars(for: chart, calendar: Self.perth)
        #expect(bars.map(\.value) == [420, 380, nil, 455], "the 14th has no reading, so it is a gap and never a zero bar")
        #expect(bars.map { Self.perth.component(.day, from: $0.date) } == [12, 13, 14, 15])
        #expect(!bars.contains { $0.isHighlighted })
    }

    @Test func highlightedDaysComeFromTheSnapshot() {
        let chart = snapshot(days: [("2026-10-12", 72), ("2026-10-13", 58), ("2026-10-14", 51), ("2026-10-15", 47)], highlighted: ["2026-10-13", "2026-10-15", "2026-10-30"])
        let bars = AgentChartPlan.bars(for: chart, calendar: Self.perth)
        #expect(bars.map(\.isHighlighted) == [false, true, false, true], "a highlighted day with no bar adds nothing")
    }

    @Test func aChartWithNoPointsHasNothingToDraw() {
        let chart = snapshot(days: [])
        #expect(AgentChartPlan.bars(for: chart).isEmpty && AgentChartPlan.linePoints(for: chart).isEmpty)
        #expect(AgentChartPlan.latest(of: chart) == nil)
    }

    @Test func daysLandOnTheSameCivilDayInThePersonsCalendar() throws {
        let date = try #require(AgentChartPlan.date("2026-10-16", calendar: Self.perth))
        let parts = Self.perth.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 16)
        #expect(AgentChartPlan.date("not-a-day") == nil)
    }

    // MARK: Which renderer

    @Test func dailyTotalsDrawAsHighlightBarsAndMovingReadingsAsALine() {
        let week = [("2026-10-10", 1.0), ("2026-10-11", 2.0), ("2026-10-12", 3.0)]
        #expect(AgentChartPlan.renderer(for: snapshot(kind: .bars, days: week)) == .highlightBars)
        #expect(AgentChartPlan.renderer(for: snapshot(kind: .line, days: week)) == .trendLine)
        #expect(AgentToolExecutor.chartKind(.steps) == .bars && AgentToolExecutor.chartKind(.deepSleep) == .bars && AgentToolExecutor.chartKind(.sleepDuration) == .bars)
        #expect(AgentToolExecutor.chartKind(.rmssd) == .line && AgentToolExecutor.chartKind(.restingHeartRate) == .line)
    }

    @Test func aLongSpanFallsBackToALineBecauseBarsGetTooThin() {
        let long = [("2026-06-01", 1.0), ("2026-10-14", 2.0)]
        #expect(AgentChartPlan.spanDays(snapshot(days: long)) == 136)
        #expect(AgentChartPlan.renderer(for: snapshot(kind: .bars, days: long)) == .trendLine)
        let edge = [("2026-09-01", 1.0), ("2026-10-15", 2.0)]
        #expect(AgentChartPlan.spanDays(snapshot(days: edge)) == AgentChartPlan.maxBarDays)
        #expect(AgentChartPlan.renderer(for: snapshot(kind: .bars, days: edge)) == .highlightBars)
    }

    @Test func foodEnergyIsOfferedAsBars() async throws {
        let suite = AgentFixtures.Suite()
        let run = AgentToolExecutor(readers: AgentReaders(gate: AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: FakeAgentSource()),
                                    proposals: nil, maker: nil, session: AgentToolSession(), conversationID: UUID(), messageID: UUID(),
                                    now: AgentFixtures.now, timeZone: AgentFixtures.zone)
        _ = await run.execute(AgentFixtures.call(AgentToolName.getFood, ["from": "2026-10-10", "to": "2026-10-16"]))
        let session = run.session
        _ = await run.execute(AgentFixtures.call(AgentToolName.showChart, ["chartId": "food.energy.2026-10-10.2026-10-16"]))
        let chart = try #require(await session.artifacts.charts.first)
        #expect(chart.kind == .bars && chart.domain == .food && chart.unit == "kcal")
        #expect(chart.points.map(\.value) == [2100, 820])
    }

    // MARK: Text on the card

    @Test func valuesReadWithTheirUnit() {
        let au = Locale(identifier: "en_AU")
        #expect(AgentChartPlan.valueText(51, unit: "ms", locale: au) == "51 ms")
        #expect(AgentChartPlan.valueText(51.46, unit: "ms", locale: au) == "51.5 ms")
        #expect(AgentChartPlan.valueText(2100, unit: "kcal", locale: au) == "2100 kcal")
        #expect(AgentChartPlan.valueText(74, unit: "%", locale: au) == "74%")
        #expect(AgentChartPlan.valueText(8000, unit: "", locale: au) == "8000")
    }

    @Test func valuesFollowThePersonsDecimalSeparator() {
        #expect(AgentChartPlan.valueText(51.46, unit: "ms", locale: Locale(identifier: "de_DE")) == "51,5 ms")
        #expect(AgentChartPlan.valueText(2100, unit: "kcal", locale: Locale(identifier: "de_DE")) == "2100 kcal")
    }

    @Test func eachChartGetsItsOwnAccent() {
        #expect(AgentChartPlan.accent(for: snapshot(id: "metric.sleep_duration.a.b", days: [])) == .sleep)
        #expect(AgentChartPlan.accent(for: snapshot(id: "metric.rmssd.a.b", days: [])) == .heart)
        #expect(AgentChartPlan.accent(for: snapshot(id: "metric.recovery.a.b", days: [])) == .recovery)
        #expect(AgentChartPlan.accent(for: snapshot(id: "food.energy.a.b", days: [], domain: .food)) == .energy)
    }
}
