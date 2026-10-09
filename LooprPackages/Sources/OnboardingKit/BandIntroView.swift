import Foundation

/// Where the intro film, its poster frame, its timings and its sounds live.
public struct BandIntroAssets: Equatable, Sendable {
    public static let baseName = "band-intro"
    public static let videoFileName = "band-intro.mp4"
    public static let posterFileName = "band-intro-poster.png"
    public static let timingsFileName = "band-intro.timings.json"

    public let videoURL: URL?
    public let posterURL: URL?
    public let timingsURL: URL?
    /// Missing sounds are left out; the haptics play without them.
    public let soundURLs: [BandIntroSound: URL]

    public init(videoURL: URL?, posterURL: URL?, timingsURL: URL?, soundURLs: [BandIntroSound: URL] = [:]) {
        self.videoURL = videoURL
        self.posterURL = posterURL
        self.timingsURL = timingsURL
        self.soundURLs = soundURLs
    }

    /// The files inside one directory. Missing files resolve to nil.
    public init(directory: URL, fileManager: FileManager = .default) {
        func existing(_ name: String) -> URL? {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        self.init(
            videoURL: existing(Self.videoFileName),
            posterURL: existing(Self.posterFileName),
            timingsURL: existing(Self.timingsFileName),
            soundURLs: Dictionary(uniqueKeysWithValues: BandIntroSound.allCases.compactMap { sound in
                existing("\(sound.resourceName).\(BandIntroSound.fileExtension)").map { (sound, $0) }
            })
        )
    }

    /// The files as the app target ships them. Xcode's synchronized folders copy
    /// `Resources/Onboarding/*` flat into the bundle root; the `Onboarding`
    /// subdirectory is checked too in case the folder is ever copied as a
    /// folder reference.
    ///
    /// `film` picks an alternative cut (`<film>.mp4` and `<film>-poster.png`)
    /// that shares the timings and sounds of the main film.
    public static func bundled(in bundle: Bundle, film: String = baseName) -> BandIntroAssets {
        func find(_ name: String, _ ext: String) -> URL? {
            bundle.url(forResource: name, withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Onboarding")
        }
        return BandIntroAssets(
            videoURL: find(film, "mp4"),
            posterURL: find("\(film)-poster", "png"),
            timingsURL: find("\(baseName).timings", "json"),
            soundURLs: Dictionary(uniqueKeysWithValues: BandIntroSound.allCases.compactMap { sound in
                find(sound.resourceName, BandIntroSound.fileExtension).map { (sound, $0) }
            })
        )
    }
}

#if os(iOS)
import AVFoundation
import DesignSystem
import Observation
import SwiftUI
import UIKit

/// Drives the film, the haptics and sounds, and the text reveal against the video clock.
///
/// The haptic pattern is never started on a wall-clock guess. When the player
/// reports `.playing`, the current item time is read and the pattern is built
/// from that video time, then started on the haptic engine clock a short lead
/// later. Whenever playback leaves `.playing` (stall, pause, background) the
/// pattern is stopped and it is rebuilt from the new video time when playback
/// resumes, so the two clocks cannot drift apart. The text reveal hangs off a
/// boundary time observer on the player, so it also follows the video.
@MainActor
@Observable
final class BandIntroPlayback {
    enum Presentation: Equatable {
        /// The film plays with the rising haptic and the click.
        case film
        /// Poster (if present) and text in place, one light click. Used for
        /// Reduce Motion and when the film is missing or cannot play.
        case still
    }

    /// Time between reading the video clock and the pattern's first moment,
    /// long enough for the engine to accept the player before it is due.
    static let hapticLead: TimeInterval = 0.05

    let choreography: BandIntroChoreography
    private(set) var presentation: Presentation
    let player: AVPlayer?
    let poster: UIImage?
    private(set) var isRevealed = false
    private(set) var revealIsAnimated = true
    private(set) var showsPoster: Bool
    private(set) var hasFinished = false

    /// Pixel size of the film frame, for placing the text in its clean area.
    var frameSize: CGSize {
        guard let poster, poster.size.width > 0, poster.size.height > 0 else { return CGSize(width: 1080, height: 2340) }
        return CGSize(width: poster.size.width * poster.scale, height: poster.size.height * poster.scale)
    }

    @ObservationIgnored private let haptics: BandIntroHaptics
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var notificationTokens: [any NSObjectProtocol] = []
    @ObservationIgnored private var boundaryToken: Any?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var skipped = false
    @ObservationIgnored private var filmEnded = false
    @ObservationIgnored private var isInForeground = true

    init(
        assets: BandIntroAssets,
        reduceMotion: Bool,
        haptics: BandIntroHaptics? = nil
    ) {
        choreography = BandIntroChoreography(timings: BandIntroTimings.load(from: assets.timingsURL))
        poster = assets.posterURL.flatMap { UIImage(contentsOfFile: $0.path) }
        self.haptics = haptics ?? BandIntroHaptics(soundURLs: assets.soundURLs)
        if !reduceMotion, let videoURL = assets.videoURL {
            let item = AVPlayerItem(url: videoURL)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            self.player = player
            presentation = .film
            showsPoster = false
        } else {
            player = nil
            presentation = .still
            showsPoster = true
        }
    }

    func start(revealImmediately: Bool) {
        guard !started else { return }
        started = true
        switch presentation {
        case .still:
            reveal(animated: false)
            haptics.play(BandIntroChoreography.lightClickPlan)
        case .film:
            // The film itself is silent. Its sounds play on the haptic engine
            // in an ambient session (see BandIntroHaptics), which also keeps
            // a stray audio track from stopping the user's music.
            try? AVAudioSession.sharedInstance().setCategory(.ambient)
            if revealImmediately { reveal(animated: false) }
            haptics.onEngineReset = { [weak self] in self?.scheduleHaptics() }
            haptics.prepare()
            observePlayer()
            playIfReady()
        }
    }

    /// Tap on the film: jump to the final frame and reveal. Before the click
    /// the rise is cancelled and one click plays instead.
    func skip() {
        guard presentation == .film, !skipped, !filmEnded, !hasFinished, let player else { return }
        switch choreography.skipOutcome(atVideoTime: player.currentTime().seconds) {
        case .ignored:
            return
        case .jumpToEnd(let replacesRise, _):
            skipped = true
            player.pause()
            let end = CMTime(seconds: choreography.timings.duration, preferredTimescale: 600)
            player.seek(to: end, toleranceBefore: .zero, toleranceAfter: .zero)
            if poster != nil {
                withAnimation(.easeOut(duration: 0.28)) { showsPoster = true }
            }
            if replacesRise {
                haptics.play(BandIntroChoreography.clickPlan())
            }
            reveal(animated: true)
        }
    }

    func reveal(animated: Bool) {
        guard !isRevealed else { return }
        revealIsAnimated = animated
        if animated {
            // Each element's transition carries its own curve and stagger.
            withAnimation(.linear(duration: 0.01)) { isRevealed = true }
        } else {
            isRevealed = true
        }
    }

    func sceneBecameActive(_ active: Bool) {
        isInForeground = active
        guard presentation == .film, started, let player else { return }
        if active {
            // Resuming fires `.playing` again, which reschedules the haptics.
            if !skipped, !filmEnded { player.play() }
        } else {
            player.pause()
            haptics.shutdown()
        }
    }

    /// The user tapped Get started or the screen went away.
    func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        haptics.onEngineReset = nil
        haptics.shutdown()
        if let boundaryToken { player?.removeTimeObserver(boundaryToken) }
        boundaryToken = nil
        observations.forEach { $0.invalidate() }
        observations = []
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens = []
        player?.pause()
    }

    // MARK: - Player events

    private func observePlayer() {
        guard let player, let item = player.currentItem else { return }
        let reveal = CMTime(seconds: choreography.revealTime, preferredTimescale: 600)
        boundaryToken = Self.addRevealObserver(to: player, at: reveal, owner: self)
        observations = Self.observe(player: player, item: item, owner: self)
        notificationTokens = Self.observeNotifications(for: item, owner: self)
    }

    fileprivate func itemStatusChanged() {
        guard presentation == .film, let item = player?.currentItem else { return }
        switch item.status {
        case .readyToPlay: playIfReady()
        case .failed: fallBackToStill()
        default: break
        }
    }

    fileprivate func timeControlStatusChanged() {
        guard presentation == .film, !skipped, !hasFinished, let player else { return }
        if player.timeControlStatus == .playing {
            scheduleHaptics()
        } else {
            // Paused or stalled: stop now instead of letting the pattern run
            // ahead of a frozen picture.
            haptics.stop()
        }
    }

    fileprivate func playbackStalled() {
        guard !skipped else { return }
        haptics.stop()
    }

    fileprivate func filmDidEnd() {
        filmEnded = true
        reveal(animated: true)
        // The last haptic ended with the click decay; release the actuator.
        haptics.shutdown()
    }

    private func playIfReady() {
        guard started, !skipped, !filmEnded, !hasFinished, isInForeground,
              let player, player.currentItem?.status == .readyToPlay else { return }
        player.play()
    }

    private func scheduleHaptics() {
        guard presentation == .film, !skipped, !hasFinished, isInForeground,
              let player, player.timeControlStatus == .playing else { return }
        let now = player.currentTime().seconds
        guard now.isFinite, now <= choreography.timings.click else { return }
        haptics.play(
            choreography.hapticPlan(fromVideoTime: now + Self.hapticLead),
            lead: Self.hapticLead
        )
    }

    private func fallBackToStill() {
        haptics.stop()
        presentation = .still
        showsPoster = true
        reveal(animated: true)
    }

    // MARK: - Observer installation
    //
    // AVFoundation calls these closures on its own threads. They are built in
    // nonisolated functions so they carry no main-actor isolation, and each one
    // hops to the main actor before touching the playback state.

    private nonisolated static func addRevealObserver(
        to player: AVPlayer,
        at time: CMTime,
        owner: BandIntroPlayback
    ) -> Any {
        player.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { [weak owner] in
            MainActor.assumeIsolated { owner?.reveal(animated: true) }
        }
    }

    private nonisolated static func observe(
        player: AVPlayer,
        item: AVPlayerItem,
        owner: BandIntroPlayback
    ) -> [NSKeyValueObservation] {
        [
            item.observe(\.status, options: [.initial, .new]) { [weak owner] _, _ in
                Task { @MainActor [owner] in owner?.itemStatusChanged() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak owner] _, _ in
                Task { @MainActor [owner] in owner?.timeControlStatusChanged() }
            }
        ]
    }

    private nonisolated static func observeNotifications(
        for item: AVPlayerItem,
        owner: BandIntroPlayback
    ) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) {
                [weak owner] _ in
                MainActor.assumeIsolated { owner?.filmDidEnd() }
            },
            center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) {
                [weak owner] _ in
                MainActor.assumeIsolated { owner?.playbackStalled() }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) {
                [weak owner] _ in
                MainActor.assumeIsolated { owner?.fallBackToStill() }
            }
        ]
    }
}

/// The first screen a new user sees: a hand, a band that wraps the wrist and
/// clicks shut, then the wordmark, one line, and Get started.
public struct BandIntroView: View {
    public static let wordmark = "Loopr"
    /// No pricing promise here: no product decision commits Loopr to
    /// "free, forever", so the first line of the product says what
    /// it does instead.
    public static let line = "Own your health data. Keep it on your iPhone."
    public static let buttonTitle = "Get started"

    private let assets: BandIntroAssets
    private let onGetStarted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback: BandIntroPlayback?

    public init(assets: BandIntroAssets, onGetStarted: @escaping () -> Void) {
        self.assets = assets
        self.onGetStarted = onGetStarted
    }

    public var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let screen = CGSize(
                width: proxy.size.width + insets.leading + insets.trailing,
                height: proxy.size.height + insets.top + insets.bottom
            )
            ZStack(alignment: .top) {
                backgroundColor.ignoresSafeArea()
                if let playback {
                    film(playback)
                    // Tap anywhere to skip. A layer of its own under the text
                    // and button, so it never competes with Get started for a tap.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { playback.skip() }
                        .accessibilityHidden(true)
                    content(playback, screen: screen, safeTop: insets.top)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        // A container of its own, so an identifier set by the parent screen
        // lands on the container and does not overwrite the button's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("band-intro")
        .onAppear(perform: startIfNeeded)
        .onDisappear { playback?.finish() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { playback?.sceneBecameActive(false) }
            if phase == .active { playback?.sceneBecameActive(true) }
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { playback?.reveal(animated: false) }
        }
    }

    private var reduceMotion: Bool {
        systemReduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }

    private var backgroundColor: Color {
        let timings = playback?.choreography.timings ?? .contract
        guard let rgb = timings.backgroundRGB ?? BandIntroTimings.contract.backgroundRGB else {
            return Color.loopr(.background)
        }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func startIfNeeded() {
        guard playback == nil else { return }
        let created = BandIntroPlayback(assets: assets, reduceMotion: reduceMotion)
        playback = created
        created.start(revealImmediately: voiceOverEnabled)
    }

    @ViewBuilder
    private func film(_ playback: BandIntroPlayback) -> some View {
        ZStack {
            if let player = playback.player, playback.presentation == .film {
                BandIntroPlayerLayerView(player: player, background: UIColor(backgroundColor))
                    .accessibilityHidden(true)
            }
            if playback.showsPoster, let poster = playback.poster {
                // Same aspect-fill crop as the player layer, so the poster
                // lands exactly on the film's last frame.
                Color.clear
                    .overlay {
                        Image(uiImage: poster)
                            .resizable()
                            .scaledToFill()
                            .accessibilityHidden(true)
                    }
                    .clipped()
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func content(_ playback: BandIntroPlayback, screen: CGSize, safeTop: CGFloat) -> some View {
        let frame = playback.frameSize
        let region = playback.choreography.textRegion(
            screenWidth: screen.width,
            screenHeight: screen.height,
            safeAreaTop: safeTop,
            videoWidth: frame.width,
            videoHeight: frame.height
        )
        let revealed = playback.isRevealed
        let animated = playback.revealIsAnimated
        let getStarted = {
            playback.finish()
            onGetStarted()
        }
        return VStack(spacing: 0) {
            // The text and button enter the tree only when revealed, so nothing
            // invisible can be focused by VoiceOver or take a tap meant to skip.
            VStack(spacing: LooprSpacing.sm) {
                if revealed {
                    Text(Self.wordmark)
                        .looprTypography(.hero)
                        .foregroundStyle(Color.loopr(.ink))
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .accessibilityAddTraits(.isHeader)
                        .transition(BandIntroReveal.transition(for: .wordmark, animated: animated))

                    Text(Self.line)
                        .looprTypography(.title)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                        .transition(BandIntroReveal.transition(for: .line, animated: animated))
                }
            }
            .padding(.horizontal, LooprSpacing.xxl)
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, region.upperBound - region.lowerBound - LooprSpacing.md), alignment: .center)
            .padding(.top, max(0, region.lowerBound - safeTop))
            // Taps on the text fall through to the skip layer.
            .allowsHitTesting(false)

            Spacer(minLength: LooprSpacing.xl)

            if revealed {
                // The same primary button as every onboarding step after it.
                OnboardingPrimaryButton(title: Self.buttonTitle, accent: .brand, action: getStarted)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .accessibilityIdentifier("band-intro-get-started")
                    .padding(.horizontal, LooprSpacing.xl)
                    .padding(.bottom, LooprSpacing.md)
                    .transition(BandIntroReveal.transition(for: .button, animated: animated))
            }
        }
    }
}

/// Fade in, drift up a few points, and come into focus.
private struct BandIntroReveal: ViewModifier {
    let shown: Bool
    let hiddenOpacity: Double

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : hiddenOpacity)
            .offset(y: shown ? 0 : 12)
            .blur(radius: shown ? 0 : 10)
    }

    static func transition(for element: BandIntroRevealElement, animated: Bool) -> AnyTransition {
        guard animated else { return .identity }
        // The button starts just above zero opacity: SwiftUI does not hit-test a
        // fully transparent view, and a tap on the button as it appears should
        // count as Get started, not fall through to the skip layer.
        let hiddenOpacity = element == .button ? 0.02 : 0
        return AnyTransition
            .modifier(
                active: BandIntroReveal(shown: false, hiddenOpacity: hiddenOpacity),
                identity: BandIntroReveal(shown: true, hiddenOpacity: hiddenOpacity)
            )
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.1).delay(element.delay))
    }
}

/// `AVPlayerLayer` filling the view, aspect-fill, no controls.
private struct BandIntroPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let background: UIColor

    func makeUIView(context: Context) -> PlayerLayerHost {
        let view = PlayerLayerHost()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        view.backgroundColor = background
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerLayerHost, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.backgroundColor = background
    }

    static func dismantleUIView(_ view: PlayerLayerHost, coordinator: ()) {
        view.playerLayer.player = nil
    }

    final class PlayerLayerHost: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        // The layer class is fixed above, so the cast cannot fail.
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

#if DEBUG
/// Previews read a placeholder film from a temp directory. Generate it with
/// `scripts/band-intro-placeholder.sh` (writes to /tmp/loopr-band-intro-placeholder).
#Preview("Band intro, placeholder film") {
    BandIntroView(
        assets: BandIntroAssets(directory: URL(fileURLWithPath: "/tmp/loopr-band-intro-placeholder")),
        onGetStarted: {}
    )
}
#endif
#endif
