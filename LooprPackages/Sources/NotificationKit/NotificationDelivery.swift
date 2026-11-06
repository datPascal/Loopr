import Foundation

/// What quiet hours do to one request.
public enum QuietHoursBehavior: String, Codable, Sendable, Equatable {
    /// Dropped. Right for "workout saved" and device chatter: stale by morning.
    case suppress
    /// Held and delivered when quiet hours end.
    case deferUntilEnd
    /// Delivered anyway. Only for alerts the person explicitly allowed to
    /// break quiet hours.
    case deliver
}

/// App-wide delivery preferences, persisted next to the family toggles.
public struct NotificationDeliverySettings: Codable, Equatable, Sendable {
    public var quietHoursEnabled: Bool
    public var quietHours: QuietHours

    public init(quietHoursEnabled: Bool = true, quietHours: QuietHours = .standard) {
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHours = quietHours
    }

    /// Quiet hours on, 22:00 to 07:00.
    public static let standard = NotificationDeliverySettings()
}

public struct NotificationActionDescriptor: Equatable, Sendable {
    public let identifier: String
    public let title: String
    /// True when the action brings the app to the foreground.
    public let opensApp: Bool
}

public struct NotificationCategoryDescriptor: Equatable, Sendable {
    public let identifier: String
    public let actions: [NotificationActionDescriptor]
}

/// Every category Loopr registers at launch. The platform adapter turns these
/// into `UNNotificationCategory` values; nothing here imports UserNotifications.
public enum NotificationCategoryCatalog {
    public static let heartAlert = "com.loopr.category.heart-alert"
    public static let overnightCheck = "com.loopr.category.overnight-check"
    public static let device = "com.loopr.category.device"
    public static let activity = "com.loopr.category.activity"
    public static let reminder = "com.loopr.category.reminder"
    public static let general = "com.loopr.category.general"
    /// A protocol rule's own reminder, which the person can answer from the lock screen (ICP R3-HAB-02).
    public static let protocolRule = "com.loopr.category.protocol-rule"

    /// Silences that heart alert kind until local midnight, without opening
    /// Loopr.
    public static let pauseForTodayAction = "com.loopr.action.pause-today"
    /// Keeps the rule for the day the reminder came, without opening Loopr.
    public static let ruleDoneAction = "com.loopr.action.rule-done"
    /// Skips the rule for the day the reminder came, without opening Loopr.
    public static let ruleSkipTodayAction = "com.loopr.action.rule-skip-today"

    public static let all: [NotificationCategoryDescriptor] = [
        NotificationCategoryDescriptor(identifier: heartAlert, actions: [
            NotificationActionDescriptor(identifier: pauseForTodayAction, title: "Pause for today", opensApp: false)
        ]),
        NotificationCategoryDescriptor(identifier: overnightCheck, actions: []),
        NotificationCategoryDescriptor(identifier: device, actions: []),
        NotificationCategoryDescriptor(identifier: activity, actions: []),
        NotificationCategoryDescriptor(identifier: reminder, actions: []),
        NotificationCategoryDescriptor(identifier: general, actions: []),
        NotificationCategoryDescriptor(identifier: protocolRule, actions: [
            NotificationActionDescriptor(identifier: ruleDoneAction, title: "Done", opensApp: false),
            NotificationActionDescriptor(identifier: ruleSkipTodayAction, title: "Skip today", opensApp: false)
        ])
    ]

    /// The category of one request. A protocol rule's reminder gets its own, with Done and Skip today; every other
    /// request takes its family's.
    public static func category(for request: NotificationRequest) -> String {
        ProtocolRuleReminder.isRuleReminder(request) ? protocolRule : category(for: request.identity.family)
    }

    public static func category(for family: NotificationFamily) -> String {
        switch family {
        case .highHeartRate, .lowHeartRate: heartAlert
        case .overnightCheck, .cardioFitness: overnightCheck
        case .battery, .chargeGuidance, .disconnect, .staleData: device
        case .detectedWorkouts, .workoutCompletion, .breathingCompletion: activity
        case .journaling, .cycleReminders, .windDown, .hydration, .userReminders: reminder
        case .recoveryReadiness, .validatedHealthChanges, .goals, .briefings: general
        }
    }
}
