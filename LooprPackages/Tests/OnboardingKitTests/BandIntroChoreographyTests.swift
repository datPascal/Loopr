import Foundation
import Testing
@testable import OnboardingKit
#if os(iOS)
import CoreHaptics
#endif

struct BandIntroChoreographyTests {
    private let choreography = BandIntroChoreography(timings: .contract)
    private let tolerance = 1e-9

    // MARK: Timings

    @Test
    func contractTimingsMatchCONTRACT() {
        let timings = BandIntroTimings.contract
        #expect(timings.fps == 60)
        #expect(timings.duration == 4.6)
        #expect(timings.wrapStart == 1.9)
        #expect(timings.click == 3.0)
        #expect(timings.textSafeTopFraction == 0.36)
        #expect(timings.background == "#0A0D11")
        #expect(timings.isCoherent)
    }

    @Test
    func decodesTheContractJSONShape() {
        let json = ##"{"fps":60,"duration":5.0,"handInEnd":1.5,"bandIn":1.5,"wrapStart":2.0,"click":3.2,"settleEnd":5.0,"background":"#07090B","textSafeTopFraction":0.4}"##
        let timings = BandIntroTimings.decode(Data(json.utf8))
        #expect(timings.duration == 5.0)
        #expect(timings.wrapStart == 2.0)
        #expect(timings.click == 3.2)
        #expect(timings.background == "#07090B")
        #expect(timings.textSafeTopFraction == 0.4)
    }

    @Test
    func missingKeysTakeContractValues() {
        let timings = BandIntroTimings.decode(Data(#"{"click":3.1}"#.utf8))
        #expect(timings.click == 3.1)
        #expect(timings.wrapStart == BandIntroTimings.contract.wrapStart)
        #expect(timings.background == BandIntroTimings.contract.background)
    }

    @Test
    func missingUnreadableOrIncoherentFilesFallBackToTheContract() {
        #expect(BandIntroTimings.decode(nil) == .contract)
        #expect(BandIntroTimings.decode(Data("not json".utf8)) == .contract)
        // Click before the wrap starts.
        #expect(BandIntroTimings.decode(Data(#"{"wrapStart":3.5,"click":3.0}"#.utf8)) == .contract)
        // Click after the film ends.
        #expect(BandIntroTimings.decode(Data(#"{"click":9.0}"#.utf8)) == .contract)
        #expect(BandIntroTimings.decode(Data(#"{"background":"blue"}"#.utf8)) == .contract)
        #expect(BandIntroTimings.decode(Data(#"{"textSafeTopFraction":0}"#.utf8)) == .contract)
        #expect(BandIntroTimings.load(from: URL(fileURLWithPath: "/nonexistent/band-intro.timings.json")) == .contract)
    }

    @Test
    func loadsTimingsFromAFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("band-intro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(BandIntroAssets.timingsFileName)
        try Data(#"{"click":2.8}"#.utf8).write(to: url)

        let assets = BandIntroAssets(directory: directory)
        #expect(assets.timingsURL == url)
        #expect(assets.videoURL == nil)
        #expect(assets.posterURL == nil)
        #expect(BandIntroTimings.load(from: assets.timingsURL).click == 2.8)
        #expect(assets.soundURLs.isEmpty)
    }

    @Test
    func findsTheSoundsNextToTheFilm() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("band-intro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let click = directory.appendingPathComponent("band-intro-click.caf")
        try Data([0]).write(to: click)

        // Only the sound that exists is offered; the approach plays without one.
        #expect(BandIntroAssets(directory: directory).soundURLs == [.click: click])
    }

    @Test
    func parsesTheBackgroundHex() throws {
        let rgb = try #require(BandIntroTimings.contract.backgroundRGB)
        #expect(abs(rgb.red - 10.0 / 255) < tolerance)
        #expect(abs(rgb.green - 13.0 / 255) < tolerance)
        #expect(abs(rgb.blue - 17.0 / 255) < tolerance)
    }

    // MARK: Full pattern from the first frame

    /// The rise event and its intensity curve (the approach curve comes first).
    private func riseCurve(
        _ plan: BandIntroHapticPlan,
        _ parameter: BandIntroHapticCurve.Parameter,
        startingAt time: TimeInterval
    ) -> BandIntroHapticCurve? {
        plan.curves.first { $0.parameter == parameter && abs($0.time - time) < tolerance }
    }

    @Test
    func fullPatternRisesFromWrapStartToClick() throws {
        let plan = choreography.hapticPlan(fromVideoTime: 0)
        let rise = try #require(plan.events.first { $0.kind == .continuous(duration: 3.0 - 1.9) })
        #expect(rise.kind == .continuous(duration: 3.0 - 1.9))
        #expect(abs(rise.time - 1.9) < tolerance)

        let curves = plan.curves.filter { abs($0.time - 1.9) < tolerance }
        let intensity = try #require(curves.first { $0.parameter == .intensityControl })
        let sharpness = try #require(curves.first { $0.parameter == .sharpnessControl })
        #expect(intensity.points.count <= 16)
        #expect(sharpness.points.count <= 16)

        // Felt values: event value times (or plus) the control value.
        let firstIntensity = rise.intensity * intensity.points.first!.value
        let lastIntensity = rise.intensity * intensity.points.last!.value
        let firstSharpness = rise.sharpness + sharpness.points.first!.value
        let lastSharpness = rise.sharpness + sharpness.points.last!.value
        #expect(abs(firstIntensity - 0.15) < tolerance)
        #expect(abs(lastIntensity - 0.85) < tolerance)
        #expect(abs(firstSharpness - 0.05) < tolerance)
        #expect(abs(lastSharpness - 0.3) < tolerance)
        #expect(abs(intensity.points.last!.time - 1.1) < tolerance)
    }

    @Test
    func riseCurvesEndNeutralSoTheClickIsNotScaled() throws {
        let plan = choreography.hapticPlan(fromVideoTime: 0)
        let intensity = try #require(riseCurve(plan, .intensityControl, startingAt: 1.9))
        let sharpness = try #require(riseCurve(plan, .sharpnessControl, startingAt: 1.9))
        #expect(abs(intensity.points.last!.value - 1) < tolerance)
        #expect(abs(sharpness.points.last!.value) < tolerance)
    }

    @Test
    func riseEasesIn() throws {
        let plan = choreography.hapticPlan(fromVideoTime: 0)
        let intensity = try #require(riseCurve(plan, .intensityControl, startingAt: 1.9))
        let values = intensity.points.map(\.value)
        let steps = zip(values.dropFirst(), values).map { $0 - $1 }
        #expect(steps.allSatisfy { $0 > 0 })
        // Accelerating: each step is larger than the one before.
        #expect(zip(steps.dropFirst(), steps).allSatisfy { $0 > $1 })
        // Halfway through the wrap the rise is below the linear midpoint.
        #expect(choreography.riseIntensity(atVideoTime: 2.45) < 0.5)
    }

    @Test
    func clickLatchAndDecayFollowTheContract() throws {
        let plan = choreography.hapticPlan(fromVideoTime: 0)
        let transients = plan.events.filter { $0.kind == .transient && $0.time >= 3.0 - tolerance }
        #expect(transients.count == 2)
        let click = transients[0]
        let latch = transients[1]
        #expect(abs(click.time - 3.0) < tolerance)
        #expect(click.intensity == 1.0)
        #expect(click.sharpness == 0.9)
        #expect(abs(latch.time - 3.045) < tolerance)
        #expect(latch.intensity == 0.5)
        #expect(latch.sharpness == 1.0)

        let decay = try #require(plan.events.first { $0.time > 3.0 && $0.kind != .transient })
        guard case .continuous(let duration) = decay.kind else {
            Issue.record("decay should be continuous")
            return
        }
        #expect(decay.time > latch.time)
        #expect(duration < 0.4)
        #expect(decay.intensity < click.intensity)
        #expect(decay.sharpness < 0.3)
        // The decay fades on its own envelope, not on a control curve, so it
        // cannot soften anything else.
        #expect(decay.decayTime == duration)
        #expect(!plan.curves.contains { $0.time > 3.0 - tolerance })
    }

    // MARK: Approach

    @Test
    func approachSwellsFromBandInAndHandsOverToTheRise() throws {
        let plan = choreography.hapticPlan(fromVideoTime: 0)
        let approach = try #require(plan.events.first)
        #expect(approach.kind == .continuous(duration: 1.9 - 1.4))
        #expect(abs(approach.time - 1.4) < tolerance)
        let curve = try #require(plan.curves.first)
        #expect(abs(curve.time - 1.4) < tolerance)
        #expect(curve.points.count <= 16)
        let felt = curve.points.map { approach.intensity * $0.value }
        #expect(felt.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(abs(felt.first!) < tolerance)
        // Lands where the rise starts, so there is no step at wrapStart.
        #expect(abs(felt.last! - 0.15) < tolerance)
        #expect(felt.max()! < BandIntroChoreography.riseIntensity.upperBound)
        #expect(approach.sharpness < BandIntroChoreography.riseSharpness.lowerBound)
    }

    // MARK: Sounds

    @Test
    func soundsStartOnTheirBeats() {
        let plan = choreography.hapticPlan(fromVideoTime: 0)
        #expect(plan.sounds == [
            BandIntroSoundCue(sound: .approach, time: 1.4, volume: 1),
            BandIntroSoundCue(sound: .click, time: 3.0, volume: 1)
        ])
        #expect(BandIntroChoreography.clickPlan().sounds == [BandIntroSoundCue(sound: .click, time: 0, volume: 1)])
        #expect(BandIntroChoreography.lightClickPlan.sounds.map(\.sound) == [.click])
        #expect(BandIntroChoreography.lightClickPlan.sounds[0].volume < 1)
    }

    @Test
    func aSoundThatAlreadyStartedIsLeftOut() {
        // Just past the start: still plays, from the top.
        #expect(choreography.hapticPlan(fromVideoTime: 1.42).sounds.first == BandIntroSoundCue(sound: .approach, time: 0, volume: 1))
        // Mid-approach: the approach cannot start mid-file, the click still plays.
        #expect(choreography.hapticPlan(fromVideoTime: 2.5).sounds.map(\.sound) == [.click])
        #expect(abs(choreography.hapticPlan(fromVideoTime: 2.5).sounds[0].time - 0.5) < tolerance)
        #expect(choreography.hapticPlan(fromVideoTime: 3.01).sounds.isEmpty)
    }

    @Test
    func noCurveIsActiveAtTheClickOrLatch() {
        // Control curves apply to every event while they run. Only the
        // approach curve and the rise curves (ending at the click, neutral)
        // exist, so the click and latch play at their stated values.
        let plan = choreography.hapticPlan(fromVideoTime: 0)
        for curve in plan.curves {
            let start = curve.time
            let end = curve.time + (curve.points.last?.time ?? 0)
            let slack = 1e-6
            let coversLatch = start <= 3.045 && 3.045 < end - slack
            let coversClickStrictly = start <= 3.0 && 3.0 < end - slack
            #expect(!coversLatch)
            #expect(!coversClickStrictly)
        }
    }

    // MARK: Starting against the video clock

    @Test
    func patternTimesAreRelativeToThePlaybackTime() {
        let fromStart = choreography.hapticPlan(fromVideoTime: 0)
        let fromLater = choreography.hapticPlan(fromVideoTime: 0.75)
        #expect(fromStart.events.count == fromLater.events.count)
        for (a, b) in zip(fromStart.events, fromLater.events) {
            #expect(abs((a.time - 0.75) - b.time) < tolerance)
        }
    }

    @Test
    func startingMidRiseTrimsTheRiseAndResumesAtTheRightLevel() throws {
        let plan = choreography.hapticPlan(fromVideoTime: 2.5)
        let rise = try #require(plan.events.first)
        #expect(rise.time == 0)
        guard case .continuous(let duration) = rise.kind else {
            Issue.record("rise should be continuous")
            return
        }
        #expect(abs(duration - 0.5) < tolerance)

        let intensity = try #require(plan.curves.first { $0.parameter == .intensityControl })
        let resumed = rise.intensity * intensity.points.first!.value
        #expect(abs(resumed - choreography.riseIntensity(atVideoTime: 2.5)) < tolerance)
        #expect(abs(intensity.points.last!.time - 0.5) < tolerance)
        #expect(abs(rise.intensity * intensity.points.last!.value - 0.85) < tolerance)

        let click = try #require(plan.events.first { $0.kind == .transient && $0.intensity == 1.0 })
        #expect(abs(click.time - 0.5) < tolerance)
    }

    @Test
    func startingAfterTheClickSchedulesNothing() {
        #expect(choreography.hapticPlan(fromVideoTime: 3.01).isEmpty)
        #expect(choreography.hapticPlan(fromVideoTime: 3.01).curves.isEmpty)
        #expect(choreography.hapticPlan(fromVideoTime: 4.6).isEmpty)
    }

    @Test
    func startingExactlyAtTheClickPlaysTheClickWithoutARise() {
        let plan = choreography.hapticPlan(fromVideoTime: 3.0)
        #expect(plan.events.first == BandIntroHapticEvent(kind: .transient, time: 0, intensity: 1.0, sharpness: 0.9))
        #expect(plan.events.allSatisfy { $0.time >= 0 })
        #expect(!plan.curves.contains { $0.parameter == .sharpnessControl })
    }

    @Test
    func followsCustomTimings() throws {
        var timings = BandIntroTimings.contract
        timings.wrapStart = 2.2
        timings.click = 3.4
        let plan = BandIntroChoreography(timings: timings).hapticPlan(fromVideoTime: 0)
        let rise = try #require(plan.events.first { $0.kind == .continuous(duration: 3.4 - 2.2) })
        #expect(abs(rise.time - 2.2) < tolerance)
        let click = try #require(plan.events.first { $0.kind == .transient && $0.intensity == 1.0 })
        #expect(abs(click.time - 3.4) < tolerance)
        #expect(abs(BandIntroChoreography(timings: timings).revealTime - 3.52) < tolerance)
    }

    // MARK: Reveal and skip

    @Test
    func revealStartsJustAfterTheClickAndStaggers() {
        #expect(abs(choreography.revealTime - 3.12) < tolerance)
        let delays = BandIntroRevealElement.allCases.map(\.delay)
        #expect(delays == delays.sorted())
        #expect(BandIntroRevealElement.wordmark.delay == 0)
        #expect(BandIntroRevealElement.button.delay > BandIntroRevealElement.line.delay)
    }

    @Test
    func skipBeforeTheClickReplacesTheRiseWithOneClick() {
        #expect(choreography.skipOutcome(atVideoTime: 0.4) == .jumpToEnd(replacesRise: true, revealsText: true))
        #expect(choreography.skipOutcome(atVideoTime: 2.6) == .jumpToEnd(replacesRise: true, revealsText: true))
        let click = BandIntroChoreography.clickPlan()
        #expect(click.events.filter { $0.kind == .transient }.first?.time == 0)
        #expect(!click.events.contains { $0.kind == .continuous(duration: 3.0 - 1.9) })
    }

    @Test
    func skipAfterTheClickAddsNoSecondClick() {
        #expect(choreography.skipOutcome(atVideoTime: 3.05) == .jumpToEnd(replacesRise: false, revealsText: true))
        #expect(choreography.skipOutcome(atVideoTime: 4.0) == .jumpToEnd(replacesRise: false, revealsText: false))
        #expect(choreography.skipOutcome(atVideoTime: 4.6) == .ignored)
    }

    @Test
    func reduceMotionIsOneLightClick() {
        let plan = BandIntroChoreography.lightClickPlan
        #expect(plan.events.count == 1)
        #expect(plan.events[0].kind == .transient)
        #expect(plan.events[0].intensity < BandIntroChoreography.clickIntensity)
        #expect(plan.curves.isEmpty)
    }

    // MARK: Text placement

    @Test
    func textRegionOnAnIPhone17() {
        // 402 x 874 pt, 62 pt top inset. The film (1080 / 2340 = 0.4615) is a
        // touch wider than the screen (402 / 874 = 0.4600), so aspect-fill
        // scales by height: the film spans the full height and loses a few
        // points at the sides. The clean area is the top 36 % of the screen.
        let region = choreography.textRegion(screenWidth: 402, screenHeight: 874, safeAreaTop: 62)
        #expect(abs(region.lowerBound - 62) < tolerance)
        #expect(abs(region.upperBound - 874 * 0.36) < tolerance)
    }

    @Test
    func textRegionFollowsTheCropWhenTheScreenIsWiderThanTheFilm() {
        // 1024 x 1366: aspect-fill scales by width, the film overflows the
        // screen vertically and its top edge sits above the screen.
        let region = choreography.textRegion(screenWidth: 1024, screenHeight: 1366, safeAreaTop: 24)
        let shown = 2340 * (1024.0 / 1080)
        let videoTop = (1366 - shown) / 2
        #expect(videoTop < 0)
        #expect(abs(region.lowerBound - 24) < tolerance)
        #expect(abs(region.upperBound - (videoTop + shown * 0.36)) < tolerance)
    }

    @Test
    func textRegionNeverStartsAboveTheSafeArea() {
        let region = choreography.textRegion(screenWidth: 1024, screenHeight: 1366, safeAreaTop: 24)
        #expect(region.lowerBound >= 24)
        #expect(region.upperBound >= region.lowerBound)
        let degenerate = choreography.textRegion(screenWidth: 0, screenHeight: 0, safeAreaTop: 20)
        #expect(degenerate == 20...20)
    }

    // MARK: Core Haptics

    #if os(iOS)
    @Test
    func plansBuildValidCoreHapticsPatterns() throws {
        for plan in [
            choreography.hapticPlan(fromVideoTime: 0),
            choreography.hapticPlan(fromVideoTime: 2.5),
            BandIntroChoreography.clickPlan(),
            BandIntroChoreography.lightClickPlan
        ] {
            let pattern = try plan.makePattern()
            #expect(pattern.duration >= 0)
            // Unregistered sounds are skipped, never fatal.
            _ = try plan.makePattern(audioResources: [:])
        }
        let full = try choreography.hapticPlan(fromVideoTime: 0).makePattern()
        #expect(full.duration >= choreography.hapticsEndTime - 0.01)
    }
    #endif
}
