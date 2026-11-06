import DeviceCenterKit
import Foundation
import UserNotifications

#if canImport(AlarmKit)
import AlarmKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// What Loopr managed to put on this iPhone as a backup for the band alarm.
enum PhoneAlarmOutcome: Equatable, Sendable {
    /// A real system alarm. It breaks through silent mode and Focus and shows
    /// a full-screen alert, the same as the Clock app.
    case systemAlarm
    /// A time-sensitive notification with a sound. Weaker: the ring switch can
    /// quiet it, and it is a banner rather than a full-screen alert.
    case notification
    /// Nothing is set. The string is the reason, in words a person can read.
    case unavailable(String)

    var assurance: StrapAlarmAssurance.PhoneBackup {
        switch self {
        case .systemAlarm: .systemAlarm
        case .notification: .notification
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

/// Schedules the iPhone-side wake so a dead app, a flat band, or a lost BLE
/// link cannot cost someone their morning.
protocol PhoneAlarmScheduling: Sendable {
    /// Requests whatever permission the backup needs. Safe to call repeatedly.
    func prepare() async

    @discardableResult
    func schedule(at fireDate: Date) async -> PhoneAlarmOutcome
    func schedule(at fireDate: Date, repeating configuration: StrapAlarmConfiguration) async -> PhoneAlarmOutcome
    func cancel() async
    func cancelChecked() async throws
    func lastOutcome() async -> PhoneAlarmOutcome?
}

extension PhoneAlarmScheduling {
    func cancelChecked() async throws { await cancel() }
    func schedule(at fireDate: Date, repeating configuration: StrapAlarmConfiguration) async -> PhoneAlarmOutcome {
        await schedule(at: fireDate)
    }
}

/// iOS owns the repeating schedule, so locking or terminating Loopr does not
/// remove tomorrow's phone alarm. Reconciliation preserves an unchanged alarm.
@MainActor
final class PhoneAlarmFallback: PhoneAlarmScheduling {
    nonisolated static let alarmID = UUID(uuidString: "6F8A2C41-0B7E-4E2B-9E7B-1C0A0D5A9F10")!
    nonisolated static let notificationID = "loopr.alarm.phone-backup"
    nonisolated static let notificationIDs = [notificationID] + AlarmWeekday.allCases.map { notificationID + "." + $0.rawValue }
    nonisolated static let outcomeKey = "loopr.alarm.phone-backup-outcome"

    private let defaults: UserDefaults
    private var outcome: PhoneAlarmOutcome?
    private let cancelSystemAlarm: (@MainActor @Sendable () throws -> Void)?

    init(defaults: UserDefaults = .standard, cancelSystemAlarm: (@MainActor @Sendable () throws -> Void)? = nil) {
        self.defaults = defaults
        self.cancelSystemAlarm = cancelSystemAlarm
        if let saved = defaults.string(forKey: Self.outcomeKey), saved.hasPrefix("unavailable:") {
            outcome = .unavailable(String(saved.dropFirst("unavailable:".count)))
        }
    }

    func prepare() async {
        #if canImport(AlarmKit) && os(iOS)
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
        if AlarmManager.shared.authorizationState == .authorized { return }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    @discardableResult
    func schedule(at fireDate: Date) async -> PhoneAlarmOutcome {
        await schedule(at: fireDate, configuration: nil)
    }

    func schedule(at fireDate: Date, repeating configuration: StrapAlarmConfiguration) async -> PhoneAlarmOutcome {
        await schedule(at: fireDate, configuration: configuration)
    }

    private func schedule(at fireDate: Date, configuration: StrapAlarmConfiguration?) async -> PhoneAlarmOutcome {
        guard fireDate > Date() else {
            return record(.unavailable("That wake time has already passed on this iPhone."))
        }
        #if canImport(AlarmKit) && os(iOS)
        if let alarmOutcome = await scheduleSystemAlarm(at: fireDate, repeating: configuration) {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
            return record(alarmOutcome)
        }
        #endif
        return record(await scheduleNotification(at: fireDate, repeating: configuration))
    }

    func cancel() async { try? await cancelChecked() }

    func cancelChecked() async throws {
        var cancellationError: (any Error)?
        do {
            if let cancelSystemAlarm {
                try cancelSystemAlarm()
            } else {
                #if canImport(AlarmKit) && os(iOS)
                if AlarmManager.shared.authorizationState == .authorized,
                   try AlarmManager.shared.alarms.contains(where: { $0.id == Self.alarmID }) {
                    try AlarmManager.shared.cancel(id: Self.alarmID)
                }
                #endif
            }
        } catch { cancellationError = error }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
        if let cancellationError {
            record(.unavailable("Loopr could not turn off the phone alarm. It may still ring. Try again."))
            throw cancellationError
        }
        outcome = nil
        defaults.removeObject(forKey: Self.outcomeKey)
        PhoneAlarmLog.write("phone backup cancelled")
    }

    func lastOutcome() async -> PhoneAlarmOutcome? {
        // A partial replacement is not a complete schedule, even if one old
        // alarm or weekday request still exists.
        if case .unavailable = outcome { return outcome }
        #if canImport(AlarmKit) && os(iOS)
        if AlarmManager.shared.authorizationState == .authorized,
           let alarms = try? AlarmManager.shared.alarms,
           alarms.contains(where: { $0.id == Self.alarmID }) {
            return .systemAlarm
        }
        #endif
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if Self.notificationIsAudible(authorization: settings.authorizationStatus,
                                     sound: settings.soundSetting, alert: settings.alertSetting),
           await center.pendingNotificationRequests().contains(where: { Self.notificationIDs.contains($0.identifier) }) {
            return .notification
        }
        return nil
    }

    // MARK: - Layers

    #if canImport(AlarmKit) && os(iOS)
    /// Returns nil when AlarmKit cannot be used at all, so the caller falls
    /// through to the notification. It never returns `.unavailable`: a refusal
    /// here is not the end of the backup chain.
    private func scheduleSystemAlarm(at fireDate: Date, repeating configuration: StrapAlarmConfiguration?) async -> PhoneAlarmOutcome? {
        // Only prepare(), called by a user action, may show permission UI.
        // Reconciliation also runs behind the lock screen.
        guard AlarmManager.shared.authorizationState == .authorized else {
            PhoneAlarmLog.write("AlarmKit not authorized; falling back to a notification")
            return nil
        }
        let schedule = Self.systemSchedule(at: fireDate, repeating: configuration)
        do {
            if let existing = try AlarmManager.shared.alarms.first(where: { $0.id == Self.alarmID }) {
                // Includes an alarm that is currently ringing. A minute tick
                // must never stop it or replace an unchanged recurring wake.
                if existing.schedule == schedule { return .systemAlarm }
                try AlarmManager.shared.cancel(id: Self.alarmID)
            }
        } catch {
            PhoneAlarmLog.write("Could not inspect or replace the system alarm: \(error)")
            return nil
        }
        let alert = AlarmPresentation.Alert(
            title: "Time to wake up",
            stopButton: AlarmButton(
                text: "Stop",
                textColor: .white,
                systemImageName: "stop.circle"
            )
        )
        let attributes = AlarmAttributes<LooprAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: LooprAlarmMetadata(),
            tintColor: .orange
        )
        let alarmConfiguration = AlarmManager.AlarmConfiguration<LooprAlarmMetadata>(
            schedule: schedule,
            attributes: attributes
        )
        do {
            _ = try await AlarmManager.shared.schedule(id: Self.alarmID, configuration: alarmConfiguration)
            PhoneAlarmLog.write("AlarmKit alarm scheduled for \(fireDate.timeIntervalSince1970)")
            return .systemAlarm
        } catch {
            PhoneAlarmLog.write("AlarmKit refused the alarm: \(error)")
            return nil
        }
    }
    #endif

    private func scheduleNotification(at fireDate: Date, repeating configuration: StrapAlarmConfiguration?) async -> PhoneAlarmOutcome {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard Self.notificationIsAudible(authorization: settings.authorizationStatus,
                                         sound: settings.soundSetting, alert: settings.alertSetting) else {
            center.removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
            return .unavailable("Allow notifications and sounds for Loopr in Settings to use the phone backup.")
        }
        let requests = Self.notificationRequests(at: fireDate, repeating: configuration)
        let desiredIDs = Set(requests.map(\.identifier))
        let existing = await center.pendingNotificationRequests()
        do {
            for request in requests {
                if let old = existing.first(where: { $0.identifier == request.identifier }),
                   let oldTrigger = old.trigger as? UNCalendarNotificationTrigger,
                   let newTrigger = request.trigger as? UNCalendarNotificationTrigger,
                   oldTrigger.dateComponents == newTrigger.dateComponents,
                   oldTrigger.repeats == newTrigger.repeats { continue }
                try await center.add(request)
            }
            center.removePendingNotificationRequests(withIdentifiers: Self.notificationIDs.filter { !desiredIDs.contains($0) })
            return .notification
        } catch {
            PhoneAlarmLog.write("notification backup failed: \(error)")
            return .unavailable("Loopr could not schedule every wake day on this iPhone. Try saving the alarm again.")
        }
    }

    static func notificationIsAudible(
        authorization: UNAuthorizationStatus, sound: UNNotificationSetting, alert: UNNotificationSetting
    ) -> Bool {
        authorization == .authorized && sound == .enabled && alert == .enabled
    }

    static func notificationRequests(at fireDate: Date, repeating configuration: StrapAlarmConfiguration?) -> [UNNotificationRequest] {
        let content = UNMutableNotificationContent()
        content.title = "Time to wake up"
        content.body = "Your Loopr alarm is due."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        if let configuration, configuration.isEnabled, let minute = configuration.guaranteedMinute {
            return AlarmWeekday.allCases.filter(configuration.weekdays.contains).map { weekday in
                UNNotificationRequest(
                    identifier: notificationID + "." + weekday.rawValue,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(
                        dateMatching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0,
                                                     weekday: weekday.calendarWeekday), repeats: true
                    )
                )
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        components.timeZone = calendar.timeZone
        return [UNNotificationRequest(identifier: notificationID, content: content,
                                      trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))]
    }

    #if canImport(AlarmKit) && os(iOS)
    static func systemSchedule(at fireDate: Date, repeating configuration: StrapAlarmConfiguration?) -> Alarm.Schedule {
        guard let configuration, configuration.isEnabled, let minute = configuration.guaranteedMinute,
              !configuration.weekdays.isEmpty else { return .fixed(fireDate) }
        let weekdays: [Locale.Weekday] = AlarmWeekday.allCases.filter(configuration.weekdays.contains).map {
            switch $0 {
            case .sunday: .sunday
            case .monday: .monday
            case .tuesday: .tuesday
            case .wednesday: .wednesday
            case .thursday: .thursday
            case .friday: .friday
            case .saturday: .saturday
            }
        }
        return .relative(.init(time: .init(hour: minute / 60, minute: minute % 60), repeats: .weekly(weekdays)))
    }
    #endif

    @discardableResult
    private func record(_ outcome: PhoneAlarmOutcome) -> PhoneAlarmOutcome {
        self.outcome = outcome
        switch outcome {
        case .systemAlarm: defaults.set("systemAlarm", forKey: Self.outcomeKey)
        case .notification: defaults.set("notification", forKey: Self.outcomeKey)
        case .unavailable(let reason): defaults.set("unavailable:" + reason, forKey: Self.outcomeKey)
        }
        return outcome
    }
}

#if canImport(AlarmKit) && os(iOS)
/// AlarmKit needs a metadata type even when there is nothing to carry.
struct LooprAlarmMetadata: AlarmMetadata {
    init() {}
}
#endif

/// A backup that does nothing, for fixture compositions and tests.
struct NoPhoneAlarmFallback: PhoneAlarmScheduling {
    let reason: String

    init(reason: String = "Loopr has no backup alarm on this iPhone.") {
        self.reason = reason
    }

    func prepare() async {}

    @discardableResult
    func schedule(at fireDate: Date) async -> PhoneAlarmOutcome { .unavailable(reason) }

    func cancel() async {}

    func lastOutcome() async -> PhoneAlarmOutcome? { nil }
}

/// Same stream and prefix the morning hardware script greps.
enum PhoneAlarmLog {
    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "[Loopr Alarm] \(Date().formatted(date: .omitted, time: .standard)) \(message())\n"
        fputs(line, stderr)
        #endif
    }
}
