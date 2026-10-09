import Foundation
import AnalyticsKit
import NotificationKit

/// Every string a heart alert notification carries. Neutral on purpose: the
/// person picked the threshold, and Loopr says what it measured, not what it
/// might mean.
nonisolated enum HeartAlertsCopy {
    static func title(for kind: HeartRateAlertKind) -> String {
        kind == .high ? "High heart rate" : "Low heart rate"
    }

    static func sentence(for episode: HeartRateAlertEpisode) -> String {
        let direction = episode.kind == .high ? "above" : "below"
        let state = episode.duringSleep && episode.kind == .low ? "while you seemed to be asleep" : "while you seemed to be at rest"
        return "Your heart rate stayed \(direction) \(episode.thresholdBPM) bpm for 10 minutes \(state)."
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func request(
        for episode: HeartRateAlertEpisode,
        family: NotificationFamily,
        now: Date,
        calendar: Calendar,
        allowDuringQuietHours: Bool
    ) -> NotificationRequest {
        let started = Date(timeIntervalSince1970: TimeInterval(episode.start))
        // Band history arrives about every 15 minutes, so the notification is
        // always a little late. Saying when it began keeps it honest.
        let detail = "\(sentence(for: episode)) It began at \(time(started, calendar: calendar))."
        return NotificationRequest(
            identity: NotificationIdentity(family: family, objectID: episode.id,
                                           day: HeartAlertsDay.key(started, calendar: calendar)),
            fireDate: now,
            title: title(for: episode.kind),
            detail: detail,
            sensitivity: .userRequestedAlert,
            deepLink: .heartAlert(episode.id),
            quietHoursBehavior: allowDuringQuietHours ? .deliver : .deferUntilEnd,
            expiresAt: started.addingTimeInterval(12 * 3600)
        )
    }

    static func metricName(_ metric: OvernightVitalMetric) -> String {
        switch metric {
        case .restingHeartRate: "resting heart rate"
        case .heartRateVariability: "heart rate variability"
        case .respiratoryRate: "breathing rate"
        case .skinTemperatureDeviation: "skin temperature"
        case .oxygenSaturation: "blood oxygen"
        }
    }

    static func countWord(_ count: Int) -> String {
        switch count {
        case 2: "Two"
        case 3: "Three"
        case 4: "Four"
        case 5: "Five"
        default: "\(count)"
        }
    }

    static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    static func overnightSentence(_ outliers: [(OvernightVitalMetric, OvernightVitalDirection)]) -> String {
        let parts = outliers.map { "\(metricName($0.0)) was \($0.1 == .higher ? "higher" : "lower")" }
        return "\(countWord(outliers.count)) of last night's readings were outside your usual range. "
            + "Your \(joined(parts))."
    }

    static let overnightFactors = "Alcohol, late meals, a hot room, hard training or travel can move these readings. Illness can too."

    static func overnightRequest(
        id: String,
        night: String,
        outliers: [OvernightVitalOutlier],
        fireDate: Date,
        calendar: Calendar
    ) -> NotificationRequest {
        let detail = "Your overnight readings have been outside your usual range for two nights. "
            + overnightSentence(outliers.map { ($0.metric, $0.direction) }) + " " + overnightFactors
        return NotificationRequest(
            identity: NotificationIdentity(family: .overnightCheck, objectID: id, day: night),
            fireDate: fireDate,
            title: "Overnight check",
            detail: detail,
            sensitivity: .userRequestedAlert,
            deepLink: .heartAlert(id),
            quietHoursBehavior: .deferUntilEnd,
            expiresAt: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: fireDate))
        )
    }

    static func cardioFitnessRequest(id: String, now: Date, calendar: Calendar) -> NotificationRequest {
        NotificationRequest(
            identity: NotificationIdentity(family: .cardioFitness, objectID: id,
                                           day: HeartAlertsDay.key(now, calendar: calendar)),
            fireDate: now,
            title: "Cardio fitness",
            detail: "Your latest cardio fitness estimate is in the low range. Regular aerobic exercise can raise it.",
            sensitivity: .userRequestedAlert,
            deepLink: .heartAlert(id),
            quietHoursBehavior: .deferUntilEnd
        )
    }
}
