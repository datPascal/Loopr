import Foundation

/// Shared wording and day checks for widgets, Watch and read-only intents.
/// Consumers reevaluate this when rendering, even if the stored flags are old.
public nonisolated struct SurfaceTodayReading: Equatable, Sendable {
    public enum Metric: Sendable { case recovery, sleep, strain }
    public let recovery: Double?
    public let sleepMinutes: Double?
    public let sleepNeedMinutes: Double?
    public let strainScore: Double?
    public let style: SurfaceRecoveryStyle?
    public let sleep: String
    public let strain: String
    public let sleepAccessibility: String
    public let strainAccessibility: String
    public let sleepContext: String?
    public let headline: String?
    public let unavailableReason: String
    public let status: String
    public let isLearning: Bool
    public let isStale: Bool
    public let isCurrentDay: Bool

    public init(snapshot: SurfaceSnapshot?, now: Date, calendar: Calendar = .current) {
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let day = SurfaceDayLabel.format(now, calendar: calendar)
        isCurrentDay = snapshot?.sourceDay == day
        let age = snapshot?.syncDate.map { max(0, now.timeIntervalSince($0)) }
        isStale = !isCurrentDay || age == nil || age! > 6 * 60 * 60 || !(snapshot?.staleReasons.isEmpty ?? false)
        let authorized = snapshot?.staleReasons.contains(.permissionRevoked) != true
        let metrics = isCurrentDay && authorized ? snapshot?.metrics : nil
        recovery = finite(metrics?.recovery).flatMap { (0...100).contains($0) ? $0 : nil }
        sleepMinutes = finite(metrics?.sleepMinutes).flatMap { $0 >= 0 ? $0 : nil }
        sleepNeedMinutes = isCurrentDay && authorized ? finite(snapshot?.insight?.sleepNeedMinutes).flatMap { $0 > 0 ? $0 : nil } : nil
        strainScore = finite(metrics?.strain).flatMap { (0...21).contains($0) ? $0 : nil }
        style = recovery == nil ? nil : snapshot?.insight?.recoveryStyle
        isLearning = recovery == nil && isCurrentDay && authorized && (snapshot?.insight?.nightsNeeded ?? 0) > 0
        sleep = finite(metrics?.sleepMinutes).flatMap { SurfaceMetricFormatting.duration(minutes: $0) } ?? "—"
        strain = finite(metrics?.strain).flatMap { (0...21).contains($0) ? $0 : nil }.map { String(format: "%.1f/21", $0) } ?? "—"
        sleepAccessibility = finite(metrics?.sleepMinutes).flatMap { SurfaceMetricFormatting.spokenDuration(minutes: $0) } ?? "unavailable"
        strainAccessibility = strain == "—" ? "unavailable" : strain.replacingOccurrences(of: "/", with: " out of ")
        headline = recovery == nil ? nil : snapshot?.insight?.headline
        if let minutes = finite(metrics?.sleepMinutes), let need = finite(snapshot?.insight?.sleepNeedMinutes) {
            let difference = Int((minutes - need).rounded())
            sleepContext = difference == 0 ? "Met your sleep need"
                : "\(difference > 0 ? "+" : "-")\(SurfaceMetricFormatting.duration(minutes: Double(abs(difference))) ?? "") vs need"
        } else {
            sleepContext = metrics?.sleepMinutes == nil ? nil : "Last night's sleep"
        }
        if !authorized {
            unavailableReason = "Turn on sharing in Loopr Settings."
        } else if !isCurrentDay {
            unavailableReason = "Sync your band for today's recovery."
        } else if let have = snapshot?.insight?.nightsRecorded, let need = snapshot?.insight?.nightsNeeded {
            unavailableReason = "\(have) of \(need) nights. Wear your band overnight."
        } else {
            unavailableReason = snapshot?.insight?.recoveryUnavailableReason ?? "Wear your band overnight, then sync."
        }
        if let synced = snapshot?.syncDate {
            if let age, age < 60, isCurrentDay {
                status = "Synced just now"
            } else if let age, age < 3_600, isCurrentDay {
                status = "Synced \(Int(age / 60)) min ago"
            } else {
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = isCurrentDay ? "HH:mm" : "EEE HH:mm"
                status = "Last synced \(formatter.string(from: synced))"
            }
        } else {
            status = "Open Loopr to sync"
        }
    }

    public var recoveryVerdict: String {
        if let recovery { return style?.verdict ?? (recovery.rounded() >= 67 ? "Ready" : recovery.rounded() >= 34 ? "Steady" : "Recover") }
        return isLearning ? "Learning" : "Waiting"
    }

    public var recoveryLine: String {
        guard let recovery else { return "No recovery yet" }
        return "Recovery \(Int(recovery.rounded()))" + (style.map { " · \($0.verdict)" } ?? "")
    }

    public var recoveryText: String { recovery.map { String(Int($0.rounded())) } ?? "—" }
    public var strainRingText: String { strainScore.map { String(format: "%.1f", $0) } ?? "—" }
    public var sleepRingText: String {
        guard let minutes = sleepMinutes, minutes < Double(Int.max) else { return "—" }
        let whole = Int(minutes.rounded())
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }

    public static func dialog(_ metric: Metric, snapshot: SurfaceSnapshot?, now: Date, calendar: Calendar = .current) -> String {
        let reading = Self(snapshot: snapshot, now: now, calendar: calendar)
        let freshness = reading.isStale ? " \(reading.status)." : ""
        switch metric {
        case .recovery:
            guard reading.recovery != nil else { return "No recovery yet. \(reading.unavailableReason) \(reading.status)." }
            return [reading.recoveryLine + ".", reading.headline].compactMap { $0 }.joined(separator: " ") + freshness
        case .sleep:
            guard reading.sleep != "—" else {
                let reason = snapshot?.staleReasons.contains(.permissionRevoked) == true
                    ? reading.unavailableReason : snapshot?.insight?.sleepUnavailableReason ?? "Wear your band overnight, then sync."
                return "No sleep yet. \(reason) \(reading.status)."
            }
            return "Sleep \(reading.sleepAccessibility). \(reading.sleepContext ?? "Last night's sleep")." + freshness
        case .strain:
            guard reading.strain != "—" else {
                let reason = snapshot?.staleReasons.contains(.permissionRevoked) == true
                    ? reading.unavailableReason : snapshot?.insight?.strainUnavailableReason ?? "Wear your band for at least an hour, then sync."
                return "No strain yet. \(reason) \(reading.status)."
            }
            return "Strain \(reading.strainAccessibility)." + freshness
        }
    }
}

public nonisolated enum SurfaceMetricFormatting {
    public static func spokenDuration(minutes: Double) -> String? {
        guard minutes.isFinite, minutes >= 0, minutes < Double(Int.max) else { return nil }
        let whole = Int(minutes.rounded()), hours = whole / 60, rest = whole % 60
        let hourText = "\(hours) \(hours == 1 ? "hour" : "hours")"
        let minuteText = "\(rest) \(rest == 1 ? "minute" : "minutes")"
        if hours == 0 { return minuteText }
        return rest == 0 ? hourText : "\(hourText), \(minuteText)"
    }
    /// Matches LooprUnitFormatter duration units; legacy efficiency is never used.
    public static func duration(minutes: Double) -> String? {
        guard minutes.isFinite, minutes >= 0, minutes < Double(Int.max) else { return nil }
        let whole = Int(minutes.rounded())
        let hours = whole / 60, rest = whole % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }
}

public nonisolated enum SurfaceTimelineSchedule {
    /// Include the civil-day boundary explicitly; a delayed reload must never
    /// leave yesterday's recovery in an entry dated today.
    public static func dates(now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = (0...104).map { now.addingTimeInterval(Double($0) * 15 * 60) }
        let midnight = calendar.startOfDay(for: now)
        for offset in 1...2 {
            if let next = calendar.date(byAdding: .day, value: offset, to: midnight), next <= dates.last! {
                dates.append(next)
            }
        }
        return Array(Set(dates)).sorted()
    }
}

public nonisolated enum SurfaceDayLabel {
    public static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
