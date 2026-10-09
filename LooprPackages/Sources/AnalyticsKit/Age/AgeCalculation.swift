import Foundation
import DomainKit

public enum AgeDerivationError: Error, Equatable, Sendable {
    case invalidDateOfBirth
    case invalidModelWindow
}

public struct RealAgeCalculator: Sendable {
    public init() {}

    /// Returns completed Gregorian calendar years in the supplied local time
    /// zone.  The comparison is calendar-day based, so a timezone change does
    /// not silently turn a birthday into a different age during the same day.
    public func completedYears(
        dateOfBirth: Date,
        on calculationDate: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let birth = calendar.dateComponents([.era, .year, .month, .day], from: dateOfBirth)
        let current = calendar.dateComponents([.era, .year, .month, .day], from: calculationDate)
        guard let birthEra = birth.era,
              let birthYear = birth.year,
              let birthMonth = birth.month,
              let birthDay = birth.day,
              let currentEra = current.era,
              let currentYear = current.year,
              let currentMonth = current.month,
              let currentDay = current.day,
              birthEra == currentEra else {
            return nil
        }
        let years = currentYear - birthYear
        guard years >= 0 else { return nil }
        if hasBirthdayOccurred(
            birthMonth: birthMonth,
            birthDay: birthDay,
            currentYear: currentYear,
            currentMonth: currentMonth,
            currentDay: currentDay,
            calendar: calendar
        ) {
            return years
        }
        return max(0, years - 1)
    }

    private func hasBirthdayOccurred(
        birthMonth: Int,
        birthDay: Int,
        currentYear: Int,
        currentMonth: Int,
        currentDay: Int,
        calendar: Calendar
    ) -> Bool {
        var effectiveDay = birthDay
        if birthMonth == 2 && birthDay == 29 {
            let leap = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: currentYear, month: 2, day: 1)) ?? .distantPast)?.count == 29
            effectiveDay = leap ? 29 : 28
        }
        return currentMonth > birthMonth || (currentMonth == birthMonth && currentDay >= effectiveDay)
    }
}

public struct CardioAgeCalculator: Sendable {
    public init() {}

    public func calculate(
        vo2max: Double,
        referenceGroup: FriendReferenceGroup?,
        curve: FriendReferenceCurve,
        source: VO2MaxSourceKind? = nil,
        confidence: Double = 1,
        calculationAge: Int? = nil
    ) -> CardioAgeResult {
        guard let referenceGroup,
              vo2max.isFinite,
              vo2max > 0,
              curve.points.count >= 2,
              calculationAge.map({ curve.supportedAgeRange?.contains(Double($0)) ?? false }) ?? true,
              isValidCurve(curve, group: referenceGroup) else {
            return .unavailable(
                reason: referenceGroup == nil ? .declinedReferenceCurve : .unsupportedPopulation,
                referenceVersion: curve.referenceVersion,
                source: source,
                referenceGroup: referenceGroup
            )
        }

        let values = curve.values(for: referenceGroup)
        guard let first = values.first, let last = values.last else {
            return .unavailable(
                reason: .unsupportedPopulation,
                referenceVersion: curve.referenceVersion,
                source: source,
                referenceGroup: referenceGroup
            )
        }

        if vo2max >= first.median {
            return available(
                age: first.age,
                label: "\(Self.displayInteger(first.age)) or younger",
                vo2max: vo2max,
                source: source,
                referenceGroup: referenceGroup,
                curve: curve,
                confidence: confidence
            )
        }
        if vo2max <= last.median {
            return available(
                age: last.age,
                label: "\(Self.displayInteger(last.age)) or older",
                vo2max: vo2max,
                source: source,
                referenceGroup: referenceGroup,
                curve: curve,
                confidence: confidence
            )
        }

        for pair in zip(values, values.dropFirst()) {
            let upper = pair.0
            let lower = pair.1
            guard upper.median >= lower.median else { continue }
            if upper.median >= vo2max && vo2max >= lower.median {
                let fraction = (upper.median - vo2max) / (upper.median - lower.median)
                let age = upper.age + fraction * (lower.age - upper.age)
                return available(
                    age: age,
                    label: nil,
                    vo2max: vo2max,
                    source: source,
                    referenceGroup: referenceGroup,
                    curve: curve,
                    confidence: confidence
                )
            }
        }

        return .unavailable(
            reason: .unsupportedPopulation,
            referenceVersion: curve.referenceVersion,
            source: source,
            referenceGroup: referenceGroup
        )
    }

    private func available(
        age: Double,
        label: String?,
        vo2max: Double,
        source: VO2MaxSourceKind?,
        referenceGroup: FriendReferenceGroup,
        curve: FriendReferenceCurve,
        confidence: Double
    ) -> CardioAgeResult {
        CardioAgeResult(
            ageYears: age,
            displayLabel: label,
            status: .available,
            vo2max: vo2max,
            source: source,
            referenceGroup: referenceGroup,
            referenceVersion: curve.referenceVersion,
            confidence: min(max(confidence, 0), 1),
            absenceReason: nil
        )
    }

    private func isValidCurve(_ curve: FriendReferenceCurve, group: FriendReferenceGroup) -> Bool {
        guard curve.points.allSatisfy({ $0.median(for: group).isFinite && $0.median(for: group) > 0 }) else {
            return false
        }
        for pair in zip(curve.points, curve.points.dropFirst()) {
            guard pair.0.calculationAge < pair.1.calculationAge,
                  pair.0.median(for: group) >= pair.1.median(for: group) else {
                return false
            }
        }
        return true
    }

    private static func displayInteger(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}

public struct AgeDerivationInput: Sendable {
    public let dateOfBirth: Date
    public let calculationDate: Date
    public let timeZone: TimeZone
    public let modelWindow: DateInterval
    public let referenceGroup: FriendReferenceGroup?
    public let measuredCPET: [MeasuredCPETSample]
    public let healthKitVO2Max: [HealthKitVO2MaxSample]
    public let looprExerciseEstimate: LooprExerciseVO2MaxEstimate?
    public let contributorSnapshots: [DailyAgeContributorSnapshot]
    public let modelVersion: Int
    public let referenceVersion: Int

    public init(
        dateOfBirth: Date,
        calculationDate: Date,
        timeZone: TimeZone = .autoupdatingCurrent,
        modelWindow: DateInterval,
        referenceGroup: FriendReferenceGroup?,
        measuredCPET: [MeasuredCPETSample] = [],
        healthKitVO2Max: [HealthKitVO2MaxSample] = [],
        looprExerciseEstimate: LooprExerciseVO2MaxEstimate? = nil,
        contributorSnapshots: [DailyAgeContributorSnapshot] = [],
        modelVersion: Int = 1,
        referenceVersion: Int = 1
    ) {
        self.dateOfBirth = dateOfBirth
        self.calculationDate = calculationDate
        self.timeZone = timeZone
        self.modelWindow = modelWindow
        self.referenceGroup = referenceGroup
        self.measuredCPET = measuredCPET
        self.healthKitVO2Max = healthKitVO2Max
        self.looprExerciseEstimate = looprExerciseEstimate
        self.contributorSnapshots = contributorSnapshots
        self.modelVersion = modelVersion
        self.referenceVersion = referenceVersion
    }
}

public struct AgeDerivationEngine: Sendable {
    public let referenceCurve: FriendReferenceCurve
    public let selector: VO2MaxSourceSelector
    public let realAgeCalculator: RealAgeCalculator
    public let cardioAgeCalculator: CardioAgeCalculator
    public let contributorAggregator: AgeContributorAggregator

    public init(
        referenceCurve: FriendReferenceCurve = .version1,
        selector: VO2MaxSourceSelector = VO2MaxSourceSelector(),
        realAgeCalculator: RealAgeCalculator = RealAgeCalculator(),
        cardioAgeCalculator: CardioAgeCalculator = CardioAgeCalculator(),
        contributorAggregator: AgeContributorAggregator = AgeContributorAggregator()
    ) {
        self.referenceCurve = referenceCurve
        self.selector = selector
        self.realAgeCalculator = realAgeCalculator
        self.cardioAgeCalculator = cardioAgeCalculator
        self.contributorAggregator = contributorAggregator
    }

    public func derive(_ input: AgeDerivationInput) async throws -> LooprAgeResult {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        guard input.modelWindow.duration >= 0 else { throw AgeDerivationError.invalidModelWindow }
        guard let realAge = realAgeCalculator.completedYears(
            dateOfBirth: input.dateOfBirth,
            on: input.calculationDate,
            timeZone: input.timeZone
        ) else {
            throw AgeDerivationError.invalidDateOfBirth
        }
        try Task.checkCancellation()

        let selection = selector.select(
            now: input.calculationDate,
            measuredCPET: input.measuredCPET,
            healthKit: input.healthKitVO2Max,
            looprEstimate: input.looprExerciseEstimate,
            timeZone: input.timeZone
        )
        let cardioAge: CardioAgeResult?
        switch selection {
        case .measuredCPET(let value, _):
            cardioAge = cardioAgeCalculator.calculate(
                vo2max: value,
                referenceGroup: input.referenceGroup,
                curve: referenceCurve,
                source: .measuredCPET,
                calculationAge: realAge
            )
        case .healthKit(let value, _):
            cardioAge = cardioAgeCalculator.calculate(
                vo2max: value,
                referenceGroup: input.referenceGroup,
                curve: referenceCurve,
                source: .healthKit,
                calculationAge: realAge
            )
        case .unavailable(let reason):
            cardioAge = .unavailable(reason: reason, referenceVersion: referenceCurve.referenceVersion)
        }
        try Task.checkCancellation()

        let aggregation = contributorAggregator.aggregate(
            snapshots: input.contributorSnapshots,
            modelWindow: input.modelWindow,
            timeZone: input.timeZone
        )
        try Task.checkCancellation()

        return LooprAgeResult(
            realAgeYears: realAge,
            cardioAge: cardioAge,
            modelWindow: input.modelWindow,
            contributors: aggregation.contributors,
            coverage: aggregation.coverage,
            confidence: confidence(for: aggregation, cardioAge: cardioAge),
            confidenceTier: aggregation.confidenceTier,
            modelVersion: input.modelVersion,
            referenceVersion: referenceCurve.referenceVersion,
            generatedAt: input.calculationDate,
            absenceReason: .compositeNotYetValidated
        )
    }

    private func confidence(for aggregation: AgeAggregationResult, cardioAge: CardioAgeResult?) -> Double {
        guard cardioAge?.isAvailable == true else { return 0 }
        switch aggregation.confidenceTier {
        case .established: return min(1, max(0, aggregation.coverage.coverageFraction))
        case .provisional: return min(0.79, max(0.5, aggregation.coverage.coverageFraction))
        case .lowConfidence: return min(0.49, max(0.01, aggregation.coverage.coverageFraction))
        case .unavailable: return 0
        }
    }
}

public protocol AgeResultRepository: CanonicalAgeResultRepository where Value == LooprAgeResult {
    func save(_ result: LooprAgeResult) async throws
}

public actor InMemoryAgeResultRepository: AgeResultRepository {
    public typealias Value = LooprAgeResult
    private var result: LooprAgeResult?

    public init() {}

    public func save(_ result: LooprAgeResult) async throws { self.result = result }
    public func readLatestAgeResult() async throws -> LooprAgeResult? { result }
}
