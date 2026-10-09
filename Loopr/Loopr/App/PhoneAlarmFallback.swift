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

    func cancel() async

    /// The outcome of the last schedule, for the status screen.
    func lastOutcome() async -> PhoneAlarmOutcome?
}

/// The real backup: AlarmKit first, a time-sensitive notification when
/// AlarmKit refuses.
///
/// Both layers are scheduled by the system, not by Loopr, so they survive the
/// app being killed, the phone being locked, and Bluetooth being off. That is
/// the whole point: on the night this was written the app process was dead
/// from 01:46 to 06:50 and nothing on the phone was holding the 07:00 wake.
///
/// One alarm identifier is reused for every arm. Loopr only ever promises one
/// next wake, so rescheduling has to replace rather than accumulate.
@MainActor
final class PhoneAlarmFallback: PhoneAlarmScheduling {
    /// Stable across launches so a relaunch can cancel the alarm the previous
    /// process scheduled.
    static let alarmID = UUID(uuidString: "6F8A2C41-0B7E-4E2B-9E7B-1C0A0D5A9F10")!
    static let notificationID = "loopr.alarm.phone-backup"
    static let outcomeKey = "loopr.alarm.phone-backup-outcome"

    private let defaults: UserDefaults
    private var outcome: PhoneAlarmOutcome?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func prepare() async {
        #if canImport(AlarmKit) && os(iOS)
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
        #endif
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    @discardableResult
    func schedule(at fireDate: Date) async -> PhoneAlarmOutcome {
        await cancel()
        guard fireDate > Date() else {
            return record(.unavailable("That wake time has already passed on this iPhone."))
        }

        #if canImport(AlarmKit) && os(iOS)
        if let alarmOutcome = await scheduleSystemAlarm(at: fireDate) {
            return record(alarmOutcome)
        }
        #endif
        return record(await scheduleNotification(at: fireDate))
    }

    func cancel() async {
        #if canImport(AlarmKit) && os(iOS)
        try? AlarmManager.shared.cancel(id: Self.alarmID)
        #endif
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        outcome = nil
        defaults.removeObject(forKey: Self.outcomeKey)
        PhoneAlarmLog.write("phone backup cancelled")
    }

    func lastOutcome() async -> PhoneAlarmOutcome? {
        if let outcome { return outcome }
        guard let raw = defaults.string(forKey: Self.outcomeKey) else { return nil }
        return switch raw {
        case "systemAlarm": .systemAlarm
        case "notification": .notification
        default: nil
        }
    }

    // MARK: - Layers

    #if canImport(AlarmKit) && os(iOS)
    /// Returns nil when AlarmKit cannot be used at all, so the caller falls
    /// through to the notification. It never returns `.unavailable`: a refusal
    /// here is not the end of the backup chain.
    private func scheduleSystemAlarm(at fireDate: Date) async -> PhoneAlarmOutcome? {
        var state = AlarmManager.shared.authorizationState
        if state == .notDetermined {
            state = (try? await AlarmManager.shared.requestAuthorization()) ?? .denied
        }
        guard state == .authorized else {
            PhoneAlarmLog.write("AlarmKit not authorized; falling back to a notification")
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
        let configuration = AlarmManager.AlarmConfiguration<LooprAlarmMetadata>(
            schedule: .fixed(fireDate),
            attributes: attributes
        )
        do {
            _ = try await AlarmManager.shared.schedule(id: Self.alarmID, configuration: configuration)
            PhoneAlarmLog.write("AlarmKit alarm scheduled for \(fireDate.timeIntervalSince1970)")
            return .systemAlarm
        } catch {
            PhoneAlarmLog.write("AlarmKit refused the alarm: \(error)")
            return nil
        }
    }
    #endif

    private func scheduleNotification(at fireDate: Date) async -> PhoneAlarmOutcome {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
        let content = UNMutableNotificationContent()
        content.title = "Time to wake up"
        content.body = "Your Loopr alarm is due. Your band may not have buzzed."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            PhoneAlarmLog.write("notification backup scheduled for \(fireDate.timeIntervalSince1970)")
            return .notification
        } catch {
            PhoneAlarmLog.write("notification backup failed: \(error)")
            return .unavailable(
                "Loopr could not set a backup alarm on this iPhone. Turn on alarms and notifications for Loopr in Settings."
            )
        }
    }

    @discardableResult
    private func record(_ outcome: PhoneAlarmOutcome) -> PhoneAlarmOutcome {
        self.outcome = outcome
        switch outcome {
        case .systemAlarm: defaults.set("systemAlarm", forKey: Self.outcomeKey)
        case .notification: defaults.set("notification", forKey: Self.outcomeKey)
        case .unavailable: defaults.removeObject(forKey: Self.outcomeKey)
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
