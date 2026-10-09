import Foundation
import DomainKit
import DesignSystem
import AnalyticsKit

public enum BodyMetricID: String, Codable, CaseIterable, Hashable, Sendable {
    case strain
    case zones
    case steps
    case energy
    case acuteLoad
    case chronicLoad
    case monotony
    case fitnessFatigue
    case effort
}

public struct BodyMetricValue: Codable, Equatable, Sendable, Identifiable {
    public let id: BodyMetricID
    public let title: String
    public let value: String?
    public let unit: String
    public let state: MetricState
    public let confidence: String?
    public let source: String
    public let algorithmVersion: String?

    public init(id: BodyMetricID, title: String, value: String?, unit: String, state: MetricState, confidence: String? = nil, source: String, algorithmVersion: String? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.unit = unit
        self.state = state
        self.confidence = confidence
        self.source = source
        self.algorithmVersion = algorithmVersion
    }

    public var accessibilitySummary: String {
        guard let value else { return "\(title). \(state.title). \(state.detail)" }
        return [title, value, unit, confidence, state == .measuredZero ? state.title : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

public struct BodyCompositionContext: Codable, Equatable, Sendable {
    public let weight: String?
    public let height: String?
    public let bodyFat: String?
    public let state: MetricState
    public let source: String

    public init(weight: String?, height: String?, bodyFat: String?, state: MetricState, source: String) {
        self.weight = weight
        self.height = height
        self.bodyFat = bodyFat
        self.state = state
        self.source = source
    }
}

public enum BodyAgePresentation: Equatable, Sendable {
    case available(label: String, confidence: String, source: String)
    case unavailable(reason: String, state: MetricState)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Minutes spent in one heart-rate zone over a whole day.
public struct BodyZoneMinutes: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let minutes: Double

    public init(id: Int, name: String, minutes: Double) {
        self.id = id
        self.name = name
        self.minutes = minutes
    }
}

public struct BodyDaySnapshot: Codable, Equatable, Sendable {
    public let day: DayIdentity
    public let state: MetricState
    public let metrics: [BodyMetricValue]
    public let composition: BodyCompositionContext
    public let cardioAge: CardioAgeResult?
    public let looprAge: LooprAgeResult?
    public let source: String
    public let algorithmVersion: String?
    /// The day's time in heart-rate zones. Empty when the day has no usable
    /// heart rate, and the screen leaves the section out rather than drawing
    /// an empty chart.
    public let zoneMinutes: [BodyZoneMinutes]
    /// VO2 max inputs for the cardio fitness card. Nil for fixtures and for
    /// generations saved before the card existed; the card then stays off.
    public let cardioFitness: BodyCardioFitness?

    public init(day: DayIdentity, state: MetricState, metrics: [BodyMetricValue], composition: BodyCompositionContext, cardioAge: CardioAgeResult?, looprAge: LooprAgeResult?, source: String, algorithmVersion: String? = nil, zoneMinutes: [BodyZoneMinutes] = [], cardioFitness: BodyCardioFitness? = nil) {
        self.day = day
        self.state = state
        self.metrics = metrics
        self.composition = composition
        self.cardioAge = cardioAge
        self.looprAge = looprAge
        self.source = source
        self.algorithmVersion = algorithmVersion
        self.zoneMinutes = zoneMinutes
        self.cardioFitness = cardioFitness
    }

    private enum CodingKeys: String, CodingKey {
        case day, state, metrics, composition, cardioAge, looprAge, source, algorithmVersion, zoneMinutes, cardioFitness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(DayIdentity.self, forKey: .day)
        state = try container.decode(MetricState.self, forKey: .state)
        metrics = try container.decode([BodyMetricValue].self, forKey: .metrics)
        composition = try container.decode(BodyCompositionContext.self, forKey: .composition)
        cardioAge = try container.decodeIfPresent(CardioAgeResult.self, forKey: .cardioAge)
        looprAge = try container.decodeIfPresent(LooprAgeResult.self, forKey: .looprAge)
        source = try container.decode(String.self, forKey: .source)
        algorithmVersion = try container.decodeIfPresent(String.self, forKey: .algorithmVersion)
        // Generations written before zones existed decode with an empty list.
        zoneMinutes = try container.decodeIfPresent([BodyZoneMinutes].self, forKey: .zoneMinutes) ?? []
        cardioFitness = try container.decodeIfPresent(BodyCardioFitness.self, forKey: .cardioFitness)
    }

    /// The same snapshot with its cardio fitness inputs replaced.
    public func replacingCardioFitness(_ cardioFitness: BodyCardioFitness?) -> BodyDaySnapshot {
        BodyDaySnapshot(day: day, state: state, metrics: metrics, composition: composition, cardioAge: cardioAge,
            looprAge: looprAge, source: source, algorithmVersion: algorithmVersion, zoneMinutes: zoneMinutes,
            cardioFitness: cardioFitness)
    }

    public func replacingZoneMinutes(_ zoneMinutes: [BodyZoneMinutes]) -> BodyDaySnapshot {
        BodyDaySnapshot(day: day, state: state, metrics: metrics, composition: composition, cardioAge: cardioAge,
            looprAge: looprAge, source: source, algorithmVersion: algorithmVersion, zoneMinutes: zoneMinutes,
            cardioFitness: cardioFitness)
    }

    public func metric(_ id: BodyMetricID) -> BodyMetricValue? { metrics.first { $0.id == id } }

    public var cardioAgePresentation: BodyAgePresentation { Self.cardioAgePresentation(for: cardioAge) }

    /// Shared by the stored Cardio Age and one resolved from Apple Health.
    public static func cardioAgePresentation(for cardioAge: CardioAgeResult?) -> BodyAgePresentation {
        guard let cardioAge, cardioAge.isAvailable else {
            let reason = cardioAge?.absenceReason
            return .unavailable(
                reason: reason?.bodyDisplayReason ?? "Cardio Age has not been measured yet.",
                state: reason?.bodyMetricState ?? .absent
            )
        }
        guard cardioAge.source == .healthKit || cardioAge.source == .measuredCPET else {
            return .unavailable(reason: "Cardio Age needs VO₂ max from Apple Health or a lab test.", state: .absent)
        }
        return .available(
            label: cardioAge.displayLabel ?? "Cardio Age",
            confidence: "\(Int(cardioAge.confidence * 100))% confidence",
            source: cardioAge.source?.bodyDisplaySource ?? "VO₂ max estimate"
        )
    }

    public var looprAgePresentation: BodyAgePresentation {
        // DEC-02.12 keeps the composite age locked, including older stored
        // results. Do not let a persisted value reopen this presentation.
        .unavailable(reason: "Loopr Age is still being validated.", state: .absent)
    }
}

private extension LooprAgeAbsenceReason {
    var bodyDisplayReason: String {
        switch self {
        case .noVO2MaxSource: "Add a VO₂ max source to calculate Cardio Age."
        case .unsupportedPopulation: "This age estimate is not available for your profile."
        case .declinedReferenceCurve: "A reference comparison is required for this estimate."
        case .insufficientCoverage: "More consistent data is needed for this estimate."
        case .illnessOrLowWear: "Recent illness or limited strap wear prevents an estimate."
        case .staleData: "Your recent data is out of date."
        case .failedQuality: "Recent data did not meet the quality requirements."
        case .missingRequiredDomain, .missingDomain: "Required health data is missing."
        case .noMatchingModelVariant: "No matching age model is available."
        case .compositeNotYetValidated: "Loopr Age is not available yet."
        case .compositeValidationIncomplete: "Loopr Age validation is still in progress."
        case .modelNotSigned: "The verified Loopr Age model is unavailable."
        case .noModel: "The Loopr Age model is unavailable."
        }
    }

    var bodyMetricState: MetricState {
        switch self {
        case .staleData: .stale
        case .insufficientCoverage, .illnessOrLowWear, .failedQuality, .compositeValidationIncomplete: .lowConfidence
        case .unsupportedPopulation, .noMatchingModelVariant: .unsupportedHardware
        case .noVO2MaxSource, .declinedReferenceCurve, .missingRequiredDomain, .compositeNotYetValidated,
             .modelNotSigned, .noModel, .missingDomain: .absent
        }
    }
}

private extension VO2MaxSourceKind {
    var bodyDisplaySource: String {
        switch self {
        case .measuredCPET: "Lab fitness test"
        case .healthKit: "From Apple Health VO₂ max"
        case .looprExerciseEstimate: "Loopr exercise estimate"
        }
    }
}

private extension ConfidenceTier {
    var bodyDisplayConfidence: String {
        switch self {
        case .established: "Established confidence"
        case .provisional: "Provisional confidence"
        case .lowConfidence: "Low confidence"
        case .unavailable: "Confidence unavailable"
        }
    }
}

public protocol BodyRepository: Sendable {
    func readBodyDay(for day: DayIdentity) async throws -> BodyDaySnapshot?
}

public actor InMemoryBodyRepository: BodyRepository {
    private var values: [DayIdentity: BodyDaySnapshot]
    public init(values: [DayIdentity: BodyDaySnapshot] = [:]) { self.values = values }
    public func readBodyDay(for day: DayIdentity) async throws -> BodyDaySnapshot? { values[day] }
    public func replace(_ snapshot: BodyDaySnapshot, for day: DayIdentity) { values[day] = snapshot }
    public func deleteAll() { values.removeAll(keepingCapacity: true) }
}
