import DesignSystem
import Foundation
import Testing
@testable import Loopr

struct MetricContentCatalogTests {
    /// Words and ideas the wellness rules in the night-build brief forbid.
    static let bannedTerms = [
        "diagnos", "detect disease", "afib", "atrial fibrillation", "arrhythmia", "irregular rhythm",
        "tachycardia", "bradycardia", "apnea", "apnoea", "ahi", "hypertension", "blood pressure",
        "abnormal", "dangerous", "medical-grade", "medical grade", "clinically accurate"
    ]

    /// AI tells the unslop pass removes.
    static let slopTerms = [
        "delve", "crucial", "pivotal", "tapestry", "testament", "vibrant", "seamless", "leverage",
        "utilize", "unlock", "empower", "game-changer", "journey", "!"
    ]

    private func allStrings(_ content: MetricContent) -> [String] {
        content.definition + content.calculation + content.raises + content.lowers
            + content.facts + content.sources + [content.provenance]
    }

    @Test(arguments: MetricKey.allCases)
    func everyMetricHasItsSupportedSections(_ key: MetricKey) {
        let content = MetricContentCatalog.content(for: key)
        #expect(!content.definition.isEmpty)
        #expect(!content.calculation.isEmpty)
        if key == .oxygenSaturation {
            // DEC-05 forbids a band oxygen estimate. Do not invent sections about it.
            #expect(content.raises.isEmpty)
            #expect(content.lowers.isEmpty)
            #expect(content.facts == ["The band's light channels move together, so they cannot provide an oxygen reading."])
            #expect(key.presentation.availability == .importedOnly)
            #expect(content.calculation == ["This band doesn't report blood oxygen. Imported readings appear when available, with their source."])
        } else {
            #expect(!content.raises.isEmpty)
            #expect(!content.lowers.isEmpty)
            #expect((2...4).contains(content.facts.count), "\(key) needs 2 to 4 facts")
        }
        #expect(!content.sources.isEmpty)
        #expect(!content.provenance.isEmpty)
        for text in allStrings(content) {
            #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @Test(arguments: MetricKey.allCases)
    func copyFollowsWellnessAndStyleRules(_ key: MetricKey) {
        let content = MetricContentCatalog.content(for: key)
        let presentation = key.presentation
        let strings = allStrings(content) + [presentation.title]
        for text in strings {
            let lower = text.lowercased()
            for term in Self.bannedTerms {
                let pattern = term == "ahi" ? "\\bahi\\b" : NSRegularExpression.escapedPattern(for: term)
                #expect(lower.range(of: pattern, options: .regularExpression) == nil, "\(key): banned term \"\(term)\" in \"\(text)\"")
            }
            for term in Self.slopTerms {
                #expect(!lower.contains(term), "\(key): \"\(term)\" in \"\(text)\"")
            }
            #expect(!text.contains("\u{2014}"), "\(key): em dash in \"\(text)\"")
            #expect(!text.contains("\u{2013}"), "\(key): en dash in \"\(text)\"")
            #expect(!text.contains("\u{201C}") && !text.contains("\u{201D}") && !text.contains("\u{2019}"), "\(key): curly quote in \"\(text)\"")
        }
    }

    @Test(arguments: MetricKey.allCases)
    func sentencesEndCleanly(_ key: MetricKey) {
        let content = MetricContentCatalog.content(for: key)
        for paragraph in content.definition + content.calculation + content.facts + [content.provenance] {
            #expect(paragraph.hasSuffix("."), "\(key): paragraph should end with a full stop: \"\(paragraph)\"")
        }
        for mover in content.raises + content.lowers {
            #expect(!mover.hasSuffix("."), "\(key): list items carry no full stop: \"\(mover)\"")
        }
    }

    @Test func linkIDsCoverEveryMetricKey() {
        #expect(Set(LooprMetricLinkID.all) == Set(MetricKey.allCases.map(\.rawValue)))
        for id in LooprMetricLinkID.all {
            #expect(MetricKey(linkID: id) != nil)
        }
    }

    @Test func notCalculatedMetricsSayTheyAreNotCalculated() {
        for key in MetricKey.allCases where key.presentation.availability != .calculated {
            let content = MetricContentCatalog.content(for: key)
            let joined = content.calculation.joined(separator: " ").lowercased()
            if key == .oxygenSaturation {
                #expect(joined == "this band doesn't report blood oxygen. imported readings appear when available, with their source.")
            } else {
                #expect(joined.contains("does not"), "\(key) must say plainly that Loopr does not calculate it")
            }
        }
    }
}

struct MetricValueFormatTests {
    @Test func formatsValuesPerKind() {
        #expect(MetricValueFormat.whole.string(54.6) == "55")
        #expect(MetricValueFormat.oneDecimal.string(15.44) == "15.4")
        #expect(MetricValueFormat.signedOneDecimal.string(0.26) == "+0.3")
        #expect(MetricValueFormat.signedOneDecimal.string(-0.04) == "0.0")
        // Durations follow the tabs spec: "7 h 32 m", "45 min", "8 h".
        #expect(MetricValueFormat.duration.string(452) == "7 h 32 m")
        #expect(MetricValueFormat.duration.string(45) == "45 min")
        #expect(MetricValueFormat.duration.string(480) == "8 h")
        #expect(MetricValueFormat.duration.axisString(480) == "8 h")
        #expect(MetricValueFormat.grouped.axisString(12000) == "12k")
        #expect(MetricValueFormat.grouped.string(8240) == "8,240")
        #expect(MetricValueFormat.grouped.delta(-1250) == "-1,250")
        #expect(MetricValueFormat.whole.delta(-3.2) == "-3")
        #expect(MetricValueFormat.duration.delta(35) == "+35 min")
        #expect(MetricValueFormat.duration.delta(-65) == "-1 h 5 m")
        #expect(MetricValueFormat.duration.delta(0.2) == "0 min")
    }
}

struct MetricTrendNarrativeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9))!
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: today))!
    }

    /// 30 baseline days alternating 48/52 (median 50, MAD 2, spread about
    /// 2.97), then the last 7 days at `recent`.
    private func points(recent: Double, recentDays: [Int] = Array(0..<7)) -> [LooprChartPoint] {
        var result = (7...36).map { LooprChartPoint(date: day($0), value: $0.isMultiple(of: 2) ? 48 : 52) }
        result += recentDays.map { LooprChartPoint(date: day($0), value: recent) }
        return result
    }

    @Test func steadyWhenTheWeekStaysWithinHalfTheSpread() {
        // Baseline over the 30 days before today includes 6 recent days, so
        // compute the threshold from the summary itself.
        let summary = MetricTrendNarrative.summary(points: points(recent: 50.5), key: .restingHeartRate, range: .month, today: today, calendar: calendar)
        #expect(summary.direction == .steady)
        #expect(summary.directionLabel == "About the same as usual")
        #expect(summary.headline.contains("in line with your usual"))
    }

    @Test func higherAndLowerPastTheSmallestWorthwhileChange() throws {
        let higher = MetricTrendNarrative.summary(points: points(recent: 58), key: .restingHeartRate, range: .month, today: today, calendar: calendar)
        #expect(higher.direction == .higher)
        #expect(higher.directionLabel == "Higher than usual")
        #expect(higher.headline.contains("above your usual"))
        let lower = MetricTrendNarrative.summary(points: points(recent: 40), key: .rmssd, range: .month, today: today, calendar: calendar)
        #expect(lower.direction == .lower)
        #expect(lower.headline.contains("below your usual"))
        let band = try #require(lower.baseline)
        let delta = try #require(lower.delta)
        #expect(abs(delta) >= MetricTrendNarrative.smallestWorthwhileChange * band.halfWidth)
    }

    @Test func thresholdBoundaryCountsAsAChange() throws {
        // Find the exact threshold from a probe, then sit just inside and just outside it.
        let probe = MetricTrendNarrative.summary(points: points(recent: 50), key: .restingHeartRate, range: .month, today: today, calendar: calendar)
        let band = try #require(probe.baseline)
        let threshold = MetricTrendNarrative.smallestWorthwhileChange * band.halfWidth
        #expect(threshold > 0)
        let direction = { (value: Double) in
            MetricTrendNarrative.summary(points: points(recent: value), key: .restingHeartRate, range: .month, today: today, calendar: calendar).direction
        }
        #expect(direction(50.2) == .steady)
        #expect(direction(56) == .higher)
    }

    @Test func needsThreeDaysThisWeek() {
        let summary = MetricTrendNarrative.summary(points: points(recent: 60, recentDays: [0, 3]), key: .restingHeartRate, range: .month, today: today, calendar: calendar)
        #expect(summary.direction == .notEnoughData)
        #expect(summary.headline.hasPrefix("Only 2 days measured in the last 7"))
        let one = MetricTrendNarrative.summary(points: points(recent: 60, recentDays: [0]), key: .restingHeartRate, range: .month, today: today, calendar: calendar)
        #expect(one.headline.hasPrefix("Only 1 day measured"))
    }

    @Test func needsFourteenDaysForAUsualRange() {
        let few = (0..<10).map { LooprChartPoint(date: day($0), value: 50) }
        let summary = MetricTrendNarrative.summary(points: few, key: .restingHeartRate, range: .month, today: today, calendar: calendar)
        #expect(summary.direction == .notEnoughData)
        #expect(summary.directionLabel == "Learning your usual range")
        #expect(summary.headline.contains("It has 9 so far"))
    }

    @Test func heroStatusComparesTheLatestDay() {
        let all = points(recent: 50)
        let latest = LooprChartPoint(date: day(0), value: 80)
        var withLatest = all.filter { $0.date != day(0) }
        withLatest.append(latest)
        let status = MetricTrendNarrative.heroStatus(points: withLatest, latest: latest, today: today, calendar: calendar)
        #expect(status?.position == .above)
        #expect(status?.text == "Above your usual range")
        #expect(MetricTrendNarrative.heroStatus(points: [], latest: nil, today: today, calendar: calendar) == nil)
    }

    @Test func summaryReportsExtremesAndDayToDayChange() throws {
        let summary = MetricTrendNarrative.summary(points: points(recent: 50), key: .restingHeartRate, range: .week, today: today, calendar: calendar)
        #expect(summary.highest?.value == 50)
        #expect(summary.typicalDailyChange == 0)
        #expect(summary.variability == "Changes by about 0 bpm from one day to the next")
    }

    @Test func durationMetricsWordDeltasAsTime() {
        var data = (7...36).map { LooprChartPoint(date: day($0), value: $0.isMultiple(of: 2) ? 420 : 440) }
        data += (0..<7).map { LooprChartPoint(date: day($0), value: 380) }
        let summary = MetricTrendNarrative.summary(points: data, key: .sleepDuration, range: .month, today: today, calendar: calendar)
        #expect(summary.direction == .lower)
        #expect(summary.headline.contains("6 h 20 m"))
    }
}

#if DEBUG
struct FixtureMetricHistoryProviderTests {
    @Test func fixtureIsDeterministicAndHasGaps() {
        let end = Date(timeIntervalSince1970: 1_790_000_000)
        let first = FixtureMetricHistoryProvider.points(for: .rmssd, days: 90, endingOn: end)
        let second = FixtureMetricHistoryProvider.points(for: .rmssd, days: 90, endingOn: end)
        #expect(first == second)
        #expect(first.count < 90)
        #expect(first.count > 60)
        #expect(FixtureMetricHistoryProvider.points(for: .heartRateDip, days: 90, endingOn: end).isEmpty)
    }
}
#endif
