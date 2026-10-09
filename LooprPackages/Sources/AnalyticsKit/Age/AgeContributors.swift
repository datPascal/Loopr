import Foundation

/// Aggregates canonical daily outputs into the fixed 180-day contributor
/// window.  It deliberately has no repository dependency; callers load
/// immutable snapshots and the scheduler owns persistence.
public struct AgeContributorAggregator: Sendable {
    public let minimumHistoryDays: Int
    public let modelWindowDays: Int
    public let minimumCoverage: Double

    public init(
        minimumHistoryDays: Int = 90,
        modelWindowDays: Int = 180,
        minimumCoverage: Double = 0.70
    ) {
        self.minimumHistoryDays = minimumHistoryDays
        self.modelWindowDays = modelWindowDays
        self.minimumCoverage = minimumCoverage
    }

    public func aggregate(
        snapshots: [DailyAgeContributorSnapshot],
        modelWindow: DateInterval,
        timeZone: TimeZone = .autoupdatingCurrent,
        uncertaintyMaterial: Bool = false
    ) -> AgeAggregationResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let totalDays = localDayCount(in: modelWindow, calendar: calendar)
        guard totalDays > 0 else {
            return emptyResult(for: modelWindow)
        }

        let inWindow = snapshots.filter { $0.day >= modelWindow.start && $0.day < modelWindow.end }
        let unique = deduplicatedByLocalDay(inWindow, calendar: calendar)
        let eligible = unique.filter(\.quality.isEligible)
        let excluded = unique.filter { !$0.quality.isEligible }
        let eligibleDays = eligible.count
        let validDays = eligibleDays
        let minimumHistoryMet = eligibleDays >= minimumHistoryDays

        let domainValues = collectDomainValues(eligible)
        let domainCoverage = domainValues.mapValues { Double($0.count) / Double(totalDays) }
        let requiredKinds: [AgeContributorKind] = [
            .cardioCapacity,
            .restingHeartRate,
            .dailyMovement,
            .lowModerateAerobicActivity,
            .vigorousAerobicActivity,
            .strengthActivity,
            .sleepDuration,
            .sleepConsistency
        ]
        let validDomainCount = requiredKinds.reduce(into: 0) { count, kind in
            if let fraction = domainCoverage[kind], fraction >= minimumCoverage {
                count += 1
            }
        }
        let strongCoverage = requiredKinds.allSatisfy {
            (domainCoverage[$0] ?? 0) >= minimumCoverage
        }
        let overallCoverage = Double(validDomainCount) / Double(requiredKinds.count)
        let coverage = AgeCoverage(
            windowDays: totalDays,
            eligibleDays: eligibleDays,
            validDays: validDays,
            totalDays: totalDays,
            coverageFraction: overallCoverage,
            strongCoverage: strongCoverage
        )

        let contributors = makeContributors(
            eligible: eligible,
            totalDays: totalDays,
            domainCoverage: domainCoverage,
            calendar: calendar
        )

        let tier: ConfidenceTier
        let absence: LooprAgeAbsenceReason?
        if !minimumHistoryMet || !strongCoverage {
            tier = .unavailable
            if excluded.contains(where: { $0.quality.acuteIllness || $0.quality.lowWear || $0.quality.unsupportedMedication }) {
                absence = .illnessOrLowWear
            } else {
                absence = .insufficientCoverage
            }
        } else if uncertaintyMaterial {
            tier = .lowConfidence
            absence = nil
        } else if eligibleDays < modelWindowDays {
            tier = .provisional
            absence = nil
        } else {
            tier = .established
            absence = nil
        }

        return AgeAggregationResult(
            contributors: contributors,
            coverage: coverage,
            confidenceTier: tier,
            absenceReason: absence,
            modelWindow: modelWindow,
            validDomainCount: validDomainCount
        )
    }

    private func emptyResult(for modelWindow: DateInterval) -> AgeAggregationResult {
        let contributors = AgeContributorKind.allCases.map {
            AgeContributor(
                kind: $0,
                rawAggregate: nil,
                unit: "",
                source: "",
                coverage: 0,
                quality: 0,
                modelTransform: "unavailable",
                availability: .absent(reason: .insufficientCoverage)
            )
        }
        return AgeAggregationResult(
            contributors: contributors,
            coverage: .empty,
            confidenceTier: .unavailable,
            absenceReason: .insufficientCoverage,
            modelWindow: modelWindow,
            validDomainCount: 0
        )
    }

    private func deduplicatedByLocalDay(
        _ snapshots: [DailyAgeContributorSnapshot],
        calendar: Calendar
    ) -> [DailyAgeContributorSnapshot] {
        var best: [String: DailyAgeContributorSnapshot] = [:]
        for snapshot in snapshots {
            let key = localDayKey(snapshot.day, calendar: calendar)
            if let previous = best[key] {
                let previousScore = previous.quality.qualityScore + previous.quality.wearCoverage
                let currentScore = snapshot.quality.qualityScore + snapshot.quality.wearCoverage
                if currentScore > previousScore || (currentScore == previousScore && snapshot.day < previous.day) {
                    best[key] = snapshot
                }
            } else {
                best[key] = snapshot
            }
        }
        return best.values.sorted { $0.day < $1.day }
    }

    private func collectDomainValues(
        _ snapshots: [DailyAgeContributorSnapshot]
    ) -> [AgeContributorKind: [AgeMetricValue]] {
        var result: [AgeContributorKind: [AgeMetricValue]] = [:]
        for snapshot in snapshots {
            append(snapshot.cardioCapacity, to: .cardioCapacity, in: &result)
            append(snapshot.restingHeartRate, to: .restingHeartRate, in: &result)
            append(snapshot.bodyComposition, to: .bodyComposition, in: &result)
            append(snapshot.dailyMovement, to: .dailyMovement, in: &result)
            append(snapshot.lowModerateAerobicMinutes, to: .lowModerateAerobicActivity, in: &result)
            append(snapshot.vigorousAerobicMinutes, to: .vigorousAerobicActivity, in: &result)
            append(snapshot.strengthMinutes, to: .strengthActivity, in: &result)
            append(snapshot.sleepDurationHours, to: .sleepDuration, in: &result)
            if snapshot.sleepOnsetMinuteOfDay != nil && snapshot.sleepOffsetMinuteOfDay != nil {
                // A unit-bearing sentinel is used only for coverage counting;
                // the real regularity is calculated from timing below.
                append(
                    AgeMetricValue(value: 1, unit: "night", source: "canonical.sleep_timing"),
                    to: .sleepConsistency,
                    in: &result
                )
            }
        }
        return result
    }

    private func append(
        _ value: AgeMetricValue?,
        to kind: AgeContributorKind,
        in result: inout [AgeContributorKind: [AgeMetricValue]]
    ) {
        guard let value, isEligibleMetric(value) else { return }
        result[kind, default: []].append(value)
    }

    private func makeContributors(
        eligible: [DailyAgeContributorSnapshot],
        totalDays: Int,
        domainCoverage: [AgeContributorKind: Double],
        calendar: Calendar
    ) -> [AgeContributor] {
        let simple: [(AgeContributorKind, KeyPath<DailyAgeContributorSnapshot, AgeMetricValue?>, String, String)] = [
            (.cardioCapacity, \.cardioCapacity, "mL/kg/min", "median canonical VO2max"),
            (.restingHeartRate, \.restingHeartRate, "bpm", "median canonical nocturnal resting HR"),
            (.bodyComposition, \.bodyComposition, "canonical", "median canonical body composition"),
            (.dailyMovement, \.dailyMovement, "steps", "median canonical daily movement"),
            (.lowModerateAerobicActivity, \.lowModerateAerobicMinutes, "min/week", "weekly sum of HR zones 1-3"),
            (.vigorousAerobicActivity, \.vigorousAerobicMinutes, "min/week", "weekly sum of HR zones 4-5"),
            (.strengthActivity, \.strengthMinutes, "min/week", "weekly sum of completed strength workouts"),
            (.sleepDuration, \.sleepDurationHours, "hours", "median canonical main-sleep duration")
        ]

        var output: [AgeContributor] = []
        for (kind, keyPath, unit, transform) in simple {
            let values: [AgeMetricValue] = eligible.compactMap { value -> AgeMetricValue? in
                guard let metric = value[keyPath: keyPath], isEligibleMetric(metric) else { return nil }
                return metric
            }
            let coverage = domainCoverage[kind] ?? 0
            if values.isEmpty {
                output.append(absent(kind: kind, coverage: coverage))
                continue
            }
            let raw: Double
            let distribution: [Double]
            if kind == .lowModerateAerobicActivity || kind == .vigorousAerobicActivity || kind == .strengthActivity {
                let weekly = weeklySums(values: eligible, kind: kind, calendar: calendar)
                raw = median(weekly)
                distribution = weekly
            } else {
                distribution = values.map(\.value)
                raw = median(distribution)
            }
            let first = values[0]
            output.append(
                AgeContributor(
                    kind: kind,
                    rawAggregate: raw,
                    unit: kind == .bodyComposition ? first.unit : unit,
                    source: first.source,
                    coverage: coverage,
                    quality: average(values.map(\.quality)),
                    modelTransform: transform,
                    direction: .unknown,
                    effect: nil,
                    availability: coverage >= minimumCoverage ? .available : .absent(reason: .insufficientCoverage),
                    distribution: distribution
                )
            )
        }

        let sleepTiming = eligible.compactMap { snapshot -> (Int, Int)? in
            guard let onset = snapshot.sleepOnsetMinuteOfDay,
                  let offset = snapshot.sleepOffsetMinuteOfDay else { return nil }
            return (onset, offset)
        }
        let consistency = sleepConsistency(sleepTiming)
        let consistencyCoverage = domainCoverage[.sleepConsistency] ?? 0
        if let consistency {
            output.append(
                AgeContributor(
                    kind: .sleepConsistency,
                    rawAggregate: consistency,
                    unit: "score",
                    source: "canonical.sleep_timing",
                    coverage: consistencyCoverage,
                    quality: 1,
                    modelTransform: "timing regularity from onset and offset",
                    availability: consistencyCoverage >= minimumCoverage ? .available : .absent(reason: .insufficientCoverage),
                    distribution: [consistency]
                )
            )
        } else {
            output.append(absent(kind: .sleepConsistency, coverage: consistencyCoverage))
        }

        // Keep output order stable for persistence, comparison, and UI.
        return AgeContributorKind.allCases.compactMap { kind in
            output.first { $0.kind == kind }
        }
    }

    private func absent(kind: AgeContributorKind, coverage: Double) -> AgeContributor {
        AgeContributor(
            kind: kind,
            rawAggregate: nil,
            unit: "",
            source: "",
            coverage: coverage,
            quality: 0,
            modelTransform: "unavailable",
            availability: .absent(reason: coverage >= minimumCoverage ? .missingDomain : .insufficientCoverage)
        )
    }

    private func weeklySums(
        values: [DailyAgeContributorSnapshot],
        kind: AgeContributorKind,
        calendar: Calendar
    ) -> [Double] {
        var totals: [String: Double] = [:]
        for snapshot in values {
            let metric: AgeMetricValue?
            switch kind {
            case .lowModerateAerobicActivity: metric = snapshot.lowModerateAerobicMinutes
            case .vigorousAerobicActivity: metric = snapshot.vigorousAerobicMinutes
            case .strengthActivity: metric = snapshot.strengthMinutes
            default: metric = nil
            }
            guard let metric, isEligibleMetric(metric) else { continue }
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: snapshot.day)
            let key = "\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
            totals[key, default: 0] += metric.value
        }
        return totals.values.sorted()
    }

    private func sleepConsistency(_ timings: [(Int, Int)]) -> Double? {
        guard !timings.isEmpty else { return nil }
        let onsetMedian = median(timings.map { Double($0.0) })
        let offsetMedian = median(timings.map { Double($0.1) })
        let deviations = timings.map {
            (circularDistance(Double($0.0), onsetMedian) + circularDistance(Double($0.1), offsetMedian)) / 2
        }
        let meanDeviation = average(deviations)
        return min(1, max(0, 1 - meanDeviation / 720))
    }

    private func circularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: 1440)
        return min(raw, 1440 - raw)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[index - 1] + sorted[index]) / 2 : sorted[index]
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func isEligibleMetric(_ value: AgeMetricValue) -> Bool {
        value.isCanonical && value.value.isFinite && value.quality > 0 && value.coverage > 0
    }

    private func localDayCount(in interval: DateInterval, calendar: Calendar) -> Int {
        guard interval.start < interval.end else { return 0 }
        var count = 0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            count += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return count
    }

    private func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(c.era ?? 1)-\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
