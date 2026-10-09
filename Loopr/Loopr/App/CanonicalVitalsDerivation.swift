import Foundation
import AnalyticsKit
import StorageKit
import DomainKit
import ProfileKit
import HeartKit
import BodyKit
import SleepKit

/// Overnight vitals for the canonical day: skin temperature, the band's
/// oxygen channels, beat-to-beat data and the cardio fitness estimate.
///
/// Kept out of `CanonicalDailyAnalytics.swift` so the shared derivation file
/// only gains call sites. Everything here is pure over values the derivation
/// already has in hand; nothing reads storage.
extension CanonicalDailyAnalytics {
    /// Tonight's own vitals. The deviations need earlier nights and start as
    /// "no reading" or "calibrating"; `heartVitalsWithHistory` fills them in.
    nonisolated static func overnightVitals(records: [StoredHistoricalRecord],
                                            sleepWindow: VitalsWindow?,
                                            cleanSleepBeats: RRQualityGateValue?) -> HeartVitalsSnapshot {
        guard let sleepWindow else {
            return HeartVitalsSnapshot(
                skinTemperature: HeartSkinTemperatureVital(nightlyCelsius: nil, keptSamples: 0, deviation: .noReading),
                oxygen: HeartOxygenVital(assessment: nil, nightlyRatio: nil, deviation: .noReading),
                beatToBeat: nil)
        }
        var skin: [SkinTemperatureSample] = []
        var optical: [OpticalOxygenSample] = []
        skin.reserveCapacity(records.count)
        optical.reserveCapacity(records.count)
        for record in records {
            let timestamp = Double(record.absoluteTimestamp)
            let bpm = record.heartRate.map(Double.init)
            if let celsius = record.skinTemperatureCelsius {
                skin.append(SkinTemperatureSample(timestamp: timestamp, celsius: celsius, heartRate: bpm))
            }
            if let red = record.spo2RedRaw, let infrared = record.spo2IRRaw {
                optical.append(OpticalOxygenSample(timestamp: timestamp, red: Int(red), infrared: Int(infrared), heartRate: bpm))
            }
        }
        let night = SkinTemperatureAnalytics.nightly(skin, sleepWindows: [sleepWindow]).value
        let skinVital = HeartSkinTemperatureVital(nightlyCelsius: night?.celsius, keptSamples: night?.keptSamples ?? 0,
            deviation: night == nil ? .noReading : .calibrating(nightsRemaining: SkinTemperatureAnalytics.calibrationNights - 1),
            settledFraction: night?.settledFraction, sleepCoverage: night?.sleepCoverage,
            missingReason: records.contains { $0.version == 24 }
                ? "No settled temperature for this night. A snug fit overnight helps; sync in the morning."
                : "Temperature is not available from this band.")
        let oxygenAssessment = optical.isEmpty ? nil : OvernightOxygenAnalytics.assess(optical, sleepWindows: [sleepWindow])
        // DEC-05.2: Gen4 carries no oxygen information. Preserve channel diagnostics,
        // but never derive a nightly ratio or a blood-oxygen value from these records.
        let oxygenVital = HeartOxygenVital(assessment: oxygenAssessment, nightlyRatio: nil, deviation: .noReading)
        let beats = cleanSleepBeats.flatMap {
            BeatToBeatAnalytics.summarize($0.normalIntervalsMilliseconds, beatTimesMilliseconds: $0.normalTimesMilliseconds).value
        }
        return HeartVitalsSnapshot(skinTemperature: skinVital, oxygen: oxygenVital, beatToBeat: beats)
    }

    /// The day's vitals with tonight compared against the earlier nights the
    /// display pass already walked (`priorDays`, newest first).
    nonisolated static func heartVitalsWithHistory(_ projection: CanonicalDailyProjection,
                                                   priorDays prior: [CanonicalDailyProjection]) -> HeartVitalsSnapshot? {
        guard let vitals = projection.heart.vitals else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: projection.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let identity = projection.heart.day
        guard let day = calendar.date(from: DateComponents(era: identity.era, year: identity.year, month: identity.month, day: identity.day)) else { return vitals }
        let lookup = Dictionary(prior.map { (dayLabel($0.heart.day), $0) }, uniquingKeysWith: { a, _ in a })
        let history: [Double?] = (1...30).reversed().map { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: day) else { return nil }
            let key = HeartAlertsDay.key(date, calendar: calendar)
            return lookup[key]?.heart.vitals?.skinTemperature.nightlyCelsius
        }
        let skin = vitals.skinTemperature.replacingDeviation(SkinTemperatureAnalytics.deviation(
            tonightCelsius: vitals.skinTemperature.nightlyCelsius, priorNightsOldestFirst: history))
        var current = overnightNight(projection)
        if skin.deviation.value?.likelyFitChange == true {
            current = .init(night: current.night, values: current.values.filter { $0.key != .skinTemperatureDeviation })
        }
        let nights = [current] + prior.map(overnightNight)
        let assessment = OvernightVitalsCheck.assessment(nights: nights, calendar: calendar)
        return vitals.replacing(skinTemperature: skin, assessment: assessment)
    }

    nonisolated static func overnightNight(_ projection: CanonicalDailyProjection) -> OvernightVitalsNight {
        var values: [OvernightVitalMetric: Double] = [:]
        if projection.sleep.mainSleep != nil {
            values[.restingHeartRate] = nocturnalRestingHeartRate(projection)
            // Captioned daytime fallbacks do not enter an overnight baseline.
            if let metric = projection.heart.metric(.rmssd), metric.confidence == nil { values[.heartRateVariability] = metric.numericValue }
            if let metric = projection.heart.metric(.respiration), metric.confidence == nil { values[.respiratoryRate] = metric.numericValue }
            let skin = projection.heart.vitals?.skinTemperature
            // Reject a contact jump against the same prior-night baseline in the display pass.
            if skin?.deviation.value?.likelyFitChange != true { values[.skinTemperatureDeviation] = skin?.nightlyCelsius }
        }
        return .init(night: dayLabel(projection.heart.day), values: values)
    }

    /// The overnight resting heart rate, or nil when the day's value came
    /// from a quiet daytime stretch. The derivation captions exactly that
    /// fallback, so a captioned value is not a night's.
    nonisolated static func nocturnalRestingHeartRate(_ projection: CanonicalDailyProjection) -> Double? {
        guard projection.sleep.mainSleep != nil,
              let metric = projection.heart.metric(.restingHeartRate), metric.confidence == nil else { return nil }
        return metric.numericValue
    }

    /// Profile context for Apple Health cardio fitness. No resting-HR estimate.
    nonisolated static func cardioFitness(_ projection: CanonicalDailyProjection,
                                          priorDays prior: [CanonicalDailyProjection],
                                          calendar: Calendar) -> BodyCardioFitness {
        let day = projection.body.day
        let age = projection.profile?.birthYear.flatMap { year -> Int? in
            let age = day.year - year
            return (1...120).contains(age) ? age : nil
        }
        let group: FriendReferenceGroup? = switch projection.profile?.biologicalSex {
        case .male: .male
        case .female: .female
        default: nil
        }
        return BodyCardioFitness(estimate: nil, gap: nil, nightsRemaining: 0, age: age, referenceGroup: group)
    }
}
