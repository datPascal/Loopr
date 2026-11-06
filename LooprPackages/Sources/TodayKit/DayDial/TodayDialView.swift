import DesignSystem
import SwiftUI
import UIKit

/// What the app hands Today for the dial: the inputs it read from the stores, whether the clock is pinned, and the
/// meal photos already cut into stickers.
public struct TodayDialContent {
    public var inputs: TodayDialInputs
    /// Fixture launches pin the clock so captures and UI tests never drift; the hand then stays at `inputs.now`.
    public var isClockPinned: Bool
    /// Sticker images by Food photo id.
    public var stickers: [UUID: Image]
    /// The same photos uncut, for the header a tapped sticker grows into. A meal without one keeps a drawn plate.
    public var photos: [UUID: UIImage]

    public init(inputs: TodayDialInputs, isClockPinned: Bool = false, stickers: [UUID: Image] = [:], photos: [UUID: UIImage] = [:]) {
        self.inputs = inputs
        self.isClockPinned = isClockPinned
        self.stickers = stickers
        self.photos = photos
    }

    /// The model at `date`, with Today's recovery hero in the readouts.
    public func model(at date: Date, recovery: TodayHeroState?) -> TodayDialModel? {
        var inputs = inputs
        if !isClockPinned { inputs.now = date }
        inputs.recovery = recovery
        return TodayDialModel(inputs)
    }
}

public extension EnvironmentValues {
    /// Where the dial remembers which meals and workouts it has shown. Tests put their own here.
    @Entry var todayDialArrivalStore: TodayDialArrivalStore = .shared
}

/// Today's hero: the dial, the sentence for what is missing, and the three readouts under it. The model is rebuilt
/// once a minute, so the hand, the countdown and the 18:00 switch follow the clock.
struct TodayDialSection: View {
    let content: TodayDialContent
    let recovery: TodayHeroState?
    let openRecovery: () -> Void

    var body: some View {
        TimelineView(.periodic(from: Self.minuteStart(), by: 60)) { context in
            if let model = content.model(at: context.date, recovery: recovery) {
                TodayDialStack(model: model, stickers: content.stickers, photos: content.photos, recovery: recovery,
                               openRecovery: openRecovery)
            }
        }
    }

    nonisolated static func minuteStart(_ date: Date = Date()) -> Date {
        Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
    }
}

struct TodayDialStack: View {
    let model: TodayDialModel
    let stickers: [UUID: Image]
    var photos: [UUID: UIImage] = [:]
    let recovery: TodayHeroState?
    let openRecovery: () -> Void

    @Environment(\.looprDotFlight) private var flight
    @Environment(\.todayDialArrivalStore) private var arrivalStore
    @Environment(\.looprEntranceStore) private var entranceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.todayDialActions) private var actions
    @State private var entrance = false
    @State private var elapsed = TodayDialDrawing.entranceDuration
    @State private var countStep = TodayDialStack.countSteps
    @State private var side: CGFloat = 0
    @State private var scrubMinute: Int?
    @State private var focusedHour: Int?
    /// The element whose card is open over the dial (or still folding back into it).
    @State private var focus: TodayDialFocus?
    /// The card's spring, which the dial follows as it steps back.
    @State private var focusMotion = TodayDialFocusMotion()

    /// The hero number counts up in this many steps during the entrance.
    static let countSteps = 12
    /// The dial never grows past the contract's 353 points.
    static let maximumSide: CGFloat = 353

    var body: some View {
        VStack(spacing: LooprSpacing.md) {
            dial
            TodayDialNotes(lines: TodayDialNotes.lines(for: model))
            TodayDialReadoutsView(readouts: model.readouts, recovery: recovery, openRecovery: openRecovery)
            if model.mode == .evening {
                TodayDialRecoveryRow(readout: model.recovery, recovery: recovery, open: openRecovery)
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        // Large text gives the notes and readouts ideal widths past the screen. Without this they would widen the
        // whole vertical scroll view, as the old recovery hero once did (91903334).
        .containerRelativeFrame(.horizontal)
    }

    private var dial: some View {
        let drawing = TodayDialDrawing(model)
        return ZStack {
            TodayDialCanvas(drawing: drawing, stickerImages: stickers, elapsed: elapsed, scrubMinute: scrubMinute,
                            hidden: focus.map { TodayDialHitTest.carriedIDs(for: $0, in: model) } ?? [])
                .accessibilityElement()
                .accessibilityLabel(model.accessibilitySummary)
                .accessibilityValue(TodayDialScrub.reading(model, minuteOfDay: hourInFocus * 60, locale: locale).spoken)
                .accessibilityHint("Swipe up or down to step through the hours.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: focusedHour = (hourInFocus + 1) % 24
                    case .decrement: focusedHour = (hourInFocus + 23) % 24
                    @unknown default: break
                    }
                }
                .accessibilityActions {
                    ForEach(TodayDialFocusTargets.all(model), id: \.self) { target in
                        Button(target.label) { focus = target.focus }
                    }
                }
                .accessibilityHidden(focus != nil)
                .accessibilityIdentifier("today-dial")
            TodayDialCentreView(model: model, scrub: scrubMinute.map { TodayDialScrub.reading(model, minuteOfDay: $0, locale: locale) },
                                countUp: countUp)
                .frame(width: max(side * TodayDialGeometry.innerRingRadius * 2 / TodayDialGeometry.viewBox - 8, 0))
                .accessibilityIdentifier("today-dial-centre")
        }
        .modifier(TodayDialRecede(motion: focusMotion))
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: Self.maximumSide)
        // Measured and scrubbed on the dial's own square, so a touch maps straight onto the view box.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { side = $0 }
        // A tap opens what is under it in the dial's own square: the card grows out of the element, Today stays.
        .simultaneousGesture(SpatialTapGesture().onEnded { value in open(at: value.location) }, isEnabled: focus == nil)
        // Hold, then move around the rim: the dial reads the hour under the finger. A drag without the hold scrolls
        // the page, through the shared UIKit long press that hands over to the scroll view.
        .looprScrubPoint { point in
            scrubMinute = point.flatMap { TodayDialScrub.minuteOfDay(at: $0, side: side) }
        }
        .looprDotFlightTarget("today-dial")
        .looprPressTilt(isEnabled: focus == nil)
        // Over the scrub and the tilt, not inside them, so a finger on the open card never scrubs or tilts the dial.
        .overlay {
            TodayDialFocusOverlay(focus: focus, model: model, photos: photos, actions: actions,
                                  reduceMotion: LooprMotion.reducesMotion(reduceMotion), locale: locale,
                                  motion: focusMotion) { focus = nil }
                .allowsHitTesting(focus != nil)
                .accessibilityHidden(focus == nil)
        }
        .frame(maxWidth: .infinity)
        .looprDetentFeedback(scrubMinute.map(TodayDialScrub.hour), isActive: scrubMinute != nil)
        .looprEntrance(tab: LooprColorFieldTab.today.rawValue, animates: $entrance, duration: TodayDialDrawing.entranceDuration)
        .onChange(of: entrance, initial: true) { _, animates in
            guard animates else { return }
            playEntrance()
        }
        .task(id: TodayDialArrivals.ids(model).sorted().joined(separator: ",")) {
            await flyArrivals()
        }
    }

    private func open(at location: CGPoint) {
        guard focus == nil, scrubMinute == nil, side > 0 else { return }
        let scale = TodayDialGeometry.viewBox / side
        let point = TodayDialPoint(x: location.x * scale, y: location.y * scale)
        guard let target = TodayDialHitTest.focus(at: point, side: side, model: model),
              TodayDialFocusDetail.make(target, model: model, locale: locale) != nil else { return }
        focus = target
    }

    private var hourInFocus: Int {
        focusedHour ?? model.hand.map { TodayDialScrub.hour(model.clock.minuteOfDay($0.date)) } ?? 12
    }

    /// The hero number's count during the entrance. Nil once it has landed.
    private var countUp: LooprCountUp? {
        guard countStep < Self.countSteps, case .asleep(let asleep) = model.centre else { return nil }
        return LooprCountUp(from: 0, to: asleep.minutes, total: Self.countSteps, landed: countStep)
    }

    private func playEntrance() {
        guard !LooprMotion.reducesMotion(reduceMotion) else { return }
        elapsed = 0
        countStep = 0
        withAnimation(.linear(duration: TodayDialDrawing.entranceDuration)) { elapsed = TodayDialDrawing.entranceDuration }
        Task { @MainActor in
            for step in 1...Self.countSteps {
                try? await Task.sleep(for: .milliseconds(90))
                countStep = step
            }
        }
    }

    /// Flies dots from each meal or workout that arrived since the dial last showed this day, once.
    private func flyArrivals() async {
        let day = model.clock.day
        let key = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        let arrivals = TodayDialArrivals.plan(model, seen: arrivalStore.seen(day: key))
        if model.isToday { arrivalStore.record(TodayDialArrivals.ids(model), day: key) }
        guard !arrivals.isEmpty, !entranceStore.forcesFinalState else { return }
        // Let the anchors land on screen first.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, let flight, let frame = flight.targets["today-dial"] else { return }
        var random = SystemRandomNumberGenerator()
        var landings: [LooprDotLanding] = []
        var away = CGPoint(x: frame.midX, y: frame.midY)
        for arrival in arrivals {
            let request = TodayDialFlightPlan.request(arrival, in: frame, using: &random)
            landings += request.landings
            away = request.away
        }
        flight.play(LooprDotFlightRequest(landings: landings, away: away))
    }
}

/// The flight for one arrival, in the host's coordinates.
enum TodayDialFlightPlan {
    static func point(radius: Double, angle: Double, in frame: CGRect) -> CGPoint {
        let scale = frame.width / TodayDialGeometry.viewBox
        let point = TodayDialGeometry.point(radius: radius, angle: angle)
        return CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    static func request<G: RandomNumberGenerator>(_ arrival: TodayDialArrival, in frame: CGRect,
                                                  using random: inout G) -> LooprDotFlightRequest {
        let scale = frame.width / TodayDialGeometry.viewBox
        let source = point(radius: arrival.sourceRadius, angle: arrival.sourceAngle, in: frame)
        let reach = (arrival.kind == .meal ? TodayDialGeometry.stickerRadius : TodayDialGeometry.trainingWidth) * scale
        let target = LooprDotTarget.ring(center: CGPoint(x: frame.midX, y: frame.midY), radius: arrival.targetRadius * scale,
                                         from: arrival.targetStartAngle / 360, to: (arrival.targetStartAngle + arrival.targetSweep) / 360)
        let colors = Array(repeating: UIColor(Color.loopr(arrival.tint)), count: TodayDialArrival.dotCount)
        return LooprDotFlight.request(from: CGRect(x: source.x - reach, y: source.y - reach, width: reach * 2, height: reach * 2),
                                      to: target, colors: colors, using: &random)
    }
}

// MARK: - Centre

struct TodayDialCentreView: View {
    nonisolated static let maximumTextSize = DynamicTypeSize.xxLarge

    let model: TodayDialModel
    let scrub: TodayDialScrubReading?
    let countUp: LooprCountUp?

    var body: some View {
        Group {
            if let scrub {
                VStack(spacing: 2) {
                    Text(scrub.time).looprTypography(.metricCompact).foregroundStyle(Color.loopr(.ink)).monospacedDigit()
                    ForEach(Array(scrub.lines.prefix(3).enumerated()), id: \.offset) { _, line in
                        Text(line).looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                switch model.centre {
                case .asleep(let asleep):
                    VStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            LooprHeroNumber(Double(shownMinutes(asleep) / 60), unit: "h", spokenUnit: "hours", style: .heroNumeralLarge)
                            LooprHeroNumber(Double(shownMinutes(asleep) % 60), unit: "m", spokenUnit: "minutes", style: .heroNumeralLarge)
                        }
                        Text(asleep.caption).looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenAsleep(asleep))
                case .countdown(let countdown):
                    VStack(spacing: 6) {
                        Text(countdown.text)
                            .looprTypography(.heroNumeralLarge)
                            .foregroundStyle(Color.loopr(.ink))
                            .contentTransition(.numericText())
                        Text(countdown.caption).looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(LooprUnitFormatter.spokenDuration(minutes: countdown.remaining / 60) ?? countdown.text) \(countdown.caption)")
                case .absent(let absence):
                    Text(absence.message)
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .accessibilityLabel(absence.message)
                }
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .minimumScaleFactor(0.6)
        // The centre is a fixed circle in the drawing. Its words stop growing here so they never spill over the rings;
        // VoiceOver reads them whole, and the notes and readouts under the dial take every size.
        .dynamicTypeSize(...TodayDialCentreView.maximumTextSize)
        .allowsHitTesting(false)
    }

    /// The minutes the count has reached during the entrance, or the night's own.
    private func shownMinutes(_ asleep: TodayDialAsleepCentre) -> Int {
        Int((countUp?.value ?? asleep.minutes).rounded())
    }

    private func spokenAsleep(_ asleep: TodayDialAsleepCentre) -> String {
        var line = "\(LooprUnitFormatter.spokenDuration(minutes: asleep.minutes) ?? asleep.text) asleep last night"
        if let nights = asleep.onTimeNights, nights > 0 { line += ", \(TodayDialReadoutRules.onTimeStreak(nights))" }
        return line
    }
}

// MARK: - Evening recovery

/// Recovery in the evening: one compact row under the readouts, so "What shaped it" stays one tap away after 18:00.
struct TodayDialRecoveryRow: View {
    let readout: TodayDialReadout
    let recovery: TodayHeroState?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TodayDialRecoveryRow.summary(readout)).looprTypography(.label).foregroundStyle(Color.loopr(.ink))
                    Text("What shaped it").looprTypography(.caption).foregroundStyle(Color.loopr(LooprColorToken.brand.textInk))
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .looprCardBackground(density: .compact)
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TodayDialReadoutCell.recoveryLabel(readout: readout, hero: recovery))
        .accessibilityHint("Opens what shaped your recovery.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("today-metric-recovery")
    }

    /// "Recovery 78 · ready", or "Recovery · no score" when there is none.
    nonisolated static func summary(_ readout: TodayDialReadout) -> String {
        guard let text = readout.text else { return readout.caption.map { "\(readout.title) · \($0)" } ?? readout.title }
        return readout.caption.map { "\(readout.title) \(text) · \($0)" } ?? "\(readout.title) \(text)"
    }
}

// MARK: - Notes

/// The sentence under the dial for what is missing and how it fills in.
struct TodayDialNotes: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .center, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("today-dial-notes")
        }
    }

    /// The empty or learning sentence, then each absent layer's own. The sleep line is left out when the centre
    /// already says it.
    nonisolated static func lines(for model: TodayDialModel) -> [String] {
        var lines: [String] = model.render.message.map { [$0] } ?? []
        guard model.render.kind != .empty else {
            // A past day with nothing on it is not a first day: say the night is missing and how it fills in.
            if !model.isToday, let sleep = model.sleep.absence { return [sleep.message] }
            return lines
        }
        var centreSaysSleep = false
        if case .absent = model.centre { centreSaysSleep = true }
        // On a past day the centre only names the gap; the line under the dial says how it fills in.
        if !centreSaysSleep || !model.isToday, let sleep = model.sleep.absence { lines.append(sleep.message) }
        for absence in [model.eating.absence, model.training.absence, model.daylight.absence].compactMap({ $0 }) {
            lines.append(absence.message)
        }
        return lines
    }
}

// MARK: - Readouts

struct TodayDialReadoutsView: View {
    let readouts: [TodayDialReadout]
    let recovery: TodayHeroState?
    let openRecovery: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the three stack so nothing clips.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .top, spacing: LooprSpacing.xs))
        layout {
            ForEach(readouts) { readout in
                TodayDialReadoutCell(readout: readout, recovery: recovery, openRecovery: openRecovery)
            }
        }
        // Side by side, the row takes its tallest cell's height and every cell fills it, so the three cards line up
        // when one title wraps (R1-OPT-19).
        .fixedSize(horizontal: false, vertical: !dynamicTypeSize.isAccessibilitySize)
        .frame(maxWidth: .infinity)
    }
}

struct TodayDialReadoutCell: View {
    let readout: TodayDialReadout
    let recovery: TodayHeroState?
    let openRecovery: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            if readout.id == .recovery {
                Button(action: openRecovery) { cell }
                    .buttonStyle(.looprPressableCard)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(TodayDialReadoutCell.recoveryLabel(readout: readout, hero: recovery))
                    .accessibilityHint("Opens what shaped your recovery.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("today-metric-recovery")
            } else {
                cell
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(TodayDialReadoutCell.spokenLabel(readout))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-readout-\(readout.id.rawValue)")
    }

    private var cell: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center, spacing: 4) {
            Text(readout.title).looprTypography(.label).foregroundStyle(Color.loopr(.inkSecondary))
            if let text = readout.text {
                let parts = Self.clockParts(text)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(parts.time)
                        .looprTypography(.metricCompact)
                        .foregroundStyle(Color.loopr(numberTint))
                        .contentTransition(.numericText())
                    // "12:30 PM" in a cell a third of the screen wide broke as "12:30 P" over "M". The day period is
                    // set small beside the time instead (ICP R2-UPG-14).
                    if let period = parts.period {
                        Text(period)
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                if let caption = readout.caption {
                    Text(caption).looprTypography(.caption).foregroundStyle(Color.loopr(captionTint))
                }
            } else {
                // No number: the reason sits where the number would be.
                Text(readout.caption ?? LooprHeroNumberAbsent.defaultText)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .padding(.vertical, 6)
            }
            // The band is the default source and the header already says when it synced, so a "Band" chip on every tile
            // was noise (UX R1-DES-07). A tile names its source only when it is something else. VoiceOver keeps the full
            // source and qualifier either way.
            if !readout.provenance.isBand {
                ProvenanceChip(readout.provenance, qualifier: readout.qualifier, style: .compact,
                               identifier: "today-readout-\(readout.id.rawValue)-source")
            }
            if readout.opensWhatShapedIt {
                HStack(spacing: 4) {
                    Text("What shaped it").looprTypography(.label).foregroundStyle(Color.loopr(LooprColorToken.brand.textInk))
                    LooprChevron()
                }
            }
        }
        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, LooprSpacing.sm)
        .padding(.horizontal, LooprSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight,
               maxHeight: dynamicTypeSize.isAccessibilitySize ? nil : .infinity,
               alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .top)
        .looprCardBackground(density: .compact)
        .contentShape(Rectangle())
    }

    private var numberTint: LooprColorToken {
        if case .recovery(let band) = readout.tone { return band.token }
        return .ink
    }

    private var captionTint: LooprColorToken {
        switch readout.tone {
        case .good: .recoveryHigh
        case .neutral, .recovery: .inkSecondary
        }
    }

    /// A readout's text split into its number and a 12-hour day period: "12:30 PM" is "12:30" and "PM", "18:20" and
    /// "9,812" have no period. Whatever is not the leading digits counts as the period, so "a.m." and "nachm." work too.
    nonisolated static func clockParts(_ text: String) -> (time: String, period: String?) {
        guard text.contains(":"), let first = text.firstIndex(where: \.isNumber) else { return (text, nil) }
        let digits = text[first...].prefix { $0.isNumber || $0 == ":" }
        let rest = (String(text[..<first]) + String(text[digits.endIndex...]))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{202F}\u{00A0}")))
        return rest.isEmpty ? (String(digits), nil) : (String(digits), rest)
    }

    /// "Sleep heart rate, 49, 4 under usual, from the band, last night."
    nonisolated static func spokenLabel(_ readout: TodayDialReadout) -> String {
        var parts = [readout.title]
        if let text = readout.text { parts.append(text) }
        if let caption = readout.caption { parts.append(caption) }
        if readout.provenance != .absent { parts.append(readout.provenance.accessibilityLabel(qualifier: readout.qualifier)) }
        return parts.joined(separator: ", ")
    }

    /// The recovery readout reads the full hero, driver and all, as the old hero did, then where it came from.
    nonisolated static func recoveryLabel(readout: TodayDialReadout, hero: TodayHeroState?) -> String {
        guard let hero else { return spokenLabel(readout) }
        return TodayRecoveryHero.spokenLabel(for: hero)
    }
}
