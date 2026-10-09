import Foundation

// High and low heart rate alerts, the band analog of the Apple Watch
// "High Heart Rate" and "Low Heart Rate" notifications.
//
// Apple samples heart rate in the background only while the wearer is still,
// and notifies when it stays above or below a threshold the person picked for
// about ten minutes of inactivity, confirmed by a second beat-to-beat check.
// This detector does the same with what the WHOOP band stores per second:
// heart rate, the gravity vector, and RR intervals. It is a wellness alert
// with a user-chosen threshold. It does not judge rhythm and makes no claim
// about any condition.
//
// PURITY: no I/O and no wall clock. The caller passes `now`, the calendar,
// the samples and the persisted state, and stores `nextState` verbatim. The
// band delivers history in offloads about every fifteen minutes, so the
// detector evaluates every ten-minute window that ends inside the newly
// delivered seconds, not just the newest one.

public enum HeartRateAlertKind: String, Codable, Sendable, CaseIterable, Hashable {
    case high
    case low
}

/// One stored second from the band.
public struct HeartRateMonitorSecond: Equatable, Sendable {
    /// Absolute unix seconds.
    public let timestamp: Int64
    /// Beats per minute. Nil or 0 means the band reported no reading.
    public let heartRate: Double?
    /// Gravity vector in g. Nil when the band did not report it.
    public let gravityX: Double?
    public let gravityY: Double?
    public let gravityZ: Double?
    /// RR intervals the band reported for this second, in milliseconds.
    public let rrIntervalsMilliseconds: [Int]

    public init(
        timestamp: Int64,
        heartRate: Double?,
        gravityX: Double?,
        gravityY: Double?,
        gravityZ: Double?,
        rrIntervalsMilliseconds: [Int] = []
    ) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.rrIntervalsMilliseconds = rrIntervalsMilliseconds
    }
}

/// What the person chose. Every alert defaults to off.
public struct HeartRateAlertSettings: Codable, Equatable, Sendable {
    public static let highThresholdChoices = [100, 110, 120, 130, 140, 150]
    public static let lowThresholdChoices = [40, 45, 50]
    public static let defaultHighThreshold = 120
    public static let defaultLowThreshold = 40

    public var highEnabled: Bool
    public var highThresholdBPM: Int
    public var lowEnabled: Bool
    public var lowThresholdBPM: Int
    /// Low heart rate while asleep is common and usually expected, so it is
    /// ignored unless the person asks for it.
    public var lowIncludesSleep: Bool

    public init(
        highEnabled: Bool = false,
        highThresholdBPM: Int = HeartRateAlertSettings.defaultHighThreshold,
        lowEnabled: Bool = false,
        lowThresholdBPM: Int = HeartRateAlertSettings.defaultLowThreshold,
        lowIncludesSleep: Bool = false
    ) {
        self.highEnabled = highEnabled
        self.highThresholdBPM = Self.clamp(highThresholdBPM, to: Self.highThresholdChoices)
        self.lowEnabled = lowEnabled
        self.lowThresholdBPM = Self.clamp(lowThresholdBPM, to: Self.lowThresholdChoices)
        self.lowIncludesSleep = lowIncludesSleep
    }

    public static let off = HeartRateAlertSettings()

    public func isEnabled(_ kind: HeartRateAlertKind) -> Bool {
        kind == .high ? highEnabled : lowEnabled
    }

    public func threshold(for kind: HeartRateAlertKind) -> Int {
        kind == .high ? highThresholdBPM : lowThresholdBPM
    }

    /// Snaps a stored or typed value onto the nearest offered choice, so a
    /// corrupted preference can never produce a 0 or 300 bpm threshold.
    public static func clamp(_ value: Int, to choices: [Int]) -> Int {
        choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}

/// The constants the detector runs on. Tests and the real-data audit pass
/// variants; production uses `.standard`.
public struct HeartRateAlertParameters: Equatable, Sendable {
    /// Apple's rule: the heart rate stays past the threshold for ten minutes.
    public var windowSeconds: Int64
    /// Share of the window's seconds that must carry a heart rate reading.
    public var minimumHeartRateCoverage: Double
    /// Share of the window's covered minutes whose own median must sit past
    /// the threshold: "stays above" rather than "averaged above". At 0.8 one
    /// dip minute is tolerated and at least eight of the ten minutes must be
    /// past the threshold, on top of the whole window's median.
    public var minimumSustainedMinuteFraction: Double
    /// A minute counts as still when its mean per-second change of the
    /// gravity vector is at or below this, in g.
    ///
    /// Calibrated on a device snapshot (2026-09-21 to 09-23, 192,940
    /// seconds): 99.4% of minutes between 01:00 and 05:00 local sit at or
    /// below 0.06 g (median 0.0006, p95 0.027), and none of the 275 minutes in
    /// which at least half the seconds moved by more than 0.1 g, the walking
    /// minutes, did (their lowest was 0.105 g). Quiet sitting in the evening
    /// ran 0.003 to 0.03 g.
    public var stillMinuteMotionLimitG: Double
    /// A minute above this looks like walking and breaks the rest window
    /// outright. The lowest walking minute in the snapshot was 0.105 g.
    public var movingMinuteMotionLimitG: Double
    /// Minutes between the still and moving limits a window may contain:
    /// turning over in bed or reaching for a glass is still rest.
    public var allowedFidgetMinutes: Int
    /// Minutes of the window that must carry motion data at all.
    public var minimumMotionMinutes: Int
    /// The RR-derived rate must agree with the band's rate within this, or
    /// the window is rejected. This catches the optical sensor locking onto
    /// a repeating movement, and a halved rate from missed beats.
    public var beatToBeatAgreementBPM: Double
    /// Fewest clean RR intervals a confirmation may rest on.
    public var minimumConfirmationBeats: Int
    /// A window whose RR intervals are mostly rejected as artifacts is
    /// treated as a disagreement, not as missing data.
    public var minimumCleanBeatFraction: Double
    /// Apple confirms with a second beat-to-beat reading before it notifies.
    /// With this on, a window without enough RR data never alerts.
    public var requiresBeatToBeatConfirmation: Bool
    /// After an alert the kind stays quiet until the heart rate has been on
    /// the ordinary side of the threshold for this long.
    public var rearmSeconds: Int64
    /// At most this many alerts per kind per local day.
    public var dailyAlertLimit: Int
    /// Windows that ended longer ago than this never alert, so a backlog
    /// offload after a day away does not raise yesterday's episode.
    public var freshnessSeconds: Int64
    /// Heart rate stays up after exercise. Windows that start within this
    /// long after a workout ends are skipped. Unrecorded exercise counts too:
    /// a minute that looks like walking with the heart rate past the
    /// threshold starts the same cooldown.
    public var postWorkoutCooldownSeconds: Int64
    /// A still stretch at least this long ending at the window counts as
    /// sleep for the low-heart-rate include-sleep option, alongside any
    /// derived sleep window. Tonight's sleep is rarely derived yet when its
    /// seconds arrive.
    public var probableSleepStillSeconds: Int64
    /// Minutes of chart context kept around an episode.
    public var chartContextSeconds: Int64

    public init(
        windowSeconds: Int64 = 600,
        minimumHeartRateCoverage: Double = 0.8,
        minimumSustainedMinuteFraction: Double = 0.8,
        stillMinuteMotionLimitG: Double = 0.06,
        movingMinuteMotionLimitG: Double = 0.10,
        allowedFidgetMinutes: Int = 1,
        minimumMotionMinutes: Int = 8,
        beatToBeatAgreementBPM: Double = 8,
        minimumConfirmationBeats: Int = 60,
        minimumCleanBeatFraction: Double = 0.5,
        requiresBeatToBeatConfirmation: Bool = true,
        rearmSeconds: Int64 = 30 * 60,
        dailyAlertLimit: Int = 2,
        freshnessSeconds: Int64 = 2 * 60 * 60,
        postWorkoutCooldownSeconds: Int64 = 10 * 60,
        probableSleepStillSeconds: Int64 = 60 * 60,
        chartContextSeconds: Int64 = 20 * 60
    ) {
        self.windowSeconds = windowSeconds
        self.minimumHeartRateCoverage = minimumHeartRateCoverage
        self.minimumSustainedMinuteFraction = minimumSustainedMinuteFraction
        self.stillMinuteMotionLimitG = stillMinuteMotionLimitG
        self.movingMinuteMotionLimitG = movingMinuteMotionLimitG
        self.allowedFidgetMinutes = allowedFidgetMinutes
        self.minimumMotionMinutes = minimumMotionMinutes
        self.beatToBeatAgreementBPM = beatToBeatAgreementBPM
        self.minimumConfirmationBeats = minimumConfirmationBeats
        self.minimumCleanBeatFraction = minimumCleanBeatFraction
        self.requiresBeatToBeatConfirmation = requiresBeatToBeatConfirmation
        self.rearmSeconds = rearmSeconds
        self.dailyAlertLimit = dailyAlertLimit
        self.freshnessSeconds = freshnessSeconds
        self.postWorkoutCooldownSeconds = postWorkoutCooldownSeconds
        self.probableSleepStillSeconds = probableSleepStillSeconds
        self.chartContextSeconds = chartContextSeconds
    }

    public static let standard = HeartRateAlertParameters()

    /// How far before the first unevaluated window the caller must read, so
    /// a window, the probable-sleep lookback and the chart context all have
    /// their data.
    public var requiredLookbackSeconds: Int64 {
        max(windowSeconds, probableSleepStillSeconds, chartContextSeconds) + 60
    }
}

/// Everything outside the band samples that the rules depend on.
public struct HeartRateAlertContext: Sendable {
    /// Absolute unix seconds.
    public var now: Int64
    /// Local calendar, used for the per-day alert limit.
    public var calendar: Calendar
    /// Recorded, detected or live workouts, as absolute half-open ranges.
    /// An open workout should be passed with `upperBound = now`.
    public var workouts: [Range<Int64>]
    /// Derived sleep windows, when known.
    public var sleep: [Range<Int64>]

    public init(now: Int64, calendar: Calendar, workouts: [Range<Int64>] = [], sleep: [Range<Int64>] = []) {
        self.now = now
        self.calendar = calendar
        self.workouts = workouts
        self.sleep = sleep
    }
}

/// Persisted between evaluations.
public struct HeartRateAlertState: Codable, Equatable, Sendable {
    public struct KindState: Codable, Equatable, Sendable {
        /// False after an alert, until the heart rate returns to normal.
        public var armed: Bool
        /// Seconds of consecutive ordinary-side minutes since the last alert.
        public var normalSeconds: Int64
        /// Window ends of alerts already raised, for the daily limit.
        public var alertTimes: [Int64]
        /// The alert episode that is still running, if any.
        public var openEpisodeID: String?
        /// End of the last window that qualified for the open episode.
        public var lastQualifyingEnd: Int64?

        public init(armed: Bool = true, normalSeconds: Int64 = 0, alertTimes: [Int64] = [],
                    openEpisodeID: String? = nil, lastQualifyingEnd: Int64? = nil) {
            self.armed = armed
            self.normalSeconds = normalSeconds
            self.alertTimes = alertTimes
            self.openEpisodeID = openEpisodeID
            self.lastQualifyingEnd = lastQualifyingEnd
        }
    }

    /// End of the newest window already evaluated. Nil before the first run.
    public var watermark: Int64?
    public var high: KindState
    public var low: KindState

    public init(watermark: Int64? = nil, high: KindState = KindState(), low: KindState = KindState()) {
        self.watermark = watermark
        self.high = high
        self.low = low
    }

    public static let initial = HeartRateAlertState()

    public subscript(kind: HeartRateAlertKind) -> KindState {
        get { kind == .high ? high : low }
        set { if kind == .high { high = newValue } else { low = newValue } }
    }
}

/// How the beat-to-beat check came out for one window.
public enum BeatToBeatConfirmation: Codable, Equatable, Sendable {
    /// RR agreed with the band. The associated value is the RR-derived rate.
    case agrees(Double)
    /// RR produced a clear rate that differs from the band's.
    case disagrees(Double)
    /// RR intervals were present but mostly artifacts.
    case inconsistent
    /// Too few RR intervals to check.
    case unavailable

    public var confirms: Bool {
        if case .agrees = self { return true }
        return false
    }
}

/// One minute of heart rate kept for the episode chart.
public struct HeartRateMinutePoint: Codable, Equatable, Sendable, Hashable {
    /// Absolute unix seconds of the minute's start.
    public let minuteStart: Int64
    public let medianBPM: Double

    public init(minuteStart: Int64, medianBPM: Double) {
        self.minuteStart = minuteStart
        self.medianBPM = medianBPM
    }
}

/// A raised alert, and the history row the settings screen lists.
public struct HeartRateAlertEpisode: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: HeartRateAlertKind
    public let thresholdBPM: Int
    /// Start of the first qualifying window.
    public let start: Int64
    /// End of the first qualifying window, when the alert was raised.
    public let detectedAt: Int64
    /// End of the last qualifying window seen so far.
    public var end: Int64
    /// Median heart rate over the qualifying windows.
    public var medianBPM: Double
    /// Highest minute median for a high alert, lowest for a low one.
    public var extremeBPM: Double
    public var confirmationBPM: Double?
    public var duringSleep: Bool
    public var minutes: [HeartRateMinutePoint]

    public init(id: String, kind: HeartRateAlertKind, thresholdBPM: Int, start: Int64, detectedAt: Int64,
                end: Int64, medianBPM: Double, extremeBPM: Double, confirmationBPM: Double?,
                duringSleep: Bool, minutes: [HeartRateMinutePoint]) {
        self.id = id
        self.kind = kind
        self.thresholdBPM = thresholdBPM
        self.start = start
        self.detectedAt = detectedAt
        self.end = end
        self.medianBPM = medianBPM
        self.extremeBPM = extremeBPM
        self.confirmationBPM = confirmationBPM
        self.duringSleep = duringSleep
        self.minutes = minutes
    }

    public var durationSeconds: Int64 { end - start }
}

/// Why a window that crossed the threshold did not raise an alert. Kept for
/// tests and the real-data audit; the app does not show these.
public enum HeartRateAlertSkip: String, Codable, Sendable, Equatable {
    case disabled, stale, disarmed, dailyLimit, sleep, workout, unconfirmed, beatToBeatDisagrees
}

public struct HeartRateAlertCandidate: Equatable, Sendable {
    public let kind: HeartRateAlertKind
    public let windowEnd: Int64
    public let medianBPM: Double
    public let confirmation: BeatToBeatConfirmation
    public let skip: HeartRateAlertSkip?
}

public struct HeartRateAlertEvaluation: Equatable, Sendable {
    /// Alerts to deliver now. Each is a new episode.
    public let alerts: [HeartRateAlertEpisode]
    /// Episodes raised earlier (including in this run) whose end or chart
    /// grew. The caller replaces its stored copy.
    public let updatedEpisodes: [HeartRateAlertEpisode]
    /// Every window that crossed a threshold while at rest, raised or not.
    public let candidates: [HeartRateAlertCandidate]
    public let nextState: HeartRateAlertState
}

public enum HeartRateAlertDetector {
    public static let algorithmVersion = "loopr.heart-alerts.v1"

    /// Evaluates every whole-minute window ending after `state.watermark`.
    ///
    /// - Parameters:
    ///   - seconds: the new seconds plus at least
    ///     `parameters.requiredLookbackSeconds` of history before the
    ///     watermark. Order does not matter.
    ///   - openEpisodes: stored episodes named by the state's
    ///     `openEpisodeID`s, so a running episode can be extended.
    public static func evaluate(
        seconds: [HeartRateMonitorSecond],
        settings: HeartRateAlertSettings,
        state: HeartRateAlertState,
        context: HeartRateAlertContext,
        openEpisodes: [HeartRateAlertEpisode] = [],
        parameters: HeartRateAlertParameters = .standard
    ) -> HeartRateAlertEvaluation {
        var next = state
        guard let series = MinuteSeries(seconds: seconds) else {
            return HeartRateAlertEvaluation(alerts: [], updatedEpisodes: [], candidates: [], nextState: next)
        }
        let window = parameters.windowSeconds
        let windowMinutes = Int(window / 60)
        // The last minute counts only once it is complete in the data.
        let lastEnd = (series.lastTimestamp + 1) / 60 * 60
        var firstEnd = series.firstMinuteStart + window
        if let watermark = state.watermark { firstEnd = max(firstEnd, (watermark / 60 + 1) * 60) }
        guard firstEnd <= lastEnd else {
            return HeartRateAlertEvaluation(alerts: [], updatedEpisodes: [], candidates: [], nextState: next)
        }

        var episodes: [String: HeartRateAlertEpisode] = [:]
        for episode in openEpisodes { episodes[episode.id] = episode }
        var alerts: [HeartRateAlertEpisode] = []
        var touched: [String] = []
        var candidates: [HeartRateAlertCandidate] = []
        let exclusions = context.workouts.map { $0.lowerBound..<($0.upperBound + parameters.postWorkoutCooldownSeconds) }

        var end = firstEnd
        while end <= lastEnd {
            defer { end += 60 }
            let start = end - window
            let minutes = (0..<windowMinutes).map { series.minute(at: start + Int64($0) * 60) }
            let lastMinute = minutes.last ?? nil

            for kind in HeartRateAlertKind.allCases {
                let threshold = Double(settings.threshold(for: kind))
                // Re-arm bookkeeping runs on every minute with data.
                if let median = lastMinute?.medianHeartRate {
                    let ordinary = kind == .high ? median <= threshold : median >= threshold
                    if ordinary {
                        next[kind].normalSeconds += 60
                        if next[kind].normalSeconds >= parameters.rearmSeconds { next[kind].armed = true }
                    } else {
                        next[kind].normalSeconds = 0
                    }
                }
                // An open episode closes once its windows stop qualifying for
                // longer than a minute.
                if let lastQualifying = next[kind].lastQualifyingEnd, end - lastQualifying > 120 {
                    next[kind].openEpisodeID = nil
                    next[kind].lastQualifyingEnd = nil
                }
            }

            // Window-level gates shared by both kinds.
            let heartSeconds = minutes.reduce(0) { $0 + ($1?.heartRates.count ?? 0) }
            guard Double(heartSeconds) >= parameters.minimumHeartRateCoverage * Double(window) else { continue }
            guard isAtRest(minutes, parameters: parameters) else { continue }
            let windowRates = minutes.flatMap { $0?.heartRates ?? [] }
            guard let windowMedian = median(windowRates) else { continue }
            let minuteMedians = minutes.compactMap { $0?.medianHeartRate }

            for kind in HeartRateAlertKind.allCases {
                let thresholdValue = settings.threshold(for: kind)
                let threshold = Double(thresholdValue)
                let beyond: (Double) -> Bool = { kind == .high ? $0 > threshold : $0 < threshold }
                guard beyond(windowMedian) else { continue }
                let sustained = minuteMedians.filter(beyond).count
                guard !minuteMedians.isEmpty,
                      Double(sustained) >= parameters.minimumSustainedMinuteFraction * Double(minuteMedians.count)
                else { continue }

                let confirmation = confirm(
                    rr: minutes.flatMap { $0?.rrIntervals ?? [] },
                    bandMedian: windowMedian,
                    parameters: parameters
                )
                // Derived sleep when the caller has it. A long still stretch
                // counts too, because tonight's sleep is usually not derived
                // yet when its seconds arrive.
                let duringSleep = overlaps(start..<end, context.sleep, minimumShare: 0.5)
                    || series.stillStretch(endingAt: end, parameters: parameters)
                        >= parameters.probableSleepStillSeconds
                let skip: HeartRateAlertSkip?
                if overlaps(start..<end, exclusions, minimumShare: 0)
                    || series.exerted(before: start, within: parameters.postWorkoutCooldownSeconds,
                                      beyond: beyond, parameters: parameters) {
                    skip = .workout
                } else {
                    switch confirmation {
                    case .agrees: skip = nil
                    case .disagrees, .inconsistent: skip = .beatToBeatDisagrees
                    case .unavailable: skip = parameters.requiresBeatToBeatConfirmation ? .unconfirmed : nil
                    }
                }
                if skip == nil && kind == .low && duringSleep && !settings.lowIncludesSleep {
                    candidates.append(.init(kind: kind, windowEnd: end, medianBPM: windowMedian,
                                            confirmation: confirmation, skip: .sleep))
                    continue
                }
                if let skip {
                    candidates.append(.init(kind: kind, windowEnd: end, medianBPM: windowMedian,
                                            confirmation: confirmation, skip: skip))
                    continue
                }

                // A qualifying window. Extend a running episode first.
                if let openID = next[kind].openEpisodeID, var episode = episodes[openID] {
                    episode.end = end
                    let extreme = kind == .high ? minuteMedians.max() : minuteMedians.min()
                    if let extreme {
                        episode.extremeBPM = kind == .high ? max(episode.extremeBPM, extreme) : min(episode.extremeBPM, extreme)
                    }
                    episode.minutes = series.merged(episode.minutes, from: episode.start - parameters.chartContextSeconds, to: end)
                    let inside = episode.minutes.filter { $0.minuteStart >= episode.start && $0.minuteStart < end }
                    episode.medianBPM = median(inside.map(\.medianBPM)) ?? episode.medianBPM
                    episodes[openID] = episode
                    if !touched.contains(openID) { touched.append(openID) }
                    next[kind].lastQualifyingEnd = end
                    candidates.append(.init(kind: kind, windowEnd: end, medianBPM: windowMedian,
                                            confirmation: confirmation, skip: nil))
                    continue
                }
                if let openID = next[kind].openEpisodeID, episodes[openID] == nil {
                    // The caller did not hand the running episode back. Keep
                    // it running so the same stretch never alerts twice.
                    next[kind].lastQualifyingEnd = end
                    _ = openID
                    candidates.append(.init(kind: kind, windowEnd: end, medianBPM: windowMedian,
                                            confirmation: confirmation, skip: .disarmed))
                    continue
                }

                let gate: HeartRateAlertSkip?
                if !settings.isEnabled(kind) {
                    gate = .disabled
                } else if end < context.now - parameters.freshnessSeconds {
                    gate = .stale
                } else if !next[kind].armed {
                    gate = .disarmed
                } else if alertsOnSameDay(next[kind].alertTimes, as: end, calendar: context.calendar)
                            >= parameters.dailyAlertLimit {
                    gate = .dailyLimit
                } else {
                    gate = nil
                }
                candidates.append(.init(kind: kind, windowEnd: end, medianBPM: windowMedian,
                                        confirmation: confirmation, skip: gate))
                guard gate == nil else { continue }

                let extreme = (kind == .high ? minuteMedians.max() : minuteMedians.min()) ?? windowMedian
                let confirmationBPM: Double? = if case .agrees(let value) = confirmation { value } else { nil }
                let episode = HeartRateAlertEpisode(
                    id: "\(kind.rawValue)-\(end)",
                    kind: kind,
                    thresholdBPM: thresholdValue,
                    start: start,
                    detectedAt: end,
                    end: end,
                    medianBPM: windowMedian,
                    extremeBPM: extreme,
                    confirmationBPM: confirmationBPM,
                    duringSleep: duringSleep,
                    minutes: series.points(from: start - parameters.chartContextSeconds, to: end)
                )
                episodes[episode.id] = episode
                alerts.append(episode)
                next[kind].armed = false
                next[kind].normalSeconds = 0
                next[kind].openEpisodeID = episode.id
                next[kind].lastQualifyingEnd = end
                next[kind].alertTimes.append(end)
            }
        }

        next.watermark = lastEnd
        // The daily limit only needs today and yesterday.
        for kind in HeartRateAlertKind.allCases {
            next[kind].alertTimes = next[kind].alertTimes.filter { $0 >= context.now - 2 * 86_400 }
        }
        // Keep extending the chart of an episode that is still open, even on
        // minutes that no longer qualify, so the chart shows the way back down.
        for kind in HeartRateAlertKind.allCases {
            guard let openID = next[kind].openEpisodeID, var episode = episodes[openID] else { continue }
            let points = series.merged(episode.minutes, from: episode.start - parameters.chartContextSeconds, to: lastEnd)
            if points != episode.minutes {
                episode.minutes = points
                episodes[openID] = episode
                if !touched.contains(openID) { touched.append(openID) }
            }
        }
        let alertIDs = Set(alerts.map(\.id))
        let finalAlerts = alerts.map { episodes[$0.id] ?? $0 }
        let updated = touched.filter { !alertIDs.contains($0) }.compactMap { episodes[$0] }
        return HeartRateAlertEvaluation(alerts: finalAlerts, updatedEpisodes: updated,
                                        candidates: candidates, nextState: next)
    }

    // MARK: - Rules

    /// Sitting, lying or sleeping: enough minutes with motion data, none that
    /// look like walking, and at most the allowed number of fidgets.
    static func isAtRest(_ minutes: [MinuteSeries.Minute?], parameters: HeartRateAlertParameters) -> Bool {
        let motion = minutes.compactMap { $0?.meanMotion }
        guard motion.count >= parameters.minimumMotionMinutes else { return false }
        if motion.contains(where: { $0 > parameters.movingMinuteMotionLimitG }) { return false }
        let fidgets = motion.filter { $0 > parameters.stillMinuteMotionLimitG }.count
        return fidgets <= parameters.allowedFidgetMinutes
    }

    /// The beat-to-beat check.
    ///
    /// RR intervals outside 300 to 2000 ms are dropped, as is any interval
    /// that exactly repeats the one before it: the band writes placeholder
    /// runs of 500 and 333 ms when it loses the beat (1,993 and 1,305 of the
    /// snapshot's 103,606 intervals, four times any neighbouring value). The
    /// rest must sit within 20% of the median of their four neighbours.
    public static func confirm(
        rr: [Int],
        bandMedian: Double,
        parameters: HeartRateAlertParameters = .standard
    ) -> BeatToBeatConfirmation {
        var inRange: [Double] = []
        var previous: Int?
        for value in rr {
            defer { previous = value }
            guard (300...2000).contains(value), value != previous else { continue }
            inRange.append(Double(value))
        }
        guard inRange.count >= parameters.minimumConfirmationBeats else {
            // Plenty of raw intervals that are all out of range or repeated
            // is an artifact run, not missing data.
            return rr.count >= parameters.minimumConfirmationBeats * 2 ? .inconsistent : .unavailable
        }
        var clean: [Double] = []
        for index in inRange.indices {
            let lower = max(inRange.startIndex, index - 2)
            let upper = min(inRange.endIndex, index + 3)
            var neighbours = Array(inRange[lower..<index])
            neighbours.append(contentsOf: inRange[(index + 1)..<upper])
            guard let reference = median(neighbours) else { continue }
            if abs(inRange[index] - reference) <= 0.2 * reference { clean.append(inRange[index]) }
        }
        guard clean.count >= parameters.minimumConfirmationBeats,
              Double(clean.count) >= parameters.minimumCleanBeatFraction * Double(inRange.count),
              let medianInterval = median(clean), medianInterval > 0
        else { return .inconsistent }
        let rate = 60_000 / medianInterval
        return abs(rate - bandMedian) <= parameters.beatToBeatAgreementBPM ? .agrees(rate) : .disagrees(rate)
    }

    static func alertsOnSameDay(_ times: [Int64], as time: Int64, calendar: Calendar) -> Int {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(time)))
        return times.filter {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0))) == day
        }.count
    }

    static func overlaps(_ window: Range<Int64>, _ intervals: [Range<Int64>], minimumShare: Double) -> Bool {
        let length = Double(window.upperBound - window.lowerBound)
        for interval in intervals {
            let overlap = min(window.upperBound, interval.upperBound) - max(window.lowerBound, interval.lowerBound)
            guard overlap > 0 else { continue }
            if minimumShare <= 0 || Double(overlap) >= minimumShare * length { return true }
        }
        return false
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// Per-minute buckets built once per evaluation.
struct MinuteSeries {
    struct Minute {
        var heartRates: [Double] = []
        var motionSum = 0.0
        var motionCount = 0
        var rrIntervals: [Int] = []

        /// Needs half a minute of readings to speak for the minute.
        var medianHeartRate: Double? {
            heartRates.count >= 30 ? HeartRateAlertDetector.median(heartRates) : nil
        }

        var meanMotion: Double? {
            motionCount >= 30 ? motionSum / Double(motionCount) : nil
        }
    }

    let firstMinuteStart: Int64
    let lastTimestamp: Int64
    private var minutes: [Int64: Minute] = [:]

    init?(seconds: [HeartRateMonitorSecond]) {
        guard !seconds.isEmpty else { return nil }
        let sorted = seconds.sorted { $0.timestamp < $1.timestamp }
        firstMinuteStart = sorted[0].timestamp / 60 * 60
        lastTimestamp = sorted[sorted.count - 1].timestamp
        var previous: HeartRateMonitorSecond?
        for second in sorted {
            defer { previous = second }
            if let last = previous, last.timestamp == second.timestamp { continue }
            let key = second.timestamp / 60 * 60
            var minute = minutes[key] ?? Minute()
            if let rate = second.heartRate, rate >= 25, rate <= 240 { minute.heartRates.append(rate) }
            // Motion is the change of the gravity vector from the previous
            // second, the same signal noop's sedentary detector smooths.
            if let last = previous, last.timestamp == second.timestamp - 1,
               let x0 = last.gravityX, let y0 = last.gravityY, let z0 = last.gravityZ,
               let x1 = second.gravityX, let y1 = second.gravityY, let z1 = second.gravityZ {
                let dx = x1 - x0, dy = y1 - y0, dz = z1 - z0
                minute.motionSum += (dx * dx + dy * dy + dz * dz).squareRoot()
                minute.motionCount += 1
            }
            minute.rrIntervals.append(contentsOf: second.rrIntervalsMilliseconds)
            minutes[key] = minute
        }
    }

    func minute(at start: Int64) -> Minute? { minutes[start] }

    func points(from start: Int64, to end: Int64) -> [HeartRateMinutePoint] {
        var output: [HeartRateMinutePoint] = []
        var cursor = max(start / 60 * 60, firstMinuteStart)
        while cursor < end {
            if let median = minutes[cursor]?.medianHeartRate {
                output.append(HeartRateMinutePoint(minuteStart: cursor, medianBPM: median))
            }
            cursor += 60
        }
        return output
    }

    /// True when a minute in the `within` seconds before `start` both moved
    /// like walking and had its heart rate past the threshold: exercise that
    /// nobody recorded as a workout.
    func exerted(before start: Int64, within: Int64, beyond: (Double) -> Bool,
                 parameters: HeartRateAlertParameters) -> Bool {
        guard within > 0 else { return false }
        var cursor = start - 60
        while cursor >= start - within {
            if let minute = minutes[cursor], let motion = minute.meanMotion,
               motion > parameters.movingMinuteMotionLimitG,
               let rate = minute.medianHeartRate, beyond(rate) {
                return true
            }
            cursor -= 60
        }
        return false
    }

    /// Stored points from before this series began, then this series' own.
    func merged(_ stored: [HeartRateMinutePoint], from start: Int64, to end: Int64) -> [HeartRateMinutePoint] {
        let older = stored.filter { $0.minuteStart >= start && $0.minuteStart < firstMinuteStart }
        return older + points(from: start, to: end)
    }

    /// Seconds of consecutive still minutes ending at `end`. A minute with no
    /// motion data ends the stretch: absence is not stillness.
    func stillStretch(endingAt end: Int64, parameters: HeartRateAlertParameters) -> Int64 {
        var seconds: Int64 = 0
        var cursor = end - 60
        var fidgets = 0
        while cursor >= firstMinuteStart {
            guard let motion = minutes[cursor]?.meanMotion else { break }
            if motion > parameters.movingMinuteMotionLimitG { break }
            if motion > parameters.stillMinuteMotionLimitG {
                fidgets += 1
                // The window's fidget allowance, per ten minutes of stretch.
                let allowance = (Int(seconds / 600) + 1) * parameters.allowedFidgetMinutes
                if fidgets > allowance { break }
            }
            seconds += 60
            cursor -= 60
            if seconds >= parameters.probableSleepStillSeconds { break }
        }
        return seconds
    }
}
