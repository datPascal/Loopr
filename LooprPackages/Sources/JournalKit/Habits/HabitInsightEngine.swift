import Foundation
import AnalyticsKit
import DomainKit

public struct HabitInsightEngine: Sendable {
    public let policy: HabitImpactPolicy
    private let calendarProvider: any CalendarProviding

    public init(
        policy: HabitImpactPolicy = .default,
        calendarProvider: any CalendarProviding = SystemCalendarProvider()
    ) {
        self.policy = policy
        self.calendarProvider = calendarProvider
    }

    @discardableResult
    public func recalculateAll(
        store: any HabitStore,
        calculatedAt: Date
    ) async throws -> [HabitImpactEstimate] {
        let definitions = try await store.definitions(includeArchived: true)
        let records = try await store.dayRecords()
        let outcomes = try await store.outcomes()
        let outcomeExclusions = Dictionary(uniqueKeysWithValues: try await store.outcomeExclusions().map { ($0.behaviorDay, $0.reason) })
        let previous = Dictionary(uniqueKeysWithValues: try await store.estimates().map { ($0.habitID, $0) })
        let sourceDays = outcomes.map(\.behaviorDay) + records.map(\.behaviorDay)
        guard let latest = sourceDays.max(by: { $0.habitKey < $1.habitKey }) else {
            let day = DayBoundaryCalculator.boundary(
                containing: calculatedAt,
                calendar: calendarProvider,
                timeZone: .current
            )?.identity ?? DayIdentity(year: 1970, month: 1, day: 1)
            let estimates = definitions.map {
                HabitImpactEstimate(
                    habitID: $0.id,
                    status: .unavailable,
                    yesCount: 0,
                    noCount: 0,
                    eligibleDayCount: 0,
                    excludedDayCount: 0,
                    windowStart: day,
                    windowEnd: day,
                    calculatedAt: calculatedAt
                )
            }
            for estimate in estimates { try await store.saveEstimate(estimate) }
            return estimates
        }
        let start = addDays(-(policy.windowDays - 1), to: latest) ?? latest
        let windowRecords = records.filter {
            $0.behaviorDay.habitKey >= start.habitKey && $0.behaviorDay.habitKey <= latest.habitKey
        }
        let windowOutcomes = outcomes.filter {
            $0.behaviorDay.habitKey >= start.habitKey && $0.behaviorDay.habitKey <= latest.habitKey
        }
        let result = try definitions.map { definition in
            try calculate(
                definition: definition,
                activeDefinitions: definitions.filter { !$0.isArchived },
                records: windowRecords,
                outcomes: windowOutcomes,
                outcomeExclusions: outcomeExclusions,
                previous: previous[definition.id],
                windowStart: start,
                windowEnd: latest,
                calculatedAt: calculatedAt
            )
        }
        for estimate in result { try await store.saveEstimate(estimate) }
        return result
    }

    private func calculate(
        definition: HabitDefinition,
        activeDefinitions: [HabitDefinition],
        records: [HabitDayRecord],
        outcomes: [HabitOutcomeSnapshot],
        outcomeExclusions: [DayIdentity: HabitExclusionReason],
        previous: HabitImpactEstimate?,
        windowStart: DayIdentity,
        windowEnd: DayIdentity,
        calculatedAt: Date
    ) throws -> HabitImpactEstimate {
        let outcomeByDay = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.behaviorDay, $0) })
        var eligibleResponses: [(HabitResponse, HabitOutcomeSnapshot)] = []
        var exclusions: [HabitExclusion] = []
        for record in records {
            guard let response = record.response(for: definition.id) else { continue }
            if let reason = HabitEligibility.exclusion(for: response, calendar: calendarProvider) {
                exclusions.append(.init(day: record.behaviorDay, reason: reason))
                continue
            }
            guard let outcome = outcomeByDay[record.behaviorDay] else {
                exclusions.append(.init(day: record.behaviorDay, reason: outcomeExclusions[record.behaviorDay] ?? .missingMainSleep))
                continue
            }
            if outcome.metrics[.recoveryScore] == nil {
                exclusions.append(.init(day: record.behaviorDay, reason: .missingMetric))
            }
            eligibleResponses.append((response, outcome))
        }

        let recoveryPairs = eligibleResponses.compactMap { response, outcome -> (HabitResponse, HabitOutcomeSnapshot)? in
            outcome.metrics[.recoveryScore] == nil ? nil : (response, outcome)
        }
        let yesCount = recoveryPairs.filter { $0.0.answer == .yes }.count
        let noCount = recoveryPairs.filter { $0.0.answer == .no }.count
        let eligibleDayCount = recoveryPairs.count
        if eligibleResponses.isEmpty {
            return HabitImpactEstimate(
                habitID: definition.id,
                status: .unavailable,
                yesCount: 0,
                noCount: 0,
                eligibleDayCount: 0,
                excludedDayCount: exclusions.count,
                exclusions: exclusions,
                windowStart: windowStart,
                windowEnd: windowEnd,
                calculatedAt: calculatedAt
            )
        }

        let overlapping = overlap(
            target: definition.id,
            candidates: activeDefinitions.map(\.id).filter { $0 != definition.id },
            records: records,
            outcomes: outcomeByDay
        )
        let mature = yesCount >= policy.maturePerGroup
            && noCount >= policy.maturePerGroup
            && eligibleDayCount >= policy.matureEligibleDays
        var metricEstimates: [HabitMetricEstimate] = []
        var metricMaturity: [HabitOutcomeMetricID: Bool] = [:]
        for metricID in HabitOutcomeMetricID.allCases {
            let pairs = eligibleResponses.compactMap { response, outcome -> (HabitResponse, HabitOutcomeSnapshot, Double)? in
                guard let value = outcome.metrics[metricID], value.isFinite else { return nil }
                return (response, outcome, value)
            }
            let metricYes = pairs.filter { $0.0.answer == .yes }.count
            let metricNo = pairs.filter { $0.0.answer == .no }.count
            metricMaturity[metricID] = metricYes >= policy.maturePerGroup
                && metricNo >= policy.maturePerGroup
                && pairs.count >= policy.matureEligibleDays
            guard metricYes > 0, metricNo > 0 else {
                metricEstimates.append(.init(metricID: metricID, yesMean: nil, noMean: nil, rawDifference: nil, adjustedDifference: nil, intervalLower: nil, intervalUpper: nil))
                continue
            }
            let rows = pairs.compactMap { response, outcome, value -> BinaryExposureRow? in
                guard let ordinal = dayOrdinal(response.behaviorDay), let weekday = weekday(response.behaviorDay) else { return nil }
                let nuisances = nuisanceValues(
                    target: definition.id,
                    candidates: activeDefinitions.map(\.id).filter { $0 != definition.id },
                    day: response.behaviorDay,
                    records: records
                )
                return BinaryExposureRow(
                    dayOrdinal: ordinal,
                    outcome: value,
                    exposure: response.answer == .yes,
                    weekday: weekday,
                    priorDayStrain: outcome.priorDayStrain,
                    nuisanceExposures: nuisances
                )
            }
            let baseline = outcomes.compactMap { outcome -> BinaryExposureBaselineValue? in
                guard let ordinal = dayOrdinal(outcome.behaviorDay), let value = outcome.metrics[metricID], value.isFinite else { return nil }
                return .init(dayOrdinal: ordinal, value: value)
            }
            let analyzerPolicy = BinaryExposurePolicy(
                baselineWindowDays: policy.trailingBaselineDays,
                minimumBaselineValues: policy.minimumBaselineDays,
                ridgeLambda: policy.ridgeLambda,
                bootstrapReplicates: metricMaturity[metricID] == true && overlapping == nil
                    ? policy.bootstrapReplicates : 0,
                blockLength: policy.bootstrapBlockDays
            )
            let seed = BinaryExposureAnalyzer.deterministicSeed([
                definition.id.rawValue.uuidString,
                metricID.rawValue,
                windowEnd.habitKey,
                policy.algorithmVersion
            ])
            let result = try? BinaryExposureAnalyzer.analyze(
                rows: rows,
                baselineValues: baseline,
                policy: analyzerPolicy,
                seed: seed,
                cancellationCheck: {
                    if Task.isCancelled { throw BinaryExposureError.cancelled }
                }
            )
            metricEstimates.append(.init(
                metricID: metricID,
                yesMean: result?.yesMean,
                noMean: result?.noMean,
                rawDifference: result?.rawDifference,
                adjustedDifference: result?.adjustedDifference,
                intervalLower: result?.intervalLower,
                intervalUpper: result?.intervalUpper,
                bootstrapPValue: result?.twoSidedPValue,
                adjustedRowCount: result?.adjustedRowCount ?? 0
            ))
        }

        let secondaryIndices = metricEstimates.indices.filter { metricEstimates[$0].metricID != .recoveryScore }
        let adjustedP = BinaryExposureAnalyzer.holmAdjusted(secondaryIndices.map { metricEstimates[$0].bootstrapPValue })
        for (offset, index) in secondaryIndices.enumerated() {
            let estimate = metricEstimates[index]
            metricEstimates[index] = withClassification(
                estimate,
                adjustedPValue: adjustedP[offset],
                mature: metricMaturity[estimate.metricID] == true
            )
        }
        if let recoveryIndex = metricEstimates.firstIndex(where: { $0.metricID == .recoveryScore }) {
            metricEstimates[recoveryIndex] = withClassification(
                metricEstimates[recoveryIndex],
                adjustedPValue: nil,
                mature: metricMaturity[.recoveryScore] == true
            )
        }

        let adjustedRows = metricEstimates.first(where: { $0.metricID == .recoveryScore })?.adjustedRowCount ?? 0
        let reachesMatureGate = mature && adjustedRows >= policy.minimumAdjustedRows
        let status: HabitInsightStatus
        if let overlapping {
            status = .cannotSeparate
            _ = overlapping
        } else if yesCount < policy.earlyPerGroup || noCount < policy.earlyPerGroup {
            status = staleStatusIfNeeded(previous: previous) ?? .collecting
        } else if !reachesMatureGate {
            status = staleStatusIfNeeded(previous: previous) ?? .earlySignal
        } else if metricEstimates.first(where: { $0.metricID == .recoveryScore })?.isClear == true {
            status = .clearAssociation
        } else {
            status = .noClearAssociation
        }
        let lastValid = status == .stale
            ? previous.flatMap { old in old.metric(.recoveryScore).map { .init(validThrough: old.windowEnd, recovery: $0) } } ?? previous?.lastValidEstimate
            : nil
        return HabitImpactEstimate(
            habitID: definition.id,
            status: status,
            yesCount: yesCount,
            noCount: noCount,
            eligibleDayCount: eligibleDayCount,
            excludedDayCount: exclusions.count,
            metrics: metricEstimates,
            exclusions: exclusions,
            overlappingHabitID: overlapping,
            windowStart: windowStart,
            windowEnd: windowEnd,
            calculatedAt: calculatedAt,
            algorithmVersion: policy.algorithmVersion,
            lastValidEstimate: lastValid
        )
    }

    private func withClassification(
        _ estimate: HabitMetricEstimate,
        adjustedPValue: Double?,
        mature: Bool
    ) -> HabitMetricEstimate {
        let threshold = policy.practicalThresholds[estimate.metricID] ?? .infinity
        let practical = abs(estimate.adjustedDifference ?? 0) >= threshold
        let enoughAdjustedRows = estimate.adjustedRowCount >= policy.minimumAdjustedRows
        let clear: Bool
        if estimate.metricID == .recoveryScore {
            clear = mature && enoughAdjustedRows && practical
                && ((estimate.intervalLower ?? 0) > 0 || (estimate.intervalUpper ?? 0) < 0)
        } else {
            clear = mature && enoughAdjustedRows && practical && (adjustedPValue ?? 1) < 0.05
        }
        return HabitMetricEstimate(
            metricID: estimate.metricID,
            yesMean: estimate.yesMean,
            noMean: estimate.noMean,
            rawDifference: estimate.rawDifference,
            adjustedDifference: estimate.adjustedDifference,
            intervalLower: estimate.intervalLower,
            intervalUpper: estimate.intervalUpper,
            bootstrapPValue: estimate.bootstrapPValue,
            adjustedPValue: adjustedPValue,
            adjustedRowCount: estimate.adjustedRowCount,
            isClear: clear
        )
    }

    private func staleStatusIfNeeded(previous: HabitImpactEstimate?) -> HabitInsightStatus? {
        guard let previous, [.clearAssociation, .noClearAssociation, .stale].contains(previous.status) else { return nil }
        return .stale
    }

    private func overlap(
        target: HabitID,
        candidates: [HabitID],
        records: [HabitDayRecord],
        outcomes: [DayIdentity: HabitOutcomeSnapshot]
    ) -> HabitID? {
        for candidate in candidates.sorted() {
            var targetValues: [Bool] = []
            var otherValues: [Bool] = []
            for record in records where outcomes[record.behaviorDay]?.metrics[.recoveryScore] != nil {
                guard let lhs = record.response(for: target), let rhs = record.response(for: candidate),
                      HabitEligibility.isEligible(lhs, calendar: calendarProvider),
                      HabitEligibility.isEligible(rhs, calendar: calendarProvider),
                      lhs.answer != .skipped, rhs.answer != .skipped else { continue }
                targetValues.append(lhs.answer == .yes)
                otherValues.append(rhs.answer == .yes)
            }
            let yes = targetValues.filter { $0 }.count, no = targetValues.filter { !$0 }.count
            let otherYes = otherValues.filter { $0 }.count, otherNo = otherValues.filter { !$0 }.count
            guard yes >= policy.earlyPerGroup, no >= policy.earlyPerGroup,
                  otherYes >= policy.earlyPerGroup, otherNo >= policy.earlyPerGroup else { continue }
            let comparison = BinaryExposureAnalyzer.phiAndDiscordance(target: targetValues, other: otherValues)
            if abs(comparison.phi ?? 0) >= policy.overlapPhiThreshold
                || comparison.targetYesOtherNo < policy.minimumDiscordantDays
                || comparison.targetNoOtherYes < policy.minimumDiscordantDays {
                return candidate
            }
        }
        return nil
    }

    private func nuisanceValues(
        target: HabitID,
        candidates: [HabitID],
        day: DayIdentity,
        records: [HabitDayRecord]
    ) -> [Double] {
        let selectedCandidates = Array(candidates.prefix(9))
        guard let record = records.first(where: { $0.behaviorDay == day }) else {
            return Array(repeating: 0, count: selectedCandidates.count * 2)
        }
        return selectedCandidates.flatMap { candidate -> [Double] in
            guard candidate != target, let response = record.response(for: candidate),
                  HabitEligibility.isEligible(response, calendar: calendarProvider), response.answer != .skipped else {
                return [0, 0]
            }
            return [response.answer == .yes ? 1 : 0, 1]
        }
    }

    private func dayOrdinal(_ day: DayIdentity) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        return Int(date.timeIntervalSince1970 / 86_400)
    }

    private func weekday(_ day: DayIdentity) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        return calendar.component(.weekday, from: date) - 1
    }

    private func addDays(_ value: Int, to day: DayIdentity) -> DayIdentity? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let output = calendar.date(byAdding: .day, value: value, to: date) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: output)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return DayIdentity(year: year, month: month, day: day)
    }
}

public enum HabitInsightOrdering {
    public static func sorted(
        estimates: [HabitImpactEstimate],
        definitions: [HabitDefinition]
    ) -> [HabitImpactEstimate] {
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        return estimates.sorted { lhs, rhs in
            let lhsRank = rank(lhs.status, archived: byID[lhs.habitID]?.isArchived == true)
            let rhsRank = rank(rhs.status, archived: byID[rhs.habitID]?.isArchived == true)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.status == .clearAssociation, rhs.status == .clearAssociation {
                let lhsEffect = abs(lhs.metric(.recoveryScore)?.adjustedDifference ?? 0)
                let rhsEffect = abs(rhs.metric(.recoveryScore)?.adjustedDifference ?? 0)
                if lhsEffect != rhsEffect { return lhsEffect > rhsEffect }
                let lhsWidth = (lhs.metric(.recoveryScore)?.intervalUpper ?? .infinity) - (lhs.metric(.recoveryScore)?.intervalLower ?? -.infinity)
                let rhsWidth = (rhs.metric(.recoveryScore)?.intervalUpper ?? .infinity) - (rhs.metric(.recoveryScore)?.intervalLower ?? -.infinity)
                if lhsWidth != rhsWidth { return lhsWidth < rhsWidth }
            }
            return lhs.habitID < rhs.habitID
        }
    }

    private static func rank(_ status: HabitInsightStatus, archived: Bool) -> Int {
        if archived { return 8 }
        return switch status {
        case .clearAssociation: 0
        case .noClearAssociation: 1
        case .earlySignal: 2
        case .collecting: 3
        case .enoughData: 4
        case .cannotSeparate: 5
        case .stale: 6
        case .unavailable: 7
        }
    }
}
