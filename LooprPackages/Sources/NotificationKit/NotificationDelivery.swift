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

    /// Silences that heart alert kind until local midnight, without opening
    /// Loopr.
    public static let pauseForTodayAction = "com.loopr.action.pause-today"

    public static let all: [NotificationCategoryDescriptor] = [
        NotificationCategoryDescriptor(identifier: heartAlert, actions: [
            NotificationActionDescriptor(identifier: pauseForTodayAction, title: "Pause for today", opensApp: false)
        ]),
        NotificationCategoryDescriptor(identifier: overnightCheck, actions: []),
        NotificationCategoryDescriptor(identifier: device, actions: []),
        NotificationCategoryDescriptor(identifier: activity, actions: []),
        NotificationCategoryDescriptor(identifier: reminder, actions: []),
        NotificationCategoryDescriptor(identifier: general, actions: [])
    ]

    public static func category(for family: NotificationFamily) -> String {
        switch family {
        case .highHeartRate, .lowHeartRate: heartAlert
        case .overnightCheck, .cardioFitness: overnightCheck
        case .battery, .chargeGuidance, .disconnect, .staleData: device
        case .detectedWorkouts, .workoutCompletion, .breathingCompletion: activity
        case .journaling, .cycleReminders, .windDown, .hydration: reminder
        case .recoveryReadiness, .validatedHealthChanges, .goals, .briefings: general
        }
    }
}
