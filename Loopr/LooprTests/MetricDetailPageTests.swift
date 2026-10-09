import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import Loopr

private var berlin: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}

/// Thu 24 Sep 2026.
private let pageToday = berlin.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 9))!

private func pageDay(_ offset: Int) -> Date {
    berlin.date(byAdding: .day, value: -offset, to: berlin.startOfDay(for: pageToday))!
}

// MARK: - Correlation maths

struct MetricCorrelationMathTests {
    @Test func pearsonMatchesKnownValues() throws {
        // Perfect line, perfect inverse line.
        let up = (0..<10).map { (Double($0), 2 * Double($0) + 1) }
        let down = (0..<10).map { (Double($0), -3 * Double($0)) }
        #expect(abs(try #require(MetricCorrelations.pearson(up)) - 1) < 1e-12)
        #expect(abs(try #require(MetricCorrelations.pearson(down)) + 1) < 1e-12)
        // A textbook example: x = 1...5, y = 2, 4, 5, 4, 5 gives r = 0.7746.
        let book = zip([1.0, 2, 3, 4, 5], [2.0, 4, 5, 4, 5]).map { ($0, $1) }
        #expect(abs(try #require(MetricCorrelations.pearson(book)) - 0.774_596_669) < 1e-6)
        // Independent pattern: r = 0.
        let flat = zip([1.0, 2, 3, 4], [1.0, -1, -1, 1]).map { ($0, $1) }
        #expect(abs(try #require(MetricCorrelations.pearson(flat))) < 1e-12)
    }

    @Test func pearsonRefusesDegenerateInput() {
        #expect(MetricCorrelations.pearson([]) == nil)
        #expect(MetricCorrelations.pearson([(1, 2)]) == nil)
        #expect(MetricCorrelations.pearson([(1, 5), (2, 5), (3, 5)]) == nil)
        #expect(MetricCorrelations.pearson([(1, 2), (.nan, 3), (3, 4)]) == nil)
    }

    private func series(_ values: [Int: Double]) -> [Date: Double] {
        Dictionary(uniqueKeysWithValues: values.map { (pageDay($0.key), $0.value) })
    }

    private var window: ClosedRange<Date> {
        MetricCorrelations.window(.month, anchor: pageDay(0), calendar: berlin)
    }

    @Test func rankKeepsOnlyStrongEnoughLinksWithEnoughDays() {
        let target = series(Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, Double($0 % 7)) }))
        let strong = series(Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, Double($0 % 7) * 2 + 3) }))
        let inverse = series(Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, -Double($0 % 7)) }))
        // Same pattern, but only 9 shared days: below the 10-day gate.
        let short = series(Dictionary(uniqueKeysWithValues: (0..<9).map { ($0, Double($0 % 7)) }))
        // Unrelated: alternates independently of the target.
        let noise = series(Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, [1.0, 1, -1, -1][$0 % 4]) }))
        let ranked = MetricCorrelations.rank(
            target: .rmssd, values: target,
            others: [.recovery: strong, .restingHeartRate: inverse, .strain: short, .steps: noise],
            window: window
        )
        #expect(ranked.map(\.other).contains(.recovery))
        #expect(ranked.map(\.other).contains(.restingHeartRate))
        #expect(!ranked.map(\.other).contains(.strain))
        #expect(ranked.allSatisfy { abs($0.r) >= MetricCorrelations.minimumStrength && $0.pairedDays >= 10 })
        let inverseLink = ranked.first { $0.other == .restingHeartRate }
        #expect(inverseLink.map { $0.r < 0 } == true)
        if let noiseLink = ranked.first(where: { $0.other == .steps }) {
            #expect(abs(noiseLink.r) >= 0.3)
        }
    }

    @Test func temperatureCanCorrelateWhileBandOxygenStaysExcluded() {
        let values = series(Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, Double($0)) }))
        let others: [MetricKey: [Date: Double]] = [
            .oxygenSaturation: values,
            .skinTemperatureDeviation: values,
            .steps: values
        ]
        let links = MetricCorrelations.rank(target: .rmssd, values: values, others: others, window: window)
        #expect(Set(links.map(\.other)) == [.steps, .skinTemperatureDeviation])
        #expect(MetricCorrelations.rank(target: .oxygenSaturation, values: values, others: [.steps: values], window: window).isEmpty)
        #expect(MetricCorrelations.rank(target: .skinTemperatureDeviation, values: values, others: [.steps: values], window: window).map(\.other) == [.steps])
    }

    @Test func missingDaysAreSkippedNotFilled() throws {
        // The target misses every third day; the other metric has a wild
        // value on exactly those days. Pairing only shared days keeps r = 1.
        var targetValues: [Int: Double] = [:]
        var otherValues: [Int: Double] = [:]
        for offset in 0..<24 {
            otherValues[offset] = offset % 3 == 0 ? 1_000 : Double(offset)
            if offset % 3 != 0 { targetValues[offset] = Double(offset) * 2 }
        }
        let ranked = MetricCorrelations.rank(target: .rmssd, values: series(targetValues), others: [.recovery: series(otherValues)], window: window)
        let link = try #require(ranked.first)
        #expect(abs(link.r - 1) < 1e-9)
        #expect(link.pairedDays == 16)
    }

    @Test func onlyDaysInsideTheWindowCount() {
        // 12 days, but 6 of them are older than the 7-day window.
        let values = series(Dictionary(uniqueKeysWithValues: (0..<12).map { ($0, Double($0)) }))
        let weekWindow = MetricCorrelations.window(.week, anchor: pageDay(0), calendar: berlin)
        #expect(MetricCorrelations.measuredDays(values, in: weekWindow) == 7)
        #expect(MetricCorrelations.rank(target: .rmssd, values: values, others: [.recovery: values], window: weekWindow).isEmpty)
    }

    @Test func topFiveStrongestFirstAndNoSameMeasurementPairs() {
        let target = series(Dictionary(uniqueKeysWithValues: (0..<30).map { ($0, Double($0)) }))
        var others: [MetricKey: [Date: Double]] = [:]
        // Increasing noise per metric, so strength falls in this order.
        let keys: [MetricKey] = [.recovery, .restingHeartRate, .strain, .stress, .sleepDuration, .steps, .sdnn]
        for (rank, key) in keys.enumerated() {
            others[key] = series(Dictionary(uniqueKeysWithValues: (0..<30).map { offset in
                (offset, Double(offset) + (offset.isMultiple(of: 2) ? 1 : -1) * Double(rank) * 3)
            }))
        }
        let ranked = MetricCorrelations.rank(target: .rmssd, values: target, others: others, window: window)
        #expect(ranked.count == 5)
        #expect(!ranked.map(\.other).contains(.sdnn), "SDNN is the same measurement as RMSSD")
        #expect(ranked.map(\.other) == [.recovery, .restingHeartRate, .strain, .stress, .sleepDuration])
        #expect(zip(ranked, ranked.dropFirst()).allSatisfy { abs($0.r) >= abs($1.r) })
    }

    @Test func wordsArePlainAndSayNotCause() {
        let positive = MetricCorrelation(other: .sleepDuration, r: 0.62, pairedDays: 38)
        let negative = MetricCorrelation(other: .strain, r: -0.34, pairedDays: 20)
        #expect(MetricCorrelations.sentence(positive, target: .rmssd) == "When you sleep longer, your HRV tends to be higher.")
        #expect(MetricCorrelations.sentence(negative, target: .recovery) == "When your strain is higher, your recovery tends to be lower.")
        #expect(MetricCorrelations.sentence(negative, target: .steps) == "When your strain is higher, you tend to walk less.")
        #expect(MetricCorrelations.sentence(MetricCorrelation(other: .rmssd, r: 0.4, pairedDays: 12), target: .sleepDuration)
                == "When your HRV is higher, you tend to sleep longer.")
        #expect(MetricCorrelations.caption(positive) == "Clear link · r = 0.62 · 38 days")
        #expect(MetricCorrelations.caption(negative) == "Loose link · r = \u{2212}0.34 · 20 days")
        #expect(MetricCorrelations.strength(0.71) == "Strong link")
        #expect(MetricCorrelationSection.causationNote == "These move together. That does not mean one causes the other.")
        for key in MetricKey.allCases {
            let sentence = MetricCorrelations.sentence(MetricCorrelation(other: key, r: 0.5, pairedDays: 10), target: .recovery)
            #expect(!sentence.contains("  "))
            #expect(!sentence.lowercased().contains("cause"))
            for term in MetricContentCatalogTests.bannedTerms {
                #expect(!sentence.lowercased().contains(term))
            }
        }
    }
}

// MARK: - Small-data rules and the day on screen

struct MetricDetailRulesTests {
    @Test func statisticsNeedAWeekOfReadings() {
        #expect(!MetricDetailRules.showsFullStatistics(measuredDays: 2))
        #expect(!MetricDetailRules.showsFullStatistics(measuredDays: 6))
        #expect(MetricDetailRules.showsFullStatistics(measuredDays: 7))
    }

    @Test func everyMetricHasAScaleAndNoun() {
        for key in MetricKey.allCases {
            #expect(MetricDetailRules.scale(for: key).minimumSpan > 0, "\(key)")
        }
        #expect(MetricDetailRules.scale(for: .recovery) == LooprChartScaleHint(minimumSpan: 100, bounds: 0...100))
        #expect(MetricDetailRules.countNoun(for: .rmssd) == .nights)
        #expect(MetricDetailRules.countNoun(for: .steps) == .days)
        #expect(MetricDetailRules.higherIsBetter(.strain) == nil)
        #expect(MetricDetailRules.higherIsBetter(.restingHeartRate) == false)
        #expect(MetricDetailRules.higherIsBetter(.heartRateDip) == nil)
    }

    @Test func sparseHistoryOffersOnlySevenDays() {
        let points = [2, 1, 0].map { LooprChartPoint(date: pageDay($0), value: 44) }
        #expect(MetricDetailRules.availableRanges(points, anchor: pageDay(0), calendar: berlin) == [.week])
        let month = (0..<20).map { LooprChartPoint(date: pageDay($0), value: 44) }
        #expect(MetricDetailRules.availableRanges(month, anchor: pageDay(0), calendar: berlin) == [.week, .month])
    }

    @Test func dateLabelsCarryTheWeekday() {
        let anchor = MetricDetailAnchor(day: pageDay(1), today: pageToday, calendar: berlin)
        #expect(anchor.dateText(pageDay(1)) == "Wed 23 Sep")
        #expect(anchor.dateText(pageDay(3)) == "Mon 21 Sep")
    }

    @Test func heroEyebrowFollowsTheDayOnScreen() {
        let today = MetricDetailAnchor(day: pageToday, today: pageToday, calendar: berlin)
        #expect(today.isToday)
        #expect(today.heroEyebrow(for: pageDay(0), key: .rmssd) == "LAST NIGHT")
        #expect(today.heroEyebrow(for: pageDay(0), key: .steps) == "TODAY")

        let yesterday = MetricDetailAnchor(day: pageDay(1), today: pageToday, calendar: berlin)
        #expect(!yesterday.isToday)
        #expect(yesterday.heroEyebrow(for: pageDay(1), key: .steps) == "YESTERDAY · WED 23 SEP")
        #expect(yesterday.heroEyebrow(for: pageDay(1), key: .rmssd) == "TUE 22 → WED 23 SEP")
        #expect(yesterday.missingCaption(for: pageDay(1)) == nil)

        // An older reading is labelled as the latest, with why.
        #expect(yesterday.heroEyebrow(for: pageDay(3), key: .rmssd) == "LATEST · MON 21 SEP")
        #expect(yesterday.missingCaption(for: pageDay(3)) == "No reading on Wed 23 Sep.")
        #expect(today.missingCaption(for: pageDay(1)) == "No reading for today yet.")
    }

    @Test func anchorNeverLiesInTheFuture() {
        let future = MetricDetailAnchor(day: berlin.date(byAdding: .day, value: 3, to: pageToday)!, today: pageToday, calendar: berlin)
        #expect(future.isToday)
    }

    @Test func anchorFromTheTabsSelection() {
        let anchor = MetricDetailAnchor(
            selectedDay: LooprDay(year: 2026, month: 9, day: 23),
            today: LooprDay(year: 2026, month: 9, day: 24),
            calendar: berlin
        )
        #expect(anchor.day == pageDay(1))
        #expect(anchor.today == pageDay(0))
        #expect(berlin.startOfDay(for: anchor.endOfDay) == pageDay(1))
    }
}

// MARK: - The page model

/// Serves fixed series and records what was asked for.
private final class StubHistory: MetricHistoryProviding, @unchecked Sendable {
    let series: [MetricKey: [MetricHistoryPoint]]
    private let lock = NSLock()
    private var requests: [(MetricKey, Date)] = []

    init(_ series: [MetricKey: [MetricHistoryPoint]]) { self.series = series }

    var asked: [(MetricKey, Date)] { lock.withLock { requests } }

    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        lock.withLock { requests.append((key, endingOn)) }
        return (series[key] ?? []).filter { $0.day <= endingOn }
    }
}

@MainActor
struct MetricDetailModelTests {
    private func points(_ offsets: Range<Int>, value: (Int) -> Double) -> [MetricHistoryPoint] {
        offsets.reversed().map { MetricHistoryPoint(day: pageDay($0), value: value($0), source: .band) }
    }

    @Test func heroFollowsTheSelectedDay() async throws {
        let stub = StubHistory([.rmssd: points(0..<5) { 40 + Double($0) }])
        let model = MetricDetailModel(key: .rmssd)
        // The tabs show Wed 23 Sep (yesterday): the page is about that day.
        await model.load(from: stub, anchor: MetricDetailAnchor(day: pageDay(1), today: pageToday, calendar: berlin))
        #expect(model.state == .loaded)
        let latest = try #require(model.latest)
        #expect(latest.value == 41)
        #expect(berlin.isDate(latest.date, inSameDayAs: pageDay(1)))
        #expect(model.points.allSatisfy { $0.date <= model.anchor.endOfDay })

        // Back on today it shows today's reading.
        await model.load(from: stub, anchor: MetricDetailAnchor(day: pageToday, today: pageToday, calendar: berlin))
        #expect(model.latest?.value == 40)
    }

    @Test func aDayWithoutAReadingFallsBackToTheLatestBefore() async {
        let stub = StubHistory([.steps: [MetricHistoryPoint(day: pageDay(3), value: 8_000, source: .band)]])
        let model = MetricDetailModel(key: .steps)
        let anchor = MetricDetailAnchor(day: pageDay(1), today: pageToday, calendar: berlin)
        await model.load(from: stub, anchor: anchor)
        #expect(model.latest?.value == 8_000)
        #expect(anchor.missingCaption(for: model.latest!.date) == "No reading on Wed 23 Sep.")
    }

    @Test func strainTargetUsesRecoveryFromTheDisplayedDay() async {
        let stub = StubHistory([
            .strain: [MetricHistoryPoint(day: pageDay(2), value: 8.6, source: .band)],
            .recovery: [MetricHistoryPoint(day: pageDay(2), value: 83, source: .band),
                        MetricHistoryPoint(day: pageDay(1), value: 25, source: .band)]
        ])
        let model = MetricDetailModel(key: .strain)
        await model.load(from: stub, anchor: MetricDetailAnchor(day: pageDay(1), today: pageToday, calendar: berlin))
        #expect(model.latest?.value == 8.6)
        #expect(model.strainTarget?.range == 14...18)
        #expect(stub.asked.map(\.0) == [.strain, .recovery])
    }

    @Test func strainPageDoesNotSuggestARangeWithoutRecovery() async {
        let stub = StubHistory([.strain: [MetricHistoryPoint(day: pageDay(0), value: 8.6, source: .band)]])
        let model = MetricDetailModel(key: .strain)
        await model.load(from: stub, anchor: MetricDetailAnchor(day: pageToday, today: pageToday, calendar: berlin))
        #expect(model.strainTarget == nil)
    }

    @Test func sparseHistoryLocksLongRangesAndSkipsCorrelations() async {
        let stub = StubHistory([.rmssd: points(0..<3) { 44 + Double($0) }])
        let model = MetricDetailModel(key: .rmssd)
        await model.load(from: stub, anchor: MetricDetailAnchor(day: pageToday, today: pageToday, calendar: berlin))
        #expect(model.availableRanges == [.week])
        await model.loadCorrelations(for: .week, provider: stub)
        #expect(model.correlationState == .tooFewDays(measured: 3))
        // No other metric was read for a page that cannot show links.
        #expect(stub.asked.count == 1)
    }

    @Test func correlationsLoadAfterThePageAndRerankWithoutRereading() async throws {
        let target = points(0..<60) { Double($0 % 9) }
        let stub = StubHistory([
            .rmssd: target,
            .recovery: points(0..<60) { Double($0 % 9) * 3 + 20 },
            .restingHeartRate: points(0..<60) { 60 - Double($0 % 9) },
            .sdnn: points(0..<60) { Double($0 % 9) }
        ])
        let model = MetricDetailModel(key: .rmssd)
        await model.load(from: stub, anchor: MetricDetailAnchor(day: pageToday, today: pageToday, calendar: berlin))
        #expect(model.correlationState == .waiting)
        #expect(model.availableRanges == [.week, .month, .quarter])

        await model.loadCorrelations(for: .month, provider: stub)
        guard case .loaded(let links) = model.correlationState else {
            Issue.record("expected links, got \(model.correlationState)")
            return
        }
        #expect(links.map(\.other) == [.recovery, .restingHeartRate] || links.map(\.other) == [.restingHeartRate, .recovery])
        #expect(!links.map(\.other).contains(.sdnn))
        #expect(links.first { $0.other == .restingHeartRate }.map { $0.r < 0 } == true)
        let reads = stub.asked.count

        await model.loadCorrelations(for: .quarter, provider: stub)
        #expect(stub.asked.count == reads, "Changing the range re-ranks without reading history again")
    }
}

#if DEBUG
struct FixtureCorrelationTests {
    /// The fixture's metrics move together the way real ones do, so its
    /// "What moves with this" never says resting heart rate rises with HRV.
    @Test func fixtureLinksPointTheRightWay() {
        let end = Date(timeIntervalSince1970: 1_790_000_000)
        func daily(_ key: MetricKey) -> [Date: Double] {
            MetricCorrelations.daily(FixtureMetricHistoryProvider.points(for: key, days: 90, endingOn: end))
        }
        let window = MetricCorrelations.window(.quarter, anchor: end)
        let links = MetricCorrelations.rank(
            target: .rmssd, values: daily(.rmssd),
            others: [.restingHeartRate: daily(.restingHeartRate), .sleepDuration: daily(.sleepDuration), .stress: daily(.stress)],
            window: window
        )
        for link in links {
            switch link.other {
            case .restingHeartRate, .stress: #expect(link.r < 0, "\(link.other)")
            case .sleepDuration: #expect(link.r > 0)
            default: break
            }
        }
    }
}
#endif

struct MetricCorrelationCopyTests {
    @Test func tooFewDaysSaysWhatIsMissing() {
        #expect(MetricCorrelationSection.tooFewText(measured: 3, range: .week, canWiden: false, noun: .nights)
                == "Loopr looks for patterns once it has 10 nights with readings. It has 3 so far.")
        #expect(MetricCorrelationSection.tooFewText(measured: 7, range: .week, canWiden: true, noun: .nights)
                == "A week is too short to see what moves together. Pick 30D or longer.")
        #expect(MetricCorrelationSection.tooFewText(measured: 8, range: .month, canWiden: true, noun: .days)
                == "Loopr looks for patterns once this range holds 10 days with readings. It has 8 so far.")
    }
}

struct MetricLearningCountTests {
    @Test func learningCountsTheLatestNightToo() {
        let points = [1, 0].map { LooprChartPoint(date: pageDay($0), value: 44) }
        #expect(MetricDetailRules.learningCount(points, latest: pageDay(0), calendar: berlin) == 2)
        #expect(MetricTrendNarrative.daysTowardsBaseline(points, today: pageDay(0), calendar: berlin) == 1)
    }
}
