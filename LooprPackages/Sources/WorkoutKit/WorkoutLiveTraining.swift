import AnalyticsKit
import Foundation

/// ActivityAnalytics owns zone edges and classification. This value only adds
/// the names and colors the live workout uses for that zone number.
public struct WorkoutZoneDisplay: Equatable, Sendable {
    public let number: Int
    public let name: String
    public let colorName: String
    public let lowerBPM: Double
    public let upperBPM: Double
    public let progress: Double

    public init?(bpm: Int, zones: HeartRateZoneSet) {
        let number = zones.zoneNumber(for: Double(bpm))
        guard let zone = zones.zones.first(where: { $0.number == number }) else { return nil }
        self.number = number
        name = Self.name(for: number)
        colorName = Self.colorName(for: number)
        lowerBPM = zone.lowerBPM
        upperBPM = zone.upperBPM
        progress = min(1, max(0, (Double(bpm) - zone.lowerBPM) / (zone.upperBPM - zone.lowerBPM)))
    }

    public static func name(for number: Int) -> String {
        switch number {
        case 1: "Recovery"
        case 2: "Easy"
        case 3: "Aerobic"
        case 4: "Hard"
        case 5: "Peak"
        default: "Below zone 1"
        }
    }

    public static func colorName(for number: Int) -> String {
        switch number {
        case 1: "brand"
        case 2: "recovery"
        case 3: "movement"
        case 4: "warning"
        case 5: "critical"
        default: "inkMuted"
        }
    }
}

public struct WorkoutLiveMetrics: Equatable, Sendable {
    public static let heartRateFreshness: TimeInterval = 10
    public let heartRate: Int?
    public let zone: WorkoutZoneDisplay?
    public let secondsInZones: [Int: TimeInterval]
    public let elapsed: TimeInterval?
    public let strain: Double?
    public let caloriesKcal: Double?

    public init(workout: WorkoutRecord?, zones: HeartRateZoneSet?, now: Date) {
        guard let workout else {
            heartRate = nil; zone = nil; secondsInZones = [:]
            elapsed = nil; strain = nil; caloriesKcal = nil
            return
        }
        elapsed = workout.activeElapsed(at: now)
        let fresh = workout.samples.last.flatMap { sample -> Int? in
            guard let bpm = sample.heartRate, bpm > 0,
                  now.timeIntervalSince(sample.timestamp) >= 0,
                  now.timeIntervalSince(sample.timestamp) <= Self.heartRateFreshness else { return nil }
            return bpm
        }
        heartRate = fresh
        zone = fresh.flatMap { bpm in zones.flatMap { WorkoutZoneDisplay(bpm: bpm, zones: $0) } }
        strain = workout.samples.reversed().compactMap(\.strain).first
        caloriesKcal = workout.samples.reversed().compactMap(\.energyKcal).first
        var seconds: [Int: TimeInterval] = [:]
        if let zones {
            for (index, sample) in workout.samples.enumerated() {
                guard let bpm = sample.heartRate, bpm > 0 else { continue }
                let next = index + 1 < workout.samples.count ? workout.samples[index + 1].timestamp : now
                let duration = min(5, max(0, next.timeIntervalSince(sample.timestamp)))
                let number = zones.zoneNumber(for: Double(bpm))
                seconds[number, default: 0] += duration
            }
        }
        secondsInZones = seconds
    }
}

public struct WorkoutLiveRoutePoint: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
    }
}

public struct WorkoutLiveRoute: Equatable, Sendable {
    public let distanceMeters: Double?
    public let currentPaceSecondsPerKilometer: Double?
    public let averagePaceSecondsPerKilometer: Double?
    public let points: [WorkoutLiveRoutePoint]
    public let segments: [[WorkoutLiveRoutePoint]]

    public init(distanceMeters: Double?, currentPaceSecondsPerKilometer: Double?, averagePaceSecondsPerKilometer: Double?, points: [WorkoutLiveRoutePoint], segments: [[WorkoutLiveRoutePoint]]? = nil) {
        self.distanceMeters = distanceMeters
        self.currentPaceSecondsPerKilometer = currentPaceSecondsPerKilometer
        self.averagePaceSecondsPerKilometer = averagePaceSecondsPerKilometer
        self.points = points
        self.segments = segments ?? [points]
    }
}
