import AnalyticsKit
import Foundation
import HealthKitBridge
import NotificationKit
import ProfileKit

// The facts the onboarding copy states, taken from the code that acts on
// them. Tests compare these with the real HealthKit request, the notification
// families and the analytics constants, so a change there cannot leave the
// copy saying something the app no longer does.

/// Exactly what the Apple Health step's one iOS sheet asks for.
public struct OnboardingHealthRequest: Equatable, Sendable {
    /// Types Loopr asks to save to Apple Health.
    public var writes: Set<ExportMetricKind>
    /// Quantities Loopr asks to read, one value per day, for its charts.
    public var reads: Set<HealthHistoryQuantity>
    /// Whether the sheet also asks to read sleep.
    public var readsSleep: Bool

    public init(writes: Set<ExportMetricKind>, reads: Set<HealthHistoryQuantity>, readsSleep: Bool) {
        self.writes = writes
        self.reads = reads.intersection(Set(HealthHistoryQuantity.allCases))
        self.readsSleep = readsSleep
    }

    /// The request a fresh install makes: every exported metric, every
    /// history quantity and sleep. The app passes its live request instead
    /// when it has one.
    public static let freshInstall = OnboardingHealthRequest(
        writes: Set(ExportMetricKind.allCases),
        reads: Set(HealthHistoryQuantity.allCases),
        readsSleep: true
    )

    /// Reading anything means Loopr imports history after the sheet closes.
    public var importsHistory: Bool { !reads.isEmpty || readsSleep }

    /// The saved types in the order the step lists them.
    public var orderedWrites: [OnboardingHealthType] {
        OnboardingHealthType.writeOrder.filter { type in
            if case .write(let kind) = type { writes.contains(kind) } else { false }
        }
    }

    /// The read types in the order the step lists them, sleep included.
    public var orderedReads: [OnboardingHealthType] {
        OnboardingHealthType.readOrder.filter { type in
            switch type {
            case .read(let quantity): reads.contains(quantity)
            case .readSleep: readsSleep
            case .write: false
            }
        }
    }
}

/// One line of the Apple Health step: a type Loopr saves or reads.
public enum OnboardingHealthType: Hashable, Sendable, Identifiable {
    case write(ExportMetricKind)
    case read(HealthHistoryQuantity)
    case readSleep

    public var id: String {
        switch self {
        case .write(let kind): "write-\(kind.rawValue)"
        case .read(let quantity): "read-\(quantity.rawValue)"
        case .readSleep: "read-sleep"
        }
    }

    /// The name the step shows. It follows the names on the iOS permission
    /// sheet, so the person can match the two.
    public var name: String {
        switch self {
        case .write(let kind):
            switch kind {
            case .heartRate: "Heart rate"
            case .restingHeartRate: "Resting heart rate"
            case .heartRateVariabilitySDNN: "Heart rate variability"
            case .respiratoryRate: "Respiratory rate"
            case .sleepStages: "Sleep"
            case .steps: "Steps"
            case .activeEnergy: "Active energy"
            case .completedWorkout: "Workouts"
            }
        case .read(let quantity):
            switch quantity {
            case .restingHeartRate: "Resting heart rate"
            case .heartRateVariabilitySDNN: "Heart rate variability"
            case .respiratoryRate: "Respiratory rate"
            case .oxygenSaturation: "Blood oxygen"
            case .vo2Max: "Cardio fitness"
            case .heartRate: "Heart rate"
            case .steps: "Steps"
            case .activeEnergy: "Active energy"
            }
        case .readSleep: "Sleep"
        }
    }

    public var symbol: String {
        switch self {
        case .write(let kind):
            switch kind {
            case .heartRate: "heart"
            case .restingHeartRate: "heart.text.square"
            case .heartRateVariabilitySDNN: "waveform.path.ecg"
            case .respiratoryRate: "lungs"
            case .sleepStages: "bed.double"
            case .steps: "figure.walk"
            case .activeEnergy: "flame"
            case .completedWorkout: "figure.run"
            }
        case .read(let quantity):
            switch quantity {
            case .restingHeartRate: "heart.text.square"
            case .heartRateVariabilitySDNN: "waveform.path.ecg"
            case .respiratoryRate: "lungs"
            case .oxygenSaturation: "drop"
            case .vo2Max: "figure.run.circle"
            case .heartRate: "heart"
            case .steps: "figure.walk"
            case .activeEnergy: "flame"
            }
        case .readSleep: "bed.double"
        }
    }

    static let writeOrder: [OnboardingHealthType] = [
        .write(.heartRate), .write(.restingHeartRate), .write(.heartRateVariabilitySDNN),
        .write(.respiratoryRate), .write(.sleepStages), .write(.steps), .write(.activeEnergy),
        .write(.completedWorkout)
    ]

    static let readOrder: [OnboardingHealthType] = [
        .readSleep, .read(.heartRate), .read(.restingHeartRate), .read(.heartRateVariabilitySDNN),
        .read(.respiratoryRate), .read(.vo2Max), .read(.steps),
        .read(.activeEnergy)
    ]
}

/// How the notifications step groups what Loopr sends.
public enum OnboardingNotificationGroup: String, CaseIterable, Sendable {
    case workouts
    case breathing
    case band
    /// Families that stay off until the person turns them on.
    case offUntilChosen

    /// The group a family belongs to. Families nothing sends yet have no
    /// group: the step does not mention them.
    public static func group(for family: NotificationFamily) -> OnboardingNotificationGroup? {
        if NotificationFamily.unwired.contains(family) { return nil }
        if !family.isEnabledByDefault { return .offUntilChosen }
        switch family {
        case .detectedWorkouts, .workoutCompletion: return .workouts
        case .breathingCompletion: return .breathing
        case .battery, .chargeGuidance, .disconnect, .staleData: return .band
        case .recoveryReadiness, .validatedHealthChanges, .goals, .journaling, .briefings,
             .windDown, .hydration, .cycleReminders, .highHeartRate, .lowHeartRate,
             .overnightCheck, .cardioFitness:
            // Only reached if one of these becomes on by default. The test
            // for this mapping fails first, so the copy gets a line for it.
            return nil
        }
    }

    /// The families in this group, in declaration order.
    public var families: [NotificationFamily] {
        NotificationFamily.allCases.filter { Self.group(for: $0) == self }
    }
}

/// Numbers the finish and sleep steps quote.
public enum OnboardingFacts {
    /// Nights of history recovery compares against before it scores a night.
    /// Today counts the same nights ("Learning your usual, 1 of 3 nights").
    public static let recoveryLearningNights = WellnessAnalytics.readinessCompositeMinBaseline

    /// The sleep need Today and Sleep use when none was saved.
    public static let defaultSleepNeedHours = SleepNeed.defaultMinutes / 60

    /// What the time zone line on the profile step says: the city from the
    /// identifier and the current offset, for example "Perth, GMT+8".
    public static func timeZoneLabel(_ timeZone: TimeZone, at date: Date) -> String {
        let city = timeZone.identifier
            .split(separator: "/")
            .last
            .map { $0.replacingOccurrences(of: "_", with: " ") } ?? timeZone.identifier
        let seconds = timeZone.secondsFromGMT(for: date)
        let hours = abs(seconds) / 3600
        let minutes = (abs(seconds) % 3600) / 60
        let sign = seconds < 0 ? "-" : "+"
        let offset: String
        if seconds == 0 {
            offset = "GMT"
        } else if minutes == 0 {
            offset = "GMT\(sign)\(hours)"
        } else {
            offset = String(format: "GMT%@%d:%02d", sign, hours, minutes)
        }
        return city == offset ? offset : "\(city), \(offset)"
    }
}
