import Foundation
import AnalyticsKit
import HeartKit
import SleepKit
import BodyKit
import TodayKit
import DesignSystem

/// The one place that decides which band-derived day values reach the metric
/// history, and in which unit (see `MetricKey.historyUnit`).
///
/// The result has an entry for every key the given inputs can speak for:
/// a number when the day has one, `nil` when the derivation ran and has no
/// value (so a stale stored value is cleared). Keys the inputs cannot speak
/// for are left out, and whatever is stored for them is kept.
///
/// To add a metric (sleeping heart rate, max heart rate, ...), read it from
/// the projection here and add one line. Never
/// substitute a zero or a placeholder for a value the derivation did not
/// produce.
nonisolated enum BandMetricSeriesMapping {
    static func values(projection: CanonicalDailyProjection, today: TodaySummary? = nil) -> [MetricKey: Double?] {
        var values: [MetricKey: Double?] = [:]
        func number(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return value
        }

        // Nightly heart values. Before the first night the derivation shows
        // readings from quiet daytime stretches, captioned as such. Those are
        // display only, exactly as they are kept out of every baseline, so a
        // day without a main sleep contributes no nightly heart history.
        let hasNight = projection.sleep.mainSleep != nil
        func heart(_ id: HeartMetricID) -> Double? {
            guard hasNight, let metric = projection.heart.metric(id), metric.state != .absent else { return nil }
            return number(metric.numericValue)
        }
        values[.restingHeartRate] = heart(.restingHeartRate)
        values[.rmssd] = heart(.rmssd)
        values[.sdnn] = heart(.sdnn)
        values[.pNN50] = heart(.pNN50)
        values[.respiratoryRate] = heart(.respiration)
        values[.heartRateDip] = heart(.heartRateDip)
        values[.sleepingHeartRate] = heart(.sleepingHeartRate)
        values[.maxHeartRate] = number(projection.heart.metric(.maxHeartRate)?.numericValue)

        // Sleep, in minutes and percent.
        func sleep(_ id: String) -> Double? {
            guard hasNight, let metric = projection.sleep.metric(id), metric.state != .absent else { return nil }
            return number(metric.numericValue)
        }
        values[.sleepDuration] = sleep("duration")
        values[.sleepEfficiency] = sleep("efficiency")
        values[.deepSleep] = sleep("deep")
        values[.remSleep] = sleep("rem")

        // The waking day.
        func todayValue(_ id: TodayMetricID, in summary: TodaySummary) -> Double? {
            guard let metric = summary.metric(id), metric.state != .absent else { return nil }
            return number(metric.numericValue)
        }
        values[.strain] = todayValue(.strain, in: projection.today)
        values[.steps] = todayValue(.steps, in: projection.today)
        values[.stress] = number(projection.stress?.score)
        // Active energy is carried only as the Body card's whole-kilocalorie
        // text, written with "%.0f".
        values[.activeEnergy] = projection.body.metric(.energy).flatMap { metric -> Double? in
            guard metric.state != .absent, let text = metric.value else { return nil }
            return number(Double(text))
        }

        // Values only a walk over the trailing nights produces. The day's own
        // generation cannot speak for them, so they are only mapped when the
        // display generation is at hand.
        if let today {
            values[.recovery] = todayValue(.recovery, in: today)
            if let regularity = projection.sleep.metric("regularity"), regularity.state != .absent {
                values[.sleepConsistency] = number(regularity.numericValue)
            } else {
                values[.sleepConsistency] = .some(nil)
            }
            // Overnight vitals are folded over earlier nights, so they exist
            // only on the display generation. A night whose change is
            // so large that it is almost certainly fit, not skin, has no
            // number on screen, so it has none in history either.
            let skin = projection.heart.vitals?.skinTemperature.deviation.value
            // Typed so a missing night stores `.some(nil)` (clear) rather
            // than removing the key from the result.
            let skinChange: Double? = skin.flatMap { $0.likelyFitChange ? nil : number($0.deltaCelsius) }
            values[.skinTemperatureDeviation] = skinChange
            // DEC-02.11 withholds Loopr's resting-HR-only VO2 max estimate.
            // Include a nil key to clear values written by older builds.
            values[.vo2Max] = .some(nil)
            values[.oxygenSaturation] = .some(nil)
            // Blood oxygen stays out: the band's relative red/infrared ratio
            // is not a percentage, and only Apple Health supplies one.
        }
        return values
    }

    /// The range that goes with a mapped value, for keys that carry one.
    /// Only keys with a value in `values(projection:today:)` get a range.
    static func ranges(projection: CanonicalDailyProjection, today: TodaySummary? = nil) -> [MetricKey: BandMetricRange] {
        [:]
    }
}

/// A low and high stored beside a day's value in `metric_series`.
nonisolated struct BandMetricRange: Equatable, Sendable {
    let low: Double
    let high: Double
}
