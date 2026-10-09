#if canImport(SwiftUI)
import DesignSystem
import Foundation
import SwiftUI

// MARK: - Screen model

/// Everything the wake alarm screen needs from the app, as plain values.
public struct WakeAlarmScreenModel: Equatable, Sendable {
    /// What is stored, or nil when no alarm was ever saved.
    public var saved: WakeAlarmPlan?
    public var band: WakeAlarmBandLayer
    public var phone: WakeAlarmPhoneLayer
    public var phoneLayerEnabled: Bool
    public var bandConnected: Bool
    public var suggestion: WakeAlarmSuggestion?

    public init(
        saved: WakeAlarmPlan?,
        band: WakeAlarmBandLayer,
        phone: WakeAlarmPhoneLayer,
        phoneLayerEnabled: Bool,
        bandConnected: Bool,
        suggestion: WakeAlarmSuggestion? = nil
    ) {
        self.saved = saved
        self.band = band
        self.phone = phone
        self.phoneLayerEnabled = phoneLayerEnabled
        self.bandConnected = bandConnected
        self.suggestion = suggestion
    }

    public var isOn: Bool { saved?.isEnabled == true }

    /// The plan the editor opens with: what is stored, else the suggestion,
    /// else 07:00 every day with a smart window.
    public var initialDraft: WakeAlarmPlan {
        if let saved { return saved }
        if let suggestion { return WakeAlarmPlan().withWakeMinute(suggestion.minuteOfDay) }
        return WakeAlarmPlan()
    }
}

/// The callbacks the screen fires. The app decides what each one does.
public struct WakeAlarmScreenActions {
    public let save: (WakeAlarmPlan) -> Void
    public let turnOff: () -> Void
    public let retryBand: () -> Void
    public let testBuzz: () -> Void
    public let setPhoneLayer: (Bool) -> Void

    public init(
        save: @escaping (WakeAlarmPlan) -> Void,
        turnOff: @escaping () -> Void,
        retryBand: @escaping () -> Void,
        testBuzz: @escaping () -> Void,
        setPhoneLayer: @escaping (Bool) -> Void
    ) {
        self.save = save
        self.turnOff = turnOff
        self.retryBand = retryBand
        self.testBuzz = testBuzz
        self.setPhoneLayer = setPhoneLayer
    }

    public static var none: WakeAlarmScreenActions {
        WakeAlarmScreenActions(save: { _ in }, turnOff: {}, retryBand: {}, testBuzz: {}, setPhoneLayer: { _ in })
    }
}

// MARK: - Screen

/// The one place to set, check, and switch off the wake alarm.
///
/// The top of the screen previews the draft: change the time and the big
/// number and the countdown follow before anything is saved. Nothing reaches
/// the band or the phone until the person taps the save button.
public struct WakeAlarmScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let model: WakeAlarmScreenModel
    private let isBusy: Bool
    private let message: String?
    private let formatter: WakeAlarmFormatter
    private let actions: WakeAlarmScreenActions

    @State private var draft: WakeAlarmPlan

    public init(
        model: WakeAlarmScreenModel,
        isBusy: Bool = false,
        message: String? = nil,
        formatter: WakeAlarmFormatter = WakeAlarmFormatter(),
        actions: WakeAlarmScreenActions
    ) {
        self.model = model
        self.isBusy = isBusy
        self.message = message
        self.formatter = formatter
        self.actions = actions
        _draft = State(initialValue: model.initialDraft)
    }

    public var body: some View {
        LooprDetailScaffold {
            hero
            wakeTimeSection
            smartWakeSection
            repeatSection
            layersSection
            testSection
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Wake alarm")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.sleep))
        .accessibilityIdentifier("wake-alarm-screen")
        // The save button stays in reach while the wheel, window, and days
        // are edited further down, so a first alarm is two taps from Today.
        .safeAreaInset(edge: .bottom, spacing: LooprSpacing.none) { actionBar }
        .onChange(of: model.saved) { _, saved in
            // A save or a switch-off lands here. The editor follows what is
            // stored so the screen never shows a stale draft as saved.
            if let saved { draft = saved }
        }
        // A stored alarm is the result the person waited for: a success tap
        // when one is set or changed, a light one when it is switched off.
        .sensoryFeedback(trigger: model.saved) { old, new in
            WakeAlarmHaptics.feedback(from: old, to: new)
        }
        .sensoryFeedback(.selection, trigger: draft.weekdays)
        .sensoryFeedback(.selection, trigger: draft.smartWindowMinutes)
        .animation(motion, value: model.isOn)
        .animation(motion, value: primaryTitle)
        .animation(motion, value: draft.hasSmartWindow)
    }

    /// Springs for state changes; with Reduce Motion, a short fade.
    private var motion: Animation {
        LooprMotion.reducesMotion(reduceMotion) ? .easeInOut(duration: LooprMotion.fast) : .smooth(duration: LooprMotion.standard)
    }

    // MARK: Hero

    private var hero: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            LooprSurface(emphasis: .hero(model.isOn ? .sleep : .inkSecondary)) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    HStack(alignment: .center, spacing: LooprSpacing.sm) {
                        LooprText(heroEyebrow.uppercased(), style: .sectionLabel, color: .inkSecondary)
                            .accessibilityHidden(true)
                        Spacer(minLength: LooprSpacing.sm)
                        heroChip
                        Toggle("Wake alarm", isOn: Binding(
                            get: { model.isOn },
                            set: { isOn in
                                if isOn {
                                    var plan = draft
                                    plan.isEnabled = true
                                    actions.save(plan)
                                } else {
                                    actions.turnOff()
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(Color.loopr(.sleep))
                        .disabled(isBusy || draft.weekdays.isEmpty)
                        .accessibilityLabel("Wake alarm")
                        .accessibilityIdentifier("wake-alarm-toggle")
                    }

                    heroText(now: context.date)
                }
            }
        }
    }

    private func heroText(now: Date) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            Text(formatter.time(minuteOfDay: draft.wakeMinute))
                .looprTypography(.hero)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(model.isOn ? .ink : .inkSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                // The digits roll as the wheel turns.
                .animation(LooprMotion.reducesMotion(reduceMotion) ? nil : .snappy(duration: LooprMotion.fast), value: draft.wakeMinute)

            LooprText(heroLine(now: now), style: .rowTitle, color: model.isOn ? .ink : .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let window = heroWindowLine {
                Label {
                    LooprText(window, style: .prose, color: .inkSecondary)
                } icon: {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(Color.loopr(.sleep))
                }
                .labelStyle(WakeAlarmInlineLabelStyle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroAccessibilityLabel(now: now))
        .accessibilityIdentifier("wake-alarm-hero")
    }

    private var heroEyebrow: String {
        draft.hasSmartWindow ? "Wake by" : "Wake at"
    }

    /// Only an unsaved edit needs a chip; the switch already says on or off.
    @ViewBuilder
    private var heroChip: some View {
        if model.isOn, draft.differs(from: model.saved) {
            StatusChip("Not saved", symbol: "pencil", tone: .warning)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private func heroLine(now: Date) -> String {
        guard let occurrence = WakeAlarmSchedule.next(
            for: previewPlan, after: now, calendar: formatter.calendar
        ) else {
            return "Pick at least one day."
        }
        guard model.isOn else {
            return "Would go off \(formatter.sentence(for: occurrence.wake, now: now, midSentence: true))"
        }
        return formatter.sentence(for: occurrence.wake, now: now)
    }

    private var heroWindowLine: String? {
        guard let start = draft.windowStartMinute else { return nil }
        return "Loopr may wake you from \(formatter.time(minuteOfDay: start)) if you are in light sleep"
    }

    private func heroAccessibilityLabel(now: Date) -> String {
        [
            "Wake alarm \(model.isOn ? "on" : "off")",
            "\(heroEyebrow) \(formatter.time(minuteOfDay: draft.wakeMinute))",
            heroLine(now: now),
            heroWindowLine
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }

    /// The draft as if it were on, so the countdown previews the real next
    /// wake even while the alarm is off.
    private var previewPlan: WakeAlarmPlan {
        var plan = draft
        plan.isEnabled = true
        return plan
    }

    // MARK: Editor

    /// The wheel works in dates; the plan works in minutes of the day.
    private var wakeDate: Binding<Date> {
        Binding(
            get: {
                let calendar = formatter.calendar
                let start = calendar.startOfDay(for: Date())
                return calendar.date(byAdding: .minute, value: draft.wakeMinute, to: start) ?? start
            },
            set: { date in
                let parts = formatter.calendar.dateComponents([.hour, .minute], from: date)
                draft = draft.withWakeMinute((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
        )
    }

    private var wakeTimeSection: some View {
        LooprSectionGroup(title: draft.hasSmartWindow ? "Latest wake time" : "Wake time") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    DatePicker(
                        "Wake time",
                        selection: wakeDate,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .environment(\.calendar, formatter.calendar)
                    .environment(\.timeZone, formatter.calendar.timeZone)
                    .accessibilityIdentifier("wake-alarm-time-picker")

                    if let suggestion = model.suggestion, suggestion.minuteOfDay != draft.wakeMinute {
                        LooprHairline()
                        Button {
                            withAnimation(motion) { draft = draft.withWakeMinute(suggestion.minuteOfDay) }
                        } label: {
                            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Color.loopr(.sleep))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                    LooprText(
                                        "Use \(formatter.time(minuteOfDay: suggestion.minuteOfDay))",
                                        style: .settingsRow
                                    )
                                    LooprText(suggestion.reason, style: .prose, color: .inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: LooprSpacing.sm)
                            }
                            .padding(.horizontal, LooprSpacing.formCardPadding)
                            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.looprPressableRow)
                        .transition(.opacity)
                        .accessibilityIdentifier("wake-alarm-use-suggestion")
                    }
                }
            }
        }
    }

    private var smartWakeSection: some View {
        LooprSectionGroup(title: "Smart wake") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Picker("Smart wake window", selection: $draft.smartWindowMinutes) {
                        ForEach(draft.windowOptions, id: \.self) { minutes in
                            Text(minutes == 0 ? "Off" : "\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("wake-alarm-smart-window")

                    LooprText(smartWakeExplanation, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if draft.hasSmartWindow {
                        LooprText(
                            "Early waking works while Loopr is running and your band is connected. If iOS pauses Loopr, you wake at \(formatter.time(minuteOfDay: draft.wakeMinute)).",
                            style: .caption,
                            color: .inkMuted
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    private var smartWakeExplanation: String {
        let wake = formatter.time(minuteOfDay: draft.wakeMinute)
        guard draft.hasSmartWindow else {
            return "Loopr wakes you at \(wake), whatever stage of sleep you are in."
        }
        return "Loopr wakes you in light sleep up to \(draft.smartWindowMinutes) minutes before \(wake). "
            + "\(wake) is the latest you will wake."
    }

    private var repeatSection: some View {
        LooprSectionGroup(title: "Repeat") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(spacing: LooprSpacing.xs) {
                        ForEach(formatter.orderedWeekdays, id: \.self) { day in
                            weekdayButton(day)
                        }
                    }

                    LooprText(formatter.repeatSummary(draft.weekdays), style: .metricUnit, color: .inkSecondary)
                        .accessibilityIdentifier("wake-alarm-repeat-summary")
                }
            }
        }
    }

    private func weekdayButton(_ day: AlarmWeekday) -> some View {
        let isSelected = draft.weekdays.contains(day)
        return Button {
            withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : .snappy(duration: LooprMotion.fast)) {
                if isSelected { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
            }
        } label: {
            Text(day.initial)
                .looprTypography(.metricValue)
                .foregroundStyle(Color.loopr(isSelected ? .background : .inkSecondary))
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
                .background(
                    Color.loopr(isSelected ? .sleep : .surfaceElevated),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .strokeBorder(Color.loopr(.surfaceStroke), lineWidth: isSelected ? LooprSpacing.none : LooprSpacing.hairline)
                        .allowsHitTesting(false)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityLabel(day.rawValue.capitalized)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("wake-alarm-day-\(day.rawValue)")
    }

    // MARK: Actions

    @ViewBuilder
    private var actionBar: some View {
        if primaryTitle != nil || message != nil {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                if let message {
                    LooprInlineMessage(message, tone: .neutral)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("wake-alarm-message")
                }

                if draft.weekdays.isEmpty {
                    LooprInlineMessage("Pick at least one day.", tone: .warning)
                        .transition(.opacity)
                }

                if let primaryTitle {
                    Button {
                        var plan = draft
                        plan.isEnabled = true
                        actions.save(plan)
                    } label: {
                        HStack(spacing: LooprSpacing.xs) {
                            if isBusy { ProgressView().tint(Color.loopr(.background)) }
                            Text(primaryTitle)
                        }
                    }
                    .buttonStyle(LooprPrimaryButtonStyle(accent: .sleep))
                    .disabled(isBusy || draft.weekdays.isEmpty)
                    .accessibilityIdentifier("wake-alarm-save")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.xs)
            .animation(motion, value: message)
            .animation(motion, value: draft.weekdays.isEmpty)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .background {
                LinearGradient(
                    colors: [Color.loopr(.background).opacity(0), Color.loopr(.background)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.35)
                )
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
        }
    }

    private var primaryTitle: String? {
        if !model.isOn { return "Set alarm for \(formatter.time(minuteOfDay: draft.wakeMinute))" }
        return draft.differs(from: model.saved) ? "Save changes" : nil
    }

    // MARK: Layers

    private var layersSection: some View {
        LooprSectionGroup(title: "How Loopr wakes you") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(alignment: .leading, spacing: LooprSpacing.none) {
                        bandLayerRow
                        LooprHairline()
                        phoneLayerRow
                    }
                }

                LooprText(
                    "The band alarm is a silent buzz on your wrist. On WHOOP 4.0 it has accepted alarms and then not buzzed, even after confirming. Keep the phone alarm on for any morning that matters.",
                    style: .caption,
                    color: .inkMuted
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, LooprSpacing.xxs)
            }
        }
    }

    private var bandLayerRow: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                layerIcon("waveform.path", accent: .sleep)
                LooprText("Band buzz", style: .settingsRow)
                Spacer(minLength: LooprSpacing.sm)
                StatusChip(model.band.title, symbol: model.band.symbol, tone: bandTone)
                    .accessibilityIdentifier("wake-alarm-band-status")
            }
            LooprText(model.band.detail, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.band.canRetry, model.bandConnected {
                Button("Send to band again", action: actions.retryBand)
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .disabled(isBusy)
                    .accessibilityIdentifier("wake-alarm-band-retry")
            }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .accessibilityElement(children: .contain)
    }

    private var phoneLayerRow: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            Toggle(isOn: Binding(
                get: { model.phoneLayerEnabled },
                set: { actions.setPhoneLayer($0) }
            )) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    layerIcon("iphone.radiowaves.left.and.right", accent: .brand)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText("Phone alarm", style: .settingsRow)
                        LooprText("RECOMMENDED", style: .confidence, color: .brand)
                    }
                }
            }
            .tint(Color.loopr(.brand))
            .disabled(isBusy)
            .accessibilityIdentifier("wake-alarm-phone-layer")

            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                StatusChip(model.phone.title, symbol: phoneSymbol, tone: phoneTone)
                    .accessibilityIdentifier("wake-alarm-phone-status")
                Spacer(minLength: LooprSpacing.none)
            }
            LooprText(model.phone.detail, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
    }

    private func layerIcon(_ symbol: String, accent: LooprColorToken) -> some View {
        Image(systemName: symbol)
            .looprTypography(.rowTitle)
            .foregroundStyle(Color.loopr(accent))
            .frame(width: LooprSpacing.xxl, height: LooprSpacing.xxl)
            .background(Color.loopr(accent).opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private var bandTone: ChipTone {
        switch model.band {
        case .confirmed: .positive
        case .notConfirmed, .notArmed: .warning
        case .off, .notConnected, .waiting: .neutral
        }
    }

    private var phoneTone: ChipTone {
        switch model.phone {
        case .systemAlarm: .positive
        case .idle: .neutral
        case .disabled, .notification, .unavailable: .warning
        }
    }

    private var phoneSymbol: String {
        switch model.phone {
        case .systemAlarm: "checkmark.circle"
        case .idle: "circle"
        case .disabled: "bell.slash"
        case .notification: "bell.badge"
        case .unavailable: "exclamationmark.circle"
        }
    }

    // MARK: Test

    private var testSection: some View {
        LooprSectionGroup(title: "Test") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText(
                        model.bandConnected
                            ? "Plays the alarm buzz on your band now. Your phone stays quiet."
                            : "Connect your band to test the buzz. Loopr can only reach a band that is connected.",
                        style: .prose,
                        color: .inkSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wake-alarm-test-explanation")

                    Button(action: actions.testBuzz) {
                        Label("Test buzz", systemImage: "waveform.path")
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .disabled(!model.bandConnected || isBusy)
                    .accessibilityIdentifier("wake-alarm-test")
                }
            }
        }
    }
}

private struct WakeAlarmInlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            configuration.icon.accessibilityHidden(true)
            configuration.title
        }
    }
}

/// Which tap a change to the stored alarm earns.
enum WakeAlarmHaptics {
    static func feedback(from old: WakeAlarmPlan?, to new: WakeAlarmPlan?) -> SensoryFeedback? {
        guard old != new else { return nil }
        if new?.isEnabled == true { return .success }
        if old?.isEnabled == true { return .impact(weight: .light) }
        return nil
    }
}

// MARK: - Card

/// The compact card on Today and Sleep. One tap opens the wake alarm screen.
public struct WakeAlarmCard: View {
    private let state: WakeAlarmCardState
    private let formatter: WakeAlarmFormatter
    private let accessibilityIdentifier: String
    private let action: () -> Void

    public init(
        state: WakeAlarmCardState,
        formatter: WakeAlarmFormatter = WakeAlarmFormatter(),
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.state = state
        self.formatter = formatter
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            LooprSurface {
                HStack(alignment: .center, spacing: LooprSpacing.md) {
                    icon
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LooprChevron()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the wake alarm.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var isOn: Bool {
        if case .scheduled = state { return true }
        return false
    }

    private var icon: some View {
        Image(systemName: isOn ? "alarm.fill" : "alarm")
            .looprTypography(.title)
            .foregroundStyle(Color.loopr(.sleep))
            .frame(width: LooprSpacing.hero, height: LooprSpacing.hero)
            .background(Color.loopr(.sleep).opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprText("WAKE ALARM", style: .sectionLabel, color: .inkSecondary)
                LooprSkeleton(height: LooprSpacing.lg)
            }
        case .notSet(let lastWakeMinute, let suggestion):
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText("WAKE ALARM", style: .sectionLabel, color: .inkSecondary)
                LooprText("Set a wake alarm", style: .cardTitle)
                LooprText(notSetDetail(lastWakeMinute: lastWakeMinute, suggestion: suggestion), style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .scheduled(let summary):
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText("WAKE ALARM · \(summary.repeatSummary.uppercased())", style: .sectionLabel, color: .inkSecondary)
                Text(summary.wakeTime)
                    .looprTypography(.metricCompact)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(.ink))
                LooprText(summary.when, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let smartWindow = summary.smartWindow {
                    LooprText(smartWindow, style: .caption, color: .sleep)
                }
                if let warning = summary.warning {
                    LooprInlineMessage(warning, tone: .warning)
                        .padding(.top, LooprSpacing.xxs)
                }
            }
        }
    }

    private func notSetDetail(lastWakeMinute: Int?, suggestion: WakeAlarmSuggestion?) -> String {
        if let suggestion {
            return "Suggested \(formatter.time(minuteOfDay: suggestion.minuteOfDay)) from your recent nights."
        }
        if let lastWakeMinute {
            return "Off. Last set for \(formatter.time(minuteOfDay: lastWakeMinute))."
        }
        return "A buzz on your band, with a phone alarm as backup."
    }

    private var accessibilityText: String {
        switch state {
        case .loading:
            return "Wake alarm, loading"
        case .notSet(let lastWakeMinute, let suggestion):
            return "Set a wake alarm. " + notSetDetail(lastWakeMinute: lastWakeMinute, suggestion: suggestion)
        case .scheduled(let summary):
            return ["Wake alarm \(summary.wakeTime)", summary.repeatSummary, summary.when, summary.smartWindow, summary.warning]
                .compactMap { $0 }
                .joined(separator: ". ")
        }
    }
}
#endif
