import SwiftUI
import Charts
import AnalyticsKit
import DesignSystem
import NotificationKit

/// Settings > Heart alerts. Modelled on the Apple Health heart cards: one card
/// per alert, the rule spelled out under each toggle, and the history below.
struct HeartAlertsSettingsScreen: View {
    var runtime: LooprHeartAlertsRuntime = .shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var preferences = HeartAlertsPreferences.off
    @State private var records: [HeartAlertRecord] = []
    @State private var delivery = NotificationDeliverySettings.standard
    @State private var authorization: NotificationAuthorizationState = .notDetermined
    @State private var loaded = false
    @State private var saving = false
    @State private var message: String?
    @State private var selectedID: String?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                if authorization == .denied && preferences.anyEnabled {
                    LooprInlineMessage("Notifications for Loopr are off in iOS Settings, so these alerts can't reach you.", tone: .warning)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .accessibilityIdentifier("heart-alerts-open-settings")
                }
                LooprSectionGroup(title: "Heart rate") {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        highCard
                        lowCard
                    }
                }
                LooprSectionGroup(title: "Overnight") { overnightCard }
                LooprSectionGroup(title: "Quiet hours") { quietHoursCard }
                LooprSectionGroup(title: "How this works") { explainer }
                    .id("explainer")
                LooprSectionGroup(title: "History") { historyList }
                    .id("history")
                if let message {
                    LooprInlineMessage(message, tone: .warning)
                }
            }
            .padding(LooprSpacing.screenGutter)
        }
        .onChange(of: loaded) { _, isLoaded in
            // DEBUG only, for screenshots of the lower half.
            guard isLoaded, let anchor = Self.debugScrollAnchor() else { return }
            proxy.scrollTo(anchor, anchor: .top)
        }
        }
        .background(Color.loopr(.background))
        .foregroundStyle(Color.loopr(.ink))
        .navigationTitle("Heart alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.heart))
        .accessibilityIdentifier("settings-destination-heartAlerts")
        .navigationDestination(item: $selectedID) { id in
            if let record = records.first(where: { $0.id == id }) {
                HeartAlertDetailScreen(record: record)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
            if let requested = LooprNotificationLaunchRoute.shared.takeRequestedHeartAlert() ?? Self.debugRequestedAlert() {
                selectedID = records.first { $0.id == requested }?.id
            }
        }
    }

    // MARK: - Cards

    private var highCard: some View {
        LooprFormCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                LooprToggleRow(title: "High heart rate", isOn: binding(\.rates.highEnabled))
                    .accessibilityIdentifier("heart-alerts-high-toggle")
                LooprHairline()
                thresholdPicker(
                    title: "Threshold",
                    choices: HeartRateAlertSettings.highThresholdChoices,
                    value: binding(\.rates.highThresholdBPM),
                    identifier: "heart-alerts-high-threshold"
                )
                LooprHairline()
                ruleText("You'll get a notification if your heart rate stays above \(preferences.rates.highThresholdBPM) bpm for 10 minutes while you seem to be at rest.")
            }
        }
    }

    private var lowCard: some View {
        LooprFormCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                LooprToggleRow(title: "Low heart rate", isOn: binding(\.rates.lowEnabled))
                    .accessibilityIdentifier("heart-alerts-low-toggle")
                LooprHairline()
                thresholdPicker(
                    title: "Threshold",
                    choices: HeartRateAlertSettings.lowThresholdChoices,
                    value: binding(\.rates.lowThresholdBPM),
                    identifier: "heart-alerts-low-threshold"
                )
                LooprHairline()
                LooprToggleRow(
                    title: "Include sleep",
                    subtitle: "Heart rate often drops during sleep, so sleep is left out unless you turn this on.",
                    isOn: binding(\.rates.lowIncludesSleep)
                )
                .disabled(!preferences.rates.lowEnabled)
                .accessibilityIdentifier("heart-alerts-low-sleep")
                LooprHairline()
                ruleText("You'll get a notification if your heart rate stays below \(preferences.rates.lowThresholdBPM) bpm for 10 minutes while you seem to be at rest.")
            }
        }
    }

    private var overnightCard: some View {
        LooprFormCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                LooprToggleRow(title: "Overnight check", isOn: binding(\.overnightCheckEnabled))
                    .accessibilityIdentifier("heart-alerts-overnight-toggle")
                LooprHairline()
                ruleText("Loopr compares resting heart rate, HRV, breathing rate and skin temperature with your usual ranges. Each signal needs 14 nights with a reading. Today shows a heads-up when two or more are outside range. A notification follows a second night, once per episode.")
                    .accessibilityIdentifier("heart-alerts-overnight-explanation")
            }
        }
    }

    private var quietHoursCard: some View {
        LooprFormCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                LooprToggleRow(
                    title: "Heart rate alerts during quiet hours",
                    subtitle: quietHoursSubtitle,
                    isOn: binding(\.allowDuringQuietHours)
                )
                .accessibilityIdentifier("heart-alerts-quiet-hours")
            }
        }
    }

    private var quietHoursSubtitle: String {
        guard delivery.quietHoursEnabled else {
            return "Quiet hours are off, so alerts arrive as soon as Loopr sees them."
        }
        let start = Self.clock(delivery.quietHours.startMinute)
        let end = Self.clock(delivery.quietHours.endMinute)
        return preferences.allowDuringQuietHours
            ? "Alerts also arrive between \(start) and \(end). The overnight check always waits for the morning."
            : "Alerts from between \(start) and \(end) arrive when quiet hours end. You can change quiet hours in Notifications."
    }

    private var explainer: some View {
        LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("Loopr reads heart rate and wrist movement from the band. An alert needs 10 minutes past your threshold, and the band sends its data about every 15 minutes. So an alert arrives 10 to 25 minutes after the change began, or later if your phone was out of range.", style: .prose, color: .inkSecondary)
                LooprText("Before it alerts, Loopr checks the band's heart rate against the time between individual beats. If the two disagree, it stays quiet. Loopr also skips workouts you record and the 10 minutes after them.", style: .prose, color: .inkSecondary)
                LooprText("Loopr is not a medical device. An alert only tells you that your heart rate crossed the number you chose. It can't tell you why. If it keeps happening, a healthcare professional can help.", style: .prose, color: .inkSecondary)
            }
        }
        .accessibilityIdentifier("heart-alerts-explainer")
    }

    @ViewBuilder
    private var historyList: some View {
        if !loaded {
            LooprSkeleton(height: 56)
        } else if records.isEmpty {
            LooprFormCard {
                LooprText("No alerts yet. When one arrives it shows up here with a chart of the minutes around it.", style: .prose, color: .inkSecondary)
            }
            .accessibilityIdentifier("heart-alerts-history-empty")
        } else {
            HairlineMetricList(rows: records.map { record in
                HairlineMetricRow(
                    id: record.id,
                    title: HeartAlertPresentation.title(record),
                    confidence: HeartAlertPresentation.meta(record),
                    value: HeartAlertPresentation.value(record),
                    unit: HeartAlertPresentation.unit(record),
                    accent: .heart,
                    showsDisclosure: true,
                    action: { selectedID = record.id }
                )
            })
            .accessibilityIdentifier("heart-alerts-history")
        }
    }

    // MARK: - Pieces

    private func ruleText(_ text: String) -> some View {
        LooprText(text, style: .prose, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.sm)
    }

    private func thresholdPicker(title: String, choices: [Int], value: Binding<Int>, identifier: String) -> some View {
        HStack {
            LooprText(title, style: .settingsRow)
            Spacer()
            Picker(title, selection: value) {
                ForEach(choices, id: \.self) { choice in
                    Text("\(choice) bpm").tag(choice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<HeartAlertsPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { newValue in
                var next = preferences
                next[keyPath: keyPath] = newValue
                preferences = next
                Task { await save(next) }
            }
        )
    }

    private func save(_ next: HeartAlertsPreferences) async {
        saving = true
        defer { saving = false }
        // Switching any alert on is the moment to ask for permission.
        if next.anyEnabled {
            switch await LooprNotificationRuntime.shared.refreshAuthorization() {
            case .notDetermined:
                _ = await LooprNotificationRuntime.shared.requestPermission()
            case .authorized, .denied:
                break
            }
            authorization = await LooprNotificationRuntime.shared.refreshAuthorization()
        }
        do {
            try await runtime.update(next)
            message = nil
        } catch {
            message = "Loopr couldn't save this change. \(error.localizedDescription)"
            preferences = await runtime.preferences()
        }
    }

    private func refresh() async {
        preferences = await runtime.preferences()
        records = (await runtime.history()).compactMap { record in
            guard record.kind == .overnightCheck else { return record }
            var visible = record
            visible.overnightMetrics = record.overnightMetrics.filter {
                OvernightVitalMetric.monitored.contains($0.metric)
            }
            return visible.overnightMetrics.count >= 2 ? visible : nil
        }
        #if DEBUG
        if let fixture = DebugCaptureFixtures.siVitalsAlertRecord() { records = [fixture] }
        #endif
        delivery = await LooprNotificationRuntime.shared.deliverySettings()
        authorization = await LooprNotificationRuntime.shared.refreshAuthorization()
        loaded = true
    }

    /// DEBUG only: `--loopr-heart-alert=<id>` opens one history entry, for
    /// screenshots of the detail screen.
    static func debugRequestedAlert() -> String? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--loopr-heart-alert=") }
            .map { String($0.dropFirst("--loopr-heart-alert=".count)) }
        #else
        nil
        #endif
    }

    static func debugScrollAnchor() -> String? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--loopr-heart-alerts-scroll=") }
            .map { String($0.dropFirst("--loopr-heart-alerts-scroll=".count)) }
        #else
        nil
        #endif
    }

    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

/// Labels shared by the history row and the detail screen.
enum HeartAlertPresentation {
    static func title(_ record: HeartAlertRecord) -> String {
        switch record.kind {
        case .highHeartRate: "High heart rate"
        case .lowHeartRate: "Low heart rate"
        case .overnightCheck: "Overnight check"
        case .cardioFitness: "Cardio fitness"
        }
    }

    static func meta(_ record: HeartAlertRecord) -> String {
        let date = record.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return "\(date) · \(deliveryLabel(record.delivery))".uppercased()
    }

    static func value(_ record: HeartAlertRecord) -> String {
        if let episode = record.episode { return "\(Int(episode.extremeBPM.rounded()))" }
        if !record.overnightMetrics.isEmpty { return "\(record.overnightMetrics.count)" }
        return "Low"
    }

    static func unit(_ record: HeartAlertRecord) -> String? {
        if record.episode != nil { return "bpm" }
        if !record.overnightMetrics.isEmpty { return "outside range" }
        return nil
    }

    static func deliveryLabel(_ delivery: HeartAlertDelivery) -> String {
        switch delivery {
        case .sent: "Sent"
        case .heldForQuietHours: "Held for quiet hours"
        case .waitingForPermission: "Waiting for permission"
        case .paused: "Paused for the day"
        case .notificationsOff: "Notifications off"
        case .notSent: "Not sent"
        }
    }
}

/// One alert: what crossed, when, and the minutes around it.
struct HeartAlertDetailScreen: View {
    let record: HeartAlertRecord
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                if let episode = record.episode {
                    episodeContent(episode)
                } else if !record.overnightMetrics.isEmpty {
                    overnightContent
                } else {
                    LooprFormCard {
                        LooprText("Your latest cardio fitness estimate was in the low range. Regular aerobic exercise can raise it.", style: .prose, color: .inkSecondary)
                    }
                }
                LooprFormCard {
                    LooprText("Loopr is not a medical device. This alert says what the band measured, not why. If it keeps happening, a healthcare professional can help.", style: .caption, color: .inkSecondary)
                }
            }
            .padding(LooprSpacing.screenGutter)
        }
        .background(Color.loopr(.background))
        .navigationTitle(HeartAlertPresentation.title(record))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .accessibilityIdentifier("heart-alert-detail")
    }

    @ViewBuilder
    private func episodeContent(_ episode: HeartRateAlertEpisode) -> some View {
        let start = Date(timeIntervalSince1970: TimeInterval(episode.start))
        let end = Date(timeIntervalSince1970: TimeInterval(episode.end))
        let direction = episode.kind == .high ? "above" : "below"
        LooprSurface(emphasis: .hero(.heart)) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprText(start.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased(), style: .sectionLabel, color: .inkSecondary)
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                    LooprText("\(Int(episode.medianBPM.rounded()))", style: .metric)
                    LooprText("bpm median", style: .metricUnit, color: .inkSecondary)
                }
                LooprText("\(HeartAlertsCopy.sentence(for: episode)) From \(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened)).", style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        LooprSectionGroup(title: "Heart rate around the alert") {
            LooprFormCard {
                HeartAlertEpisodeChart(episode: episode)
                    .frame(height: 180)
            }
        }
        HairlineMetricList(rows: [
            HairlineMetricRow(title: "Threshold", value: "\(direction) \(episode.thresholdBPM)", unit: "bpm"),
            HairlineMetricRow(title: episode.kind == .high ? "Highest minute" : "Lowest minute",
                              value: "\(Int(episode.extremeBPM.rounded()))", unit: "bpm"),
            HairlineMetricRow(title: "Beat-to-beat check",
                              value: episode.confirmationBPM.map { "\(Int($0.rounded()))" } ?? "Not available",
                              unit: episode.confirmationBPM == nil ? nil : "bpm"),
            HairlineMetricRow(title: "Asleep", value: episode.duringSleep ? "Probably" : "No"),
            HairlineMetricRow(title: "Notification", value: HeartAlertPresentation.deliveryLabel(record.delivery))
        ])
    }

    private var overnightContent: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprFormCard {
                LooprText(
                    HeartAlertsCopy.overnightSentence(record.overnightMetrics.map { ($0.metric, $0.direction) })
                        + " " + HeartAlertsCopy.overnightFactors,
                    style: .prose, color: .inkSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            HairlineMetricList(rows: record.overnightMetrics.map { metric in
                HairlineMetricRow(
                    title: metric.metric == .skinTemperatureDeviation ? "Approximate wrist temperature" : HeartAlertsCopy.metricName(metric.metric).capitalizedFirst,
                    confidence: "USUAL \(Self.format(metric.low, metric.metric)) TO \(Self.format(metric.high, metric.metric))",
                    value: Self.format(metric.value, metric.metric),
                    unit: Self.unit(metric.metric)
                )
            })
        }
    }

    static func format(_ value: Double, _ metric: OvernightVitalMetric) -> String {
        switch metric {
        case .restingHeartRate, .heartRateVariability, .oxygenSaturation: String(Int(value.rounded()))
        case .respiratoryRate, .skinTemperatureDeviation: String(format: "%.1f", value)
        }
    }

    static func unit(_ metric: OvernightVitalMetric) -> String {
        switch metric {
        case .restingHeartRate: "bpm"
        case .heartRateVariability: "ms"
        case .respiratoryRate: "br/min"
        case .skinTemperatureDeviation: "°C"
        case .oxygenSaturation: "%"
        }
    }
}

/// Minute medians around the episode, the threshold as a rule, and the
/// alert's minutes shaded. Built with Swift Charts and design tokens only.
struct HeartAlertEpisodeChart: View {
    let episode: HeartRateAlertEpisode

    var body: some View {
        let points = episode.minutes
        if points.count < 2 {
            StateMessage(.absent, compact: true)
        } else {
            Chart {
                RectangleMark(
                    xStart: .value("Start", Date(timeIntervalSince1970: TimeInterval(episode.start))),
                    xEnd: .value("End", Date(timeIntervalSince1970: TimeInterval(episode.end)))
                )
                .foregroundStyle(Color.loopr(.heartSoft).opacity(0.35))
                RuleMark(y: .value("Threshold", episode.thresholdBPM))
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(points, id: \.minuteStart) { point in
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: TimeInterval(point.minuteStart))),
                        y: .value("Heart rate", point.medianBPM)
                    )
                    .foregroundStyle(Color.loopr(.heart))
                    .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: yDomain(points))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.loopr(.divider))
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(LooprTextStyle.overline.font)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.loopr(.divider))
                    AxisValueLabel()
                        .font(LooprTextStyle.overline.font)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary(points))
        }
    }

    private func yDomain(_ points: [HeartRateMinutePoint]) -> ClosedRange<Double> {
        let values = points.map(\.medianBPM) + [Double(episode.thresholdBPM)]
        let low = (values.min() ?? 40) - 10
        let high = (values.max() ?? 120) + 10
        return max(0, low)...high
    }

    private func accessibilitySummary(_ points: [HeartRateMinutePoint]) -> String {
        let values = points.map(\.medianBPM)
        let low = Int((values.min() ?? 0).rounded())
        let high = Int((values.max() ?? 0).rounded())
        return "Heart rate chart. Minute values from \(low) to \(high) beats per minute. Threshold \(episode.thresholdBPM)."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
