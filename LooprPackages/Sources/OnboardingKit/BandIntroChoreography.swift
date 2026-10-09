import Foundation

/// Beat times for the band intro film, read from `band-intro.timings.json`.
///
/// The JSON is written by the render pipeline next to the film (see
/// `design/onboarding-band/CONTRACT.md`). Any key the file leaves out takes the
/// contract value, and a file whose beats contradict each other is replaced by
/// the contract as a whole, so a bad render can never drift the haptics.
public struct BandIntroTimings: Codable, Equatable, Sendable {
    public var fps: Double
    public var duration: TimeInterval
    public var handInEnd: TimeInterval
    public var bandIn: TimeInterval
    public var wrapStart: TimeInterval
    public var click: TimeInterval
    public var settleEnd: TimeInterval
    /// `#RRGGBB`. The flat color the film is composited onto.
    public var background: String
    /// Fraction of the frame height, from the top, that is free of hand and band in the final frame.
    public var textSafeTopFraction: Double

    public init(
        fps: Double,
        duration: TimeInterval,
        handInEnd: TimeInterval,
        bandIn: TimeInterval,
        wrapStart: TimeInterval,
        click: TimeInterval,
        settleEnd: TimeInterval,
        background: String,
        textSafeTopFraction: Double
    ) {
        self.fps = fps
        self.duration = duration
        self.handInEnd = handInEnd
        self.bandIn = bandIn
        self.wrapStart = wrapStart
        self.click = click
        self.settleEnd = settleEnd
        self.background = background
        self.textSafeTopFraction = textSafeTopFraction
    }

    /// The values fixed in CONTRACT.md.
    public static let contract = BandIntroTimings(
        fps: 60,
        duration: 4.6,
        handInEnd: 1.4,
        bandIn: 1.4,
        wrapStart: 1.9,
        click: 3.0,
        settleEnd: 4.6,
        background: "#0A0D11",
        textSafeTopFraction: 0.36
    )

    private enum CodingKeys: String, CodingKey {
        case fps, duration, handInEnd, bandIn, wrapStart, click, settleEnd, background, textSafeTopFraction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.contract
        fps = try container.decodeIfPresent(Double.self, forKey: .fps) ?? fallback.fps
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? fallback.duration
        handInEnd = try container.decodeIfPresent(Double.self, forKey: .handInEnd) ?? fallback.handInEnd
        bandIn = try container.decodeIfPresent(Double.self, forKey: .bandIn) ?? fallback.bandIn
        wrapStart = try container.decodeIfPresent(Double.self, forKey: .wrapStart) ?? fallback.wrapStart
        click = try container.decodeIfPresent(Double.self, forKey: .click) ?? fallback.click
        settleEnd = try container.decodeIfPresent(Double.self, forKey: .settleEnd) ?? fallback.settleEnd
        background = try container.decodeIfPresent(String.self, forKey: .background) ?? fallback.background
        textSafeTopFraction = try container.decodeIfPresent(Double.self, forKey: .textSafeTopFraction)
            ?? fallback.textSafeTopFraction
    }

    /// True when the beats are ordered and inside the film, and the color parses.
    public var isCoherent: Bool {
        let times = [duration, handInEnd, bandIn, wrapStart, click, settleEnd]
        guard times.allSatisfy({ $0.isFinite && $0 >= 0 }), fps.isFinite, fps > 0 else { return false }
        guard wrapStart < click, click <= duration, settleEnd <= duration + 1.0 / fps else { return false }
        guard textSafeTopFraction > 0.05, textSafeTopFraction <= 0.9 else { return false }
        return backgroundRGB != nil
    }

    /// The background color as 0...1 components, or nil when `background` is not `#RRGGBB`.
    public var backgroundRGB: (red: Double, green: Double, blue: Double)? {
        var hex = background.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    /// Decodes a timings file. Returns the contract when the data is missing, unreadable, or incoherent.
    public static func decode(_ data: Data?) -> BandIntroTimings {
        guard let data, let decoded = try? JSONDecoder().decode(BandIntroTimings.self, from: data),
              decoded.isCoherent else { return .contract }
        return decoded
    }

    public static func load(from url: URL?) -> BandIntroTimings {
        decode(url.flatMap { try? Data(contentsOf: $0) })
    }
}

/// One haptic event, timed from the start of the pattern it belongs to.
public struct BandIntroHapticEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case transient
        case continuous(duration: TimeInterval)
    }

    public let kind: Kind
    public let time: TimeInterval
    public let intensity: Double
    public let sharpness: Double
    /// Continuous events only: fade from full intensity to nothing over this
    /// time instead of sustaining. The fade belongs to the event, so unlike a
    /// control curve it cannot soften other events that play meanwhile.
    public let decayTime: TimeInterval?

    public init(kind: Kind, time: TimeInterval, intensity: Double, sharpness: Double, decayTime: TimeInterval? = nil) {
        self.kind = kind
        self.time = time
        self.intensity = intensity
        self.sharpness = sharpness
        self.decayTime = decayTime
    }
}

/// A dynamic-parameter curve. Core Haptics multiplies event intensity by the
/// intensity control and adds the sharpness control to event sharpness. The
/// last point's value stays in force after the curve ends.
public struct BandIntroHapticCurve: Equatable, Sendable {
    public enum Parameter: Equatable, Sendable {
        case intensityControl
        case sharpnessControl
    }

    public struct Point: Equatable, Sendable {
        public let time: TimeInterval
        public let value: Double

        public init(time: TimeInterval, value: Double) {
            self.time = time
            self.value = value
        }
    }

    public let parameter: Parameter
    /// Curve start, relative to the pattern.
    public let time: TimeInterval
    /// Point times are relative to `time`.
    public let points: [Point]

    public init(parameter: Parameter, time: TimeInterval, points: [Point]) {
        self.parameter = parameter
        self.time = time
        self.points = points
    }
}

/// A sound that plays on the haptic engine, so it shares the haptics' clock.
/// `design/onboarding-band/sound/make_sounds.py` renders the files against the
/// same beats as this choreography.
public enum BandIntroSound: String, CaseIterable, Sendable {
    /// Starts at `bandIn`: a deep rise that goes quiet just before the click.
    case approach
    /// Starts at the click: a clean latch click and a short room tail.
    case click

    public var resourceName: String { "band-intro-\(rawValue)" }
    public static let fileExtension = "caf"
}

/// One sound, timed from the start of the pattern it belongs to.
public struct BandIntroSoundCue: Equatable, Sendable {
    public let sound: BandIntroSound
    public let time: TimeInterval
    /// 0...1.
    public let volume: Double

    public init(sound: BandIntroSound, time: TimeInterval, volume: Double) {
        self.sound = sound
        self.time = time
        self.volume = volume
    }
}

public struct BandIntroHapticPlan: Equatable, Sendable {
    public let events: [BandIntroHapticEvent]
    public let curves: [BandIntroHapticCurve]
    public let sounds: [BandIntroSoundCue]

    public init(events: [BandIntroHapticEvent], curves: [BandIntroHapticCurve], sounds: [BandIntroSoundCue] = []) {
        self.events = events
        self.curves = curves
        self.sounds = sounds
    }

    public static let empty = BandIntroHapticPlan(events: [], curves: [])
    public var isEmpty: Bool { events.isEmpty && sounds.isEmpty }
}

/// What a tap on the film does at a given video time.
public enum BandIntroSkipOutcome: Equatable, Sendable {
    /// Jump to the final frame. `replacesRise` is true before the click: the
    /// scheduled rise is cancelled and one click plays now. After the click the
    /// tail of the real click is left to finish and nothing new plays.
    case jumpToEnd(replacesRise: Bool, revealsText: Bool)
    /// The film already ended. The tap does nothing.
    case ignored
}

public enum BandIntroRevealElement: CaseIterable, Sendable {
    case wordmark
    case line
    case button

    /// Stagger after the reveal starts.
    public var delay: TimeInterval {
        switch self {
        case .wordmark: 0
        case .line: 0.16
        case .button: 0.38
        }
    }
}

/// Pure timing for the band intro: the haptic pattern and sounds against video
/// time, the text reveal, skip behavior, and where the text may sit in the frame.
public struct BandIntroChoreography: Equatable, Sendable {
    public static let revealDelayAfterClick: TimeInterval = 0.12
    public static let latchDelay: TimeInterval = 0.045
    public static let decayDelay: TimeInterval = 0.06
    public static let decayDuration: TimeInterval = 0.2
    /// Control points used to sample each curve. Core Haptics allows 16 per curve.
    public static let curveSamples = 12
    /// A sound that would start later than this into its own file is left out:
    /// it cannot start mid-file, and a late start would put it off the picture.
    public static let soundStartTolerance: TimeInterval = 0.03

    // Approach: a soft swell while the band flies in, handing over to the rise.
    public static let approachPeakIntensity = 0.35
    public static let approachSharpness = 0.03
    // Rising haptic, CONTRACT.md "Haptics".
    // Deep: low sharpness that only brightens a little toward the click.
    public static let riseIntensity: ClosedRange<Double> = 0.15...0.85
    public static let riseSharpness: ClosedRange<Double> = 0.05...0.3
    // Click.
    public static let clickIntensity = 1.0
    public static let clickSharpness = 0.9
    public static let latchIntensity = 0.5
    public static let latchSharpness = 1.0
    public static let decayIntensity = 0.3
    public static let decaySharpness = 0.1
    // Reduce Motion: one light click.
    public static let lightClickIntensity = 0.55
    public static let lightClickSharpness = 0.8
    public static let lightClickVolume = 0.55

    public let timings: BandIntroTimings

    public init(timings: BandIntroTimings) {
        self.timings = timings
    }

    public var revealTime: TimeInterval { timings.click + Self.revealDelayAfterClick }

    /// Video time after which no haptic from the film is left to play.
    public var hapticsEndTime: TimeInterval {
        timings.click + Self.decayDelay + Self.decayDuration
    }

    /// Ease-in used for the rise, `u` in 0...1.
    public static func easeIn(_ u: Double) -> Double {
        let clamped = min(max(u, 0), 1)
        return clamped * clamped
    }

    private func riseProgress(atVideoTime time: TimeInterval) -> Double {
        Self.easeIn((time - timings.wrapStart) / (timings.click - timings.wrapStart))
    }

    /// Felt intensity of the rise at a video time inside the wrap.
    public func riseIntensity(atVideoTime time: TimeInterval) -> Double {
        let range = Self.riseIntensity
        return range.lowerBound + (range.upperBound - range.lowerBound) * riseProgress(atVideoTime: time)
    }

    /// Felt sharpness of the rise at a video time inside the wrap.
    public func riseSharpness(atVideoTime time: TimeInterval) -> Double {
        let range = Self.riseSharpness
        return range.lowerBound + (range.upperBound - range.lowerBound) * riseProgress(atVideoTime: time)
    }

    /// Felt intensity of the approach swell between `bandIn` and `wrapStart`:
    /// a bell that follows the whoosh, landing on the rise's first value.
    public func approachIntensity(atVideoTime time: TimeInterval) -> Double {
        let span = timings.wrapStart - timings.bandIn
        guard span > 0 else { return Self.riseIntensity.lowerBound }
        let u = min(max((time - timings.bandIn) / span, 0), 1)
        let bell = pow(sin(Double.pi * u), 1.5)
        let handOver = u * u * (3 - 2 * u)
        return 0.2 * bell + Self.riseIntensity.lowerBound * handOver
    }

    /// The film's haptic pattern and sounds for a player that starts at `videoTime`.
    ///
    /// Event times are relative to `videoTime`. A click already in the past is
    /// dropped with its tail, and a swell or rise that has already begun is
    /// trimmed so it resumes at the level it would have reached. Each
    /// continuous event carries its peak values and curves scale it down. The
    /// rise curves finish at the neutral values (x1 intensity, +0 sharpness)
    /// exactly at the click, so the click and its tail play at their stated
    /// values. A sound whose start has passed is left out.
    public func hapticPlan(fromVideoTime videoTime: TimeInterval) -> BandIntroHapticPlan {
        var events: [BandIntroHapticEvent] = []
        var curves: [BandIntroHapticCurve] = []
        var sounds: [BandIntroSoundCue] = []
        let click = timings.click

        if videoTime <= timings.bandIn + Self.soundStartTolerance, timings.bandIn < click {
            sounds.append(BandIntroSoundCue(sound: .approach, time: max(0, timings.bandIn - videoTime), volume: 1))
        }

        let approachStart = max(videoTime, timings.bandIn)
        if approachStart < timings.wrapStart {
            let peak = Self.approachPeakIntensity
            events.append(BandIntroHapticEvent(
                kind: .continuous(duration: timings.wrapStart - approachStart),
                time: approachStart - videoTime,
                intensity: peak,
                sharpness: Self.approachSharpness
            ))
            curves.append(sampledCurve(.intensityControl, from: approachStart, to: timings.wrapStart, videoTime: videoTime) {
                approachIntensity(atVideoTime: $0) / peak
            })
        }

        let riseStart = max(videoTime, timings.wrapStart)
        if riseStart < click {
            let peakIntensity = Self.riseIntensity.upperBound
            let peakSharpness = Self.riseSharpness.upperBound
            events.append(BandIntroHapticEvent(
                kind: .continuous(duration: click - riseStart),
                time: riseStart - videoTime,
                intensity: peakIntensity,
                sharpness: peakSharpness
            ))
            curves.append(sampledCurve(.intensityControl, from: riseStart, to: click, videoTime: videoTime) {
                riseIntensity(atVideoTime: $0) / peakIntensity
            })
            curves.append(sampledCurve(.sharpnessControl, from: riseStart, to: click, videoTime: videoTime) {
                riseSharpness(atVideoTime: $0) - peakSharpness
            })
        }

        // The latch and decay only make sense after a felt click, so
        // a player started after the click gets none of the tail.
        if click >= videoTime {
            let clickTail = Self.clickPlan(at: click - videoTime)
            events += clickTail.events
            curves += clickTail.curves
            sounds += clickTail.sounds
        }
        return BandIntroHapticPlan(events: events, curves: curves, sounds: sounds)
    }

    /// `value` sampled from video time `start` to `end`, as a curve relative to `videoTime`.
    private func sampledCurve(
        _ parameter: BandIntroHapticCurve.Parameter,
        from start: TimeInterval,
        to end: TimeInterval,
        videoTime: TimeInterval,
        value: (TimeInterval) -> Double
    ) -> BandIntroHapticCurve {
        let length = end - start
        let times = (0..<Self.curveSamples).map { start + length * Double($0) / Double(Self.curveSamples - 1) }
        return BandIntroHapticCurve(
            parameter: parameter,
            time: start - videoTime,
            points: times.map { .init(time: $0 - start, value: value($0)) }
        )
    }

    /// Click, latch tick and a short soft decay, with the click at `time`, and
    /// the click sound. No control curve runs here, so nothing scales the tail.
    public static func clickPlan(at time: TimeInterval = 0) -> BandIntroHapticPlan {
        let events = [
            BandIntroHapticEvent(kind: .transient, time: time, intensity: clickIntensity, sharpness: clickSharpness),
            BandIntroHapticEvent(kind: .transient, time: time + latchDelay, intensity: latchIntensity, sharpness: latchSharpness),
            BandIntroHapticEvent(
                kind: .continuous(duration: decayDuration),
                time: time + decayDelay,
                intensity: decayIntensity,
                sharpness: decaySharpness,
                decayTime: decayDuration
            )
        ]
        return BandIntroHapticPlan(
            events: events,
            curves: [],
            sounds: [BandIntroSoundCue(sound: .click, time: time, volume: 1)]
        )
    }

    /// Reduce Motion: a single light click with a quieter click sound.
    public static let lightClickPlan = BandIntroHapticPlan(
        events: [
            BandIntroHapticEvent(
                kind: .transient,
                time: 0,
                intensity: lightClickIntensity,
                sharpness: lightClickSharpness
            )
        ],
        curves: [],
        sounds: [BandIntroSoundCue(sound: .click, time: 0, volume: lightClickVolume)]
    )

    public func skipOutcome(atVideoTime videoTime: TimeInterval) -> BandIntroSkipOutcome {
        guard videoTime < timings.duration else { return .ignored }
        return .jumpToEnd(replacesRise: videoTime < timings.click, revealsText: videoTime < revealTime)
    }

    /// Vertical band of the screen, in screen points from the top, where the
    /// text may sit: the film's clean top area under aspect-fill scaling, cut
    /// off at the top safe-area inset.
    public func textRegion(
        screenWidth: Double,
        screenHeight: Double,
        safeAreaTop: Double,
        videoWidth: Double = 1080,
        videoHeight: Double = 2340
    ) -> ClosedRange<Double> {
        guard screenWidth > 0, screenHeight > 0, videoWidth > 0, videoHeight > 0 else {
            return safeAreaTop...safeAreaTop
        }
        let scale = max(screenWidth / videoWidth, screenHeight / videoHeight)
        let shownHeight = videoHeight * scale
        let videoTop = (screenHeight - shownHeight) / 2
        let top = max(videoTop, safeAreaTop)
        let bottom = max(top, videoTop + shownHeight * timings.textSafeTopFraction)
        return top...bottom
    }
}
