import DesignSystem
import SwiftUI
import UIKit

/// The look of the element a card grows out of, for everything that is not a photo or the night.
struct TodayDialFocusBadgeStyle: Equatable {
    let symbol: String
    let tint: LooprColorToken

    static func of(_ detail: TodayDialFocusDetail) -> TodayDialFocusBadgeStyle {
        switch detail {
        case .training(let training): .init(symbol: training.isPlanned ? "calendar" : "figure.run", tint: .strain)
        case .rule(let rule): .init(symbol: rule.state == .kept ? "checkmark" : "circle.dashed", tint: .protocol)
        case .bedtime: .init(symbol: "moon.fill", tint: .sleep)
        case .tonight: .init(symbol: "moon.stars.fill", tint: .sleep)
        case .alarm: .init(symbol: "alarm.fill", tint: .brand)
        case .meal: .init(symbol: "fork.knife", tint: .energy)
        case .lastNight: .init(symbol: "bed.double.fill", tint: .sleep)
        }
    }
}

/// The open card over the dial, and every transition into and out of it.
///
/// One number drives everything: `progress`, 0 with the card folded into its element on the dial and 1 open. A
/// display-link spring moves it, so opening, closing and a swipe that hands back mid-way all run through `apply(_:)`
/// and can turn round at any frame. What moves depends on the element:
/// - a meal's photo leaves the sticker, loses its white rim and grows into the card's header;
/// - last night's stage spans peel off the ring one after another and land as bars in Sleep's stage chart, which then
///   takes over so it can be scrubbed;
/// - anything else grows from its dot into the card's badge.
/// The plate grows out of the same element (for the night, out of the dial's own face), the dial sinks and softens behind
/// it on the same spring through `motion`, and the words rise last. Closing runs the same frames backwards, so the dial is
/// whole again the moment the card has folded away.
final class TodayDialFocusView: UIView, UIGestureRecognizerDelegate {
    private enum Hero: Equatable {
        case photo
        case night
        case badge(TodayDialFocusBadgeStyle)
    }

    /// The card closed and folded back into its element.
    var onDismissed: (() -> Void)?
    /// Where the dial behind reads the progress from.
    var motion: TodayDialFocusMotion?

    private(set) var focus: TodayDialFocus?
    let store: TodayDialFocusStore

    private var hero: Hero = .badge(.init(symbol: "circle", tint: .brand))
    /// The element on the dial, in this view's points.
    private var anchorRect: CGRect = .zero
    private var morph: TodayDialSleepMorph?
    private var reduceMotion = false

    // The spring.
    private var progress: Double = 0
    private var velocity: Double = 0
    private var target: Double = 0
    private var stiffness: Double = 200
    private var damping: Double = 22
    private var displayLink: CADisplayLink?
    /// When the spring last stepped, so a dropped frame catches up instead of slowing the motion down.
    private var lastStep: CFTimeInterval?
    private var isClosing = false

    // Layers and views, back to front.
    private let plate = UIView()
    private let trackLayers: [CAShapeLayer] = (0..<LooprStageTimelineModel.laneOrder.count).map { _ in CAShapeLayer() }
    private let morphLayer = CALayer()
    private var pieceLayers: [CAShapeLayer] = []
    private let photoView = UIImageView()
    private let photoSymbol = UIImageView()
    private let badgeView = UIView()
    private let badgeFill = UIView()
    private let badgeSymbol = UIImageView()
    private let contentHost: UIHostingController<TodayDialFocusCardContent>
    private let chartHost: UIHostingController<TodayDialFocusChart>
    private let closeButton = UIButton(type: .system)
    private let closeBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))

    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

    override init(frame: CGRect) {
        let store = TodayDialFocusStore(layout: TodayDialFocusLayout(side: max(frame.width, 1), laneHeight: 24))
        self.store = store
        contentHost = UIHostingController(rootView: TodayDialFocusCardContent(store: store))
        chartHost = UIHostingController(rootView: TodayDialFocusChart(store: store))
        super.init(frame: frame)
        isHidden = true
        backgroundColor = .clear
        clipsToBounds = false

        plate.layer.cornerCurve = .continuous
        plate.layer.shadowOffset = CGSize(width: 0, height: 8)
        plate.layer.shadowRadius = 22
        plate.layer.borderWidth = 0.75
        addSubview(plate)

        for track in trackLayers { layer.addSublayer(track) }
        layer.addSublayer(morphLayer)

        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        photoView.layer.cornerCurve = .continuous
        photoView.layer.borderColor = UIColor.white.cgColor
        photoSymbol.contentMode = .scaleAspectFit
        photoView.addSubview(photoSymbol)
        addSubview(photoView)

        badgeView.clipsToBounds = true
        badgeFill.isUserInteractionEnabled = false
        badgeSymbol.contentMode = .scaleAspectFit
        badgeView.addSubview(badgeFill)
        badgeView.addSubview(badgeSymbol)
        addSubview(badgeView)

        for host in [contentHost, chartHost] as [UIViewController] {
            host.view.backgroundColor = .clear
            host.view.clipsToBounds = false
        }
        contentHost.safeAreaRegions = []
        chartHost.safeAreaRegions = []
        addSubview(chartHost.view)
        addSubview(contentHost.view)

        closeBlur.clipsToBounds = true
        closeBlur.isUserInteractionEnabled = false
        closeButton.addSubview(closeBlur)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)),
                             for: .normal)
        closeButton.accessibilityLabel = "Close"
        closeButton.accessibilityIdentifier = "today-dial-focus-close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        pan.delegate = self
        tap.delegate = self
        tap.cancelsTouchesInView = false
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                                 UITraitPreferredContentSizeCategory.self]) { (view: TodayDialFocusView, _: UITraitCollection) in
            view.refreshColors()
            view.relayout()
        }
        accessibilityIdentifier = "today-dial-focus"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        displayLink?.invalidate()
    }

    // MARK: Presenting

    var isPresented: Bool { focus != nil }

    /// Opens `detail` out of the element at `anchor` (view-box points).
    func present(_ focus: TodayDialFocus, detail: TodayDialFocusDetail, anchor: TodayDialFocusAnchor, spans: [TodayDialStageSpan],
                 photo: UIImage?, actions: TodayDialActions, reduceMotion: Bool) {
        teardownMotion()
        self.focus = focus
        self.reduceMotion = reduceMotion
        isClosing = false
        store.actions = actions
        store.selection = nil
        store.highlightedStage = nil
        store.ticking = false
        store.detail = detail
        let scale = bounds.width / TodayDialGeometry.viewBox
        let radius = max(anchor.radius * scale, 4)
        anchorRect = CGRect(x: anchor.center.x * scale - radius, y: anchor.center.y * scale - radius, width: radius * 2, height: radius * 2)

        switch detail {
        case .meal: hero = .photo
        case .lastNight: hero = .night
        default: hero = .badge(.of(detail))
        }
        relayout()
        configureHero(detail: detail, spans: spans, photo: photo)
        refreshColors()
        attachHosts()

        isHidden = false
        accessibilityViewIsModal = true
        progress = 0
        velocity = 0
        apply(0)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
        if reduceMotion {
            progress = 1
            apply(1)
            alpha = 0
            UIView.animate(withDuration: 0.22) { self.alpha = 1 } completion: { _ in self.announce() }
            driveDial(to: 1, .easeInOut(duration: 0.22))
        } else {
            alpha = 1
            // The night's peel gets a longer response so each span can be seen leaving the ring; neither spring
            // overshoots far enough for the card to spill past the dial.
            if hero == .night { animate(to: 1, Spring.nightOpen) } else { animate(to: 1, Spring.open) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.announce() }
        }
    }

    /// New words for the open card, as when the meal it shows was edited.
    func update(detail: TodayDialFocusDetail, photo: UIImage?, actions: TodayDialActions) {
        store.actions = actions
        if store.detail != detail { store.detail = detail }
        if hero == .photo, let photo, photoView.image !== photo { setPhoto(photo) }
    }

    /// Folds the card back into its element. Without animation it just goes.
    func dismiss(animated: Bool = true) {
        guard isPresented, !isClosing else { return }
        isClosing = true
        if !animated {
            finishDismiss()
        } else if reduceMotion {
            UIView.animate(withDuration: 0.2) { self.alpha = 0 } completion: { _ in self.finishDismiss() }
            driveDial(to: 0, .easeInOut(duration: 0.2))
        } else {
            animate(to: 0, hero == .night ? Spring.nightClose : Spring.close)
        }
    }

    private func finishDismiss() {
        teardownMotion()
        progress = 0
        apply(0)
        // A close without animation still has to bring the dial forward.
        driveDial(to: 0, nil)
        accessibilityViewIsModal = false
        focus = nil
        isClosing = false
        // The dial draws what the card carried again in SwiftUI's next commit. The pieces sit exactly over those
        // strokes, so they stay one more turn of the run loop: the two overlap for a frame instead of leaving a gap.
        onDismissed?()
        DispatchQueue.main.async { [weak self] in
            guard let self, !isPresented else { return }
            isHidden = true
            alpha = 1
            store.detail = nil
            pieceLayers.forEach { $0.removeFromSuperlayer() }
            pieceLayers = []
            morph = nil
        }
    }

    private func announce() {
        guard isPresented else { return }
        UIAccessibility.post(notification: .screenChanged, argument: contentHost.view)
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    private var laneHeight: CGFloat {
        UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 24, compatibleWith: traitCollection)
    }

    private var labelWidth: CGFloat {
        min(UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 46, compatibleWith: traitCollection), 62)
    }

    private func relayout() {
        let layout = TodayDialFocusLayout(side: bounds.width, laneHeight: laneHeight)
        if store.layout != layout { store.layout = layout }
        // The words and the close button carry a transform while they rise, so they are placed by bounds and centre:
        // a frame is undefined under a transform.
        place(contentHost.view, in: layout.card)
        chartHost.view.frame = layout.chart
        place(closeButton, in: layout.close)
        closeBlur.frame = closeButton.bounds.insetBy(dx: 7, dy: 7)
        closeBlur.layer.cornerRadius = closeBlur.bounds.width / 2
        if let image = closeButton.imageView { closeButton.bringSubviewToFront(image) }
        for (index, track) in trackLayers.enumerated() {
            let chart = chartLayout(layout)
            let rect = chart?.track(index) ?? .zero
            track.path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).cgPath
        }
        if isPresented { apply(progress) }
    }

    private func place(_ view: UIView, in rect: CGRect) {
        view.bounds = CGRect(origin: .zero, size: rect.size)
        view.center = CGPoint(x: rect.midX, y: rect.midY)
    }

    private func chartLayout(_ layout: TodayDialFocusLayout) -> TodayDialStageChartLayout? {
        guard case .lastNight(let night) = store.detail, let start = night.spans.map(\.start).min(),
              let end = night.spans.map(\.end).max() else { return nil }
        return TodayDialStageChartLayout(frame: layout.chart, laneHeight: laneHeight, labelWidth: labelWidth, start: start, end: end)
    }

    private func configureHero(detail: TodayDialFocusDetail, spans: [TodayDialStageSpan], photo: UIImage?) {
        photoView.isHidden = hero != .photo
        badgeView.isHidden = true
        morphLayer.isHidden = hero != .night
        chartHost.view.isHidden = hero != .night
        trackLayers.forEach { $0.isHidden = hero != .night }
        pieceLayers.forEach { $0.removeFromSuperlayer() }
        pieceLayers = []
        morph = nil

        switch hero {
        case .photo:
            setPhoto(photo)
        case .night:
            if let chart = chartLayout(store.layout) {
                let morph = TodayDialSleepMorph(spans: spans, side: bounds.width, chart: chart)
                self.morph = morph
                pieceLayers = morph.pieces.map { piece in
                    let shape = CAShapeLayer()
                    shape.fillColor = color(piece.stage.token).cgColor
                    shape.actions = ["path": NSNull(), "opacity": NSNull()]
                    morphLayer.addSublayer(shape)
                    return shape
                }
            }
        case .badge(let style):
            badgeView.isHidden = false
            badgeSymbol.image = UIImage(systemName: style.symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        }
    }

    private func setPhoto(_ photo: UIImage?) {
        photoView.image = photo
        photoSymbol.isHidden = photo != nil
        photoSymbol.image = UIImage(systemName: "fork.knife", withConfiguration: UIImage.SymbolConfiguration(weight: .medium))
    }

    /// Hosts the SwiftUI parts as children of the nearest view controller, so they get its environment and lifecycle.
    private func attachHosts() {
        guard let parent = nearestViewController else { return }
        for host in [contentHost, chartHost] as [UIViewController] where host.parent !== parent {
            host.willMove(toParent: nil)
            host.removeFromParent()
            parent.addChild(host)
            host.didMove(toParent: parent)
        }
    }

    private var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }

    private func color(_ token: LooprColorToken) -> UIColor {
        UIColor(Color.loopr(token)).resolvedColor(with: traitCollection)
    }

    private func refreshColors() {
        plate.backgroundColor = color(.surface)
        plate.layer.borderColor = color(.surfaceStroke).cgColor
        plate.layer.shadowColor = UIColor.black.cgColor
        plate.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.45 : 0.14
        photoView.backgroundColor = color(.energy).withAlphaComponent(0.16)
        photoSymbol.tintColor = color(.energy)
        closeButton.tintColor = color(.ink)
        trackLayers.forEach { $0.fillColor = color(.ink).withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.05 : 0.045).cgColor }
        if case .badge(let style) = hero {
            badgeView.backgroundColor = color(style.tint).withAlphaComponent(0.16)
            badgeFill.backgroundColor = color(style.tint)
            badgeSymbol.tintColor = color(style.tint)
        }
        if let morph {
            for (piece, shape) in zip(morph.pieces, pieceLayers) { shape.fillColor = color(piece.stage.token).cgColor }
        }
    }

    // MARK: The frame

    /// Places everything for one value of the shared progress. Above 1 the spring overshoots: frames follow a little,
    /// fades and the peel stop at 1.
    private func apply(_ value: Double) {
        let p = CGFloat(min(max(value, -0.02), 1.03))
        let q = CGFloat(min(max(value, 0), 1))
        let layout = store.layout
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // The plate leaves the element as the element's own shape and opens into the card. The night's element is the
        // whole dial, so its plate starts as the dial face and squares off into the card.
        let plateFrom: CGRect = switch hero {
        case .photo: anchorRect
        case .badge: anchorRect.insetBy(dx: -4, dy: -4)
        case .night: faceRect
        }
        plate.frame = lerp(plateFrom, layout.card, p)
        // Round for most of the way, whatever size it has reached, and only squaring off as it lands.
        plate.layer.cornerRadius = lerp(min(plate.bounds.width, plate.bounds.height) / 2, layout.cornerRadius, smooth(0.3, 1, q))
        plate.layer.shadowPath = UIBezierPath(roundedRect: plate.bounds, cornerRadius: plate.layer.cornerRadius).cgPath
        plate.alpha = hero == .night ? smooth(0, 0.4, q) : smooth(0, 0.16, q)

        switch hero {
        case .photo:
            let frame = lerp(anchorRect, layout.photo, p)
            photoView.frame = frame
            photoView.layer.cornerRadius = lerp(min(frame.width, frame.height) / 2, LooprRadius.card - 6, smooth(0.3, 1, q))
            // The sticker's white rim: 2.5 of its 16.5 view-box points.
            photoView.layer.borderWidth = anchorRect.width * 2.5 / 33 * (1 - smooth(0, 0.5, q))
            let symbol = min(frame.width, frame.height) * 0.42
            photoSymbol.frame = CGRect(x: (frame.width - symbol) / 2, y: (frame.height - symbol) / 2, width: symbol, height: symbol)
        case .night:
            if let morph {
                for (piece, shape) in zip(morph.pieces, pieceLayers) {
                    let outline = TodayDialSleepMorph.outline(piece, progress: Double(q))
                    let path = CGMutablePath()
                    path.addLines(between: outline)
                    path.closeSubpath()
                    shape.path = path
                }
            }
            // The real chart takes over once the bars have landed; a swipe back hands over to the peel again.
            let handover = smooth(0.9, 1, q)
            morphLayer.opacity = Float(1 - handover)
            chartHost.view.alpha = handover
            trackLayers.forEach { $0.opacity = Float(smooth(0.45, 0.9, q) * (1 - handover)) }
        case .badge:
            let frame = lerp(anchorRect, layout.badge, p)
            badgeView.frame = frame
            badgeView.layer.cornerRadius = frame.width / 2
            badgeFill.frame = badgeView.bounds
            badgeFill.alpha = 1 - smooth(0.2, 0.7, q)
            let symbol = frame.width * 0.46
            badgeSymbol.frame = CGRect(x: (frame.width - symbol) / 2, y: (frame.height - symbol) / 2, width: symbol, height: symbol)
            badgeSymbol.alpha = smooth(0.35, 0.85, q)
        }

        let words = smooth(0.45, 0.95, q)
        contentHost.view.alpha = words
        contentHost.view.transform = CGAffineTransform(translationX: 0, y: (1 - words) * 10)
        closeButton.alpha = smooth(0.55, 1, q)
        closeButton.transform = CGAffineTransform(scaleX: 0.6 + 0.4 * words, y: 0.6 + 0.4 * words)
        CATransaction.commit()
    }

    /// The dial face, in this view's points: where the night's plate starts.
    private var faceRect: CGRect {
        let radius = TodayDialGeometry.faceRadius * bounds.width / TodayDialGeometry.viewBox
        return CGRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
    }

    // MARK: The spring

    /// A spring by its response (seconds for one swing) and damping ratio, as SwiftUI and Core Animation name them.
    struct Spring {
        let response: Double
        let dampingRatio: Double

        var stiffness: Double { pow(2 * .pi / response, 2) }

        static let open = Spring(response: 0.5, dampingRatio: 0.84)
        static let nightOpen = Spring(response: 0.64, dampingRatio: 0.9)
        static let close = Spring(response: 0.4, dampingRatio: 1)
        static let nightClose = Spring(response: 0.5, dampingRatio: 1)
        static let settle = Spring(response: 0.42, dampingRatio: 0.84)
    }

    private func animate(to target: Double, _ spring: Spring, velocity: Double? = nil) {
        self.target = target
        stiffness = spring.stiffness
        damping = 2 * spring.dampingRatio * stiffness.squareRoot()
        if let velocity { self.velocity = velocity }
        // SwiftUI runs the dial's half of the motion on the same spring. Its initial velocity is a share of the distance
        // left per second; only a finger hands one over, since a spring already running keeps its own momentum.
        let distance = target - progress
        let handed = velocity.map { abs(distance) > 0.001 ? $0 / distance : 0 } ?? 0
        driveDial(to: target, .interpolatingSpring(stiffness: stiffness, damping: damping, initialVelocity: handed))
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        // Real time since the last step, capped so a long stall does not jump the card to its end in one frame.
        let dt = min(max(now - (lastStep ?? (now - (link.targetTimestamp - link.timestamp))), 1.0 / 240), 1.0 / 15)
        lastStep = now
        // Semi-implicit Euler in steps of at most 2 ms keeps the spring stable at any frame rate.
        let substeps = max(Int((dt / 0.002).rounded(.up)), 1)
        let h = dt / Double(substeps)
        for _ in 0..<substeps {
            let acceleration = -stiffness * (progress - target) - damping * velocity
            velocity += acceleration * h
            progress += velocity * h
        }
        if abs(progress - target) < 0.0015, abs(velocity) < 0.02 {
            progress = target
            apply(progress)
            stopLink()
            if target == 0, isClosing { finishDismiss() }
            return
        }
        apply(progress)
    }

    /// Moves the dial behind the card. The dial is SwiftUI, and SwiftUI does not promise to draw a value written from a
    /// display link on the frame it was written, so the dial never follows the UIKit spring frame by frame: it gets the
    /// same spring as its own animation, which the render server runs in step. Only a finger writes it directly. Every
    /// write goes through the main queue, so none lands inside a SwiftUI update and they arrive in order.
    private func driveDial(to value: Double, _ animation: Animation?) {
        DispatchQueue.main.async { [weak self] in
            guard let motion = self?.motion else { return }
            var transaction = Transaction(animation: animation)
            transaction.disablesAnimations = animation == nil
            withTransaction(transaction) { motion.progress = value }
        }
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastStep = nil
    }

    private func teardownMotion() {
        stopLink()
    }

    // MARK: Gestures

    @objc private func closeTapped() {
        dismiss()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard isPresented, !plate.frame.contains(recognizer.location(in: self)) else { return }
        dismiss()
    }

    /// Dragging down scrubs the card back towards its element; letting go far enough, or fast enough, closes it.
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard isPresented, !reduceMotion else { return }
        let distance = max(bounds.height * 0.85, 1)
        let translation = recognizer.translation(in: self).y
        switch recognizer.state {
        case .began:
            stopLink()
            isClosing = false
        case .changed:
            // Upwards it resists, a few points at most.
            let raw = 1 - Double(translation / distance)
            progress = raw > 1 ? 1 + (raw - 1) * 0.15 : max(raw, 0)
            apply(progress)
            driveDial(to: min(progress, 1), nil)
        case .ended, .cancelled, .failed:
            let speed = -Double(recognizer.velocity(in: self).y / distance)
            if progress < 0.72 || speed < -1.4 {
                isClosing = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                animate(to: 0, hero == .night ? Spring.nightClose : Spring.close, velocity: speed)
            } else {
                animate(to: 1, Spring.settle, velocity: speed)
            }
        default:
            break
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isPresented, !isHidden else { return nil }
        return super.hitTest(point, with: event) ?? self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === tap { return !plate.frame.contains(touch.location(in: self)) }
        return true
    }

    /// UIView's own hook and the delegate's share this selector, so one override serves both.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = pan.velocity(in: self)
        guard velocity.y > 0, velocity.y > abs(velocity.x) * 1.2 else { return false }
        // Inside long card words, a downward drag first scrolls them back to the top.
        let location = pan.location(in: self)
        if let scroll = scrollView(at: location), scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1 { return false }
        return true
    }

    /// The page and the card's own scroll view wait for the swipe-down to fail before they scroll.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan && otherGestureRecognizer.view is UIScrollView
    }

    private func scrollView(at point: CGPoint) -> UIScrollView? {
        var view = contentHost.view.hitTest(convert(point, to: contentHost.view), with: nil)
        while let current = view, current !== contentHost.view {
            if let scroll = current as? UIScrollView { return scroll }
            view = current.superview
        }
        return nil
    }
}

// MARK: - Interpolation

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: max(lerp(a.width, b.width, t), 0),
           height: max(lerp(a.height, b.height, t), 0))
}

/// 0 below `edge0`, 1 above `edge1`, smooth between.
private func smooth(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
