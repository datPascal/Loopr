import SwiftUI
import DomainKit
import DesignSystem

struct HeartLiveExperience: View {
    @Environment(\.bandConnected) private var bandConnected
    @Environment(\.looprBandIndicator) private var bandIndicator
    @Environment(\.profileAgeAction) private var profileAgeAction
    @Environment(\.heartTabServices) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var lastStored: HeartLastReading?
    @State private var showsZoneSettings = false
    @State private var opensAgeAfterZoneSettings = false
    @State private var now = Date()

    let samples: [HeartLiveSample]
    let stats: HeartLiveSessionStats

    private var reading: HeartLiveReading? {
        HeartLiveReading.resolve(samples: samples, now: now, zones: services?.zones)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                hero
                if let reading {
                    chart(reading, zones: services?.zones)
                    sessionNumbers
                }
                zoneList
                Button { showsZoneSettings = true } label: {
                    HStack {
                        LooprText("Zone settings", style: .rowTitle)
                        Spacer()
                        LooprChevron()
                    }
                    .padding(.vertical, LooprSpacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("heart-zone-settings-route")
                if reading == nil {
                    LooprText(bandConnected
                        ? "Wear your band snugly to start a live reading."
                        : "Connect your band to start a live reading.",
                        style: .caption, color: .inkSecondary)
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Live heart rate")
        .toolbarBackground(Color.loopr(.background), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityIdentifier("heart-live-screen")
        .task(id: services?.revision) { lastStored = await services?.lastReading?() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
        .sheet(isPresented: $showsZoneSettings, onDismiss: {
            if opensAgeAfterZoneSettings {
                opensAgeAfterZoneSettings = false
                profileAgeAction?.open()
            }
        }) {
            HeartZoneSettingsScreen(settings: services?.zoneSettings ?? HeartRateZoneSettings(),
                                    age: services?.age, restingHeartRate: services?.zones?.zones.restingHeartRate, save: services?.saveZoneSettings,
                                    onAgePrompt: {
                                        opensAgeAfterZoneSettings = true
                                        showsZoneSettings = false
                                    })
        }
    }

    private var hero: some View {
        LooprSurface(emphasis: .hero(reading?.zone?.token ?? .heart)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack {
                    Circle()
                        .fill(Color.loopr(reading?.zone?.token ?? .heart))
                        .frame(width: 7, height: 7)
                    LooprText(reading == nil ? "HEART RATE" : "LIVE HEART RATE", style: .sectionLabel,
                              color: reading?.zone?.textToken ?? (reading == nil ? .inkSecondary : .heart))
                    Spacer()
                    if let zone = reading?.zone { HeartZonePill(zone: zone) }
                }
                if let reading {
                    ZStack(alignment: .bottom) {
                        HeartZoneGauge(zones: services?.zones?.zones, bpm: reading.bpm)
                            .frame(maxWidth: 310)
                            .frame(height: 170)
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30)) { context in
                                let phase = context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 60 / max(35, reading.bpm))
                                let beat = reduceMotion ? 0 : 0.035 * exp(-phase * 13)
                                Text(reading.bpmText)
                                    .looprTypography(.hero)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(reduceMotion ? nil : .smooth(duration: LooprMotion.standard), value: reading.bpmText)
                                    .foregroundStyle(Color.loopr(reading.zone?.textToken ?? .heart))
                                    .scaleEffect(1 + beat)
                            }
                            .accessibilityIdentifier("heart-live-bpm")
                            LooprText("bpm", style: .metricUnit, color: .inkSecondary)
                        }
                        .padding(.bottom, 7)
                    }
                    .frame(maxWidth: .infinity)
                    if let zone = reading.zone {
                        LooprText(zone.title, style: .cardTitle, color: zone.textToken)
                    } else {
                        ageAction
                    }
                    if reading.fromBeatToBeat {
                        LooprText("From beat-to-beat intervals", style: .caption, color: .inkSecondary)
                    }
                } else if let last = newestReading {
                    LooprText("Last reading", style: .cardTitle)
                    ZStack(alignment: .bottom) {
                        HeartZoneGauge(zones: services?.zones?.zones, bpm: last.bpm)
                            .frame(maxWidth: 310)
                            .frame(height: 160)
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            Text(String(Int(last.bpm.rounded())))
                                .looprTypography(.hero)
                                .monospacedDigit()
                                .foregroundStyle(Color.loopr(.ink))
                            LooprText("bpm", style: .metricUnit, color: .inkSecondary)
                        }
                        .padding(.bottom, 7)
                    }
                    .frame(maxWidth: .infinity)
                    LooprText(HeartLastReading.when(last.at, now: now, calendar: .current,
                                                    locale: Locale(identifier: "en_GB")),
                              style: .caption, color: .inkSecondary)
                    LooprText(linkCaption(waiting: "Waiting for live data"), style: .caption, color: .inkSecondary)
                } else {
                    LooprText("No reading yet", style: .cardTitle)
                    HeartZoneGauge(zones: services?.zones?.zones, bpm: nil)
                        .frame(maxWidth: 310)
                        .frame(height: 122)
                    LooprText(linkCaption(waiting: "Waiting for your band"), style: .caption, color: .inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heart-live-reading")
    }

    /// The band's state in a few words. A short reconnect or a history sync
    /// reads as a pause, not as a missing band.
    private func linkCaption(waiting: String) -> String {
        switch bandIndicator?.link {
        case .syncing: "Your band is syncing"
        case .reconnecting: "Connecting to your band"
        default: bandConnected ? waiting : "Band not connected"
        }
    }

    private var ageAction: some View {
        Group {
            if let profileAgeAction {
                Button(ProfileAgePrompt.action) { profileAgeAction.open() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.loopr(.heartChip))
                    .accessibilityIdentifier("heart-live-age-hero-action")
            } else {
                LooprText(ProfileAgePrompt.action, style: .caption, color: .inkSecondary)
            }
        }
    }

    private var newestReading: HeartLastReading? {
        let streamed = samples.last.flatMap { sample -> HeartLastReading? in
            HeartLiveReading.rate(of: sample).map { HeartLastReading(bpm: $0.bpm, at: sample.receivedAt) }
        }
        if let streamed, let lastStored { return streamed.at >= lastStored.at ? streamed : lastStored }
        return streamed ?? lastStored
    }

    private func chart(_ reading: HeartLiveReading, zones: HeartZoneScale?) -> some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack {
                    LooprText("This session", style: .cardTitle)
                    Spacer()
                    LooprText("LAST 3 MIN", style: .sectionLabel, color: .inkMuted)
                }
                HeartLiveRollingChart(reading: reading, zones: zones?.zones)
                    .frame(height: 168)
                    .accessibilityLabel("Heart rate over the last three minutes")
                HStack {
                    LooprText("3 min ago", style: .confidence, color: .inkMuted)
                    Spacer(minLength: LooprSpacing.lg)
                    LooprText("Now", style: .confidence, color: .inkMuted)
                }
            }
        }
        .accessibilityIdentifier("heart-live-chart")
    }

    private var sessionNumbers: some View {
        LooprSurface {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    stat("Average", value: stats.averageBPM.map { "\(Int($0.rounded()))" } ?? "–", unit: "bpm")
                    Divider()
                    stat("Max", value: stats.maximumBPM.map { "\(Int($0.rounded()))" } ?? "–", unit: "bpm")
                    Divider()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        stat("Elapsed", value: elapsedText(stats.elapsed(at: context.date)), unit: nil)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: LooprSpacing.sm) {
                    stat("Average", value: stats.averageBPM.map { "\(Int($0.rounded()))" } ?? "–", unit: "bpm")
                    Spacer(minLength: 2)
                    stat("Max", value: stats.maximumBPM.map { "\(Int($0.rounded()))" } ?? "–", unit: "bpm")
                    Spacer(minLength: 2)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        stat("Elapsed", value: elapsedText(stats.elapsed(at: context.date)), unit: nil)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This session")
        .accessibilityIdentifier("heart-live-session-stats")
        .accessibilityValue(elapsedText(stats.elapsed(at: now)))
    }

    private func stat(_ title: String, value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LooprText(title, style: .caption, color: .inkSecondary)
            Text(value).looprTypography(.metricCompact).monospacedDigit().foregroundStyle(Color.loopr(.ink))
                .accessibilityIdentifier("heart-live-stat-\(title.lowercased())")
            if let unit { LooprText(unit, style: .metricUnit, color: .inkMuted) }
        }
    }

    private func elapsedText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    private var zoneList: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprSectionHeader(stats.count == 0 ? "Your zones" : "Time in each zone")
            if let zones = services?.zones?.zones {
                LooprSurface {
                    VStack(spacing: 0) {
                        ForEach(1...5, id: \.self) { number in
                            zoneRow(number, zones: zones)
                            if number < 5 { Divider().overlay(Color.loopr(.divider)) }
                        }
                    }
                }
            } else {
                ProfileAgePromptButton(identifier: "heart-live-age-zones-action")
            }
        }
        .accessibilityIdentifier("heart-live-zones")
    }

    private func zoneRow(_ number: Int, zones: HeartRateZones) -> some View {
        let current = reading?.zone?.number == number
        let token = HeartZone(number: number, percentOfMax: 0).token
        let range = zones.bpmRange(for: number)
        let seconds = stats.seconds(in: number, zones: zones)
        let total = (1...5).reduce(0.0) { $0 + stats.seconds(in: $1, zones: zones) }
        return VStack(spacing: LooprSpacing.xxs) {
            HStack(spacing: LooprSpacing.sm) {
                RoundedRectangle(cornerRadius: 2).fill(Color.loopr(token)).frame(width: 4, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    LooprText("Zone \(number)", style: .rowTitle, color: current ? token : .ink)
                    if let range {
                        LooprText("\(range.lowerBound)–\(range.upperBound) bpm", style: .caption, color: .inkSecondary)
                    }
                }
                Spacer()
                if stats.count > 0 {
                    LooprText(elapsedText(seconds), style: .metricValue, color: current ? token : .inkSecondary)
                }
            }
            if stats.count > 0 {
                GeometryReader { geometry in
                    Capsule().fill(Color.loopr(token).opacity(0.11))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.loopr(token))
                                .frame(width: geometry.size.width * CGFloat(total > 0 ? seconds / total : 0))
                        }
                }
                .frame(height: 5)
                .padding(.leading, 4 + LooprSpacing.sm)
            }
        }
        .padding(.vertical, LooprSpacing.xs)
        .accessibilityIdentifier("heart-live-zone-\(number)")
    }
}

private struct HeartLiveRollingChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reading: HeartLiveReading
    let zones: HeartRateZones?

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30)) { timeline in
            Canvas { context, size in
                let domain = reading.lineDomain
                let span = max(1, domain.upperBound - domain.lowerBound)
                func y(_ bpm: Double) -> CGFloat {
                    size.height * CGFloat(1 - (bpm - domain.lowerBound) / span)
                }
                let end = timeline.date
                let start = end.addingTimeInterval(-HeartLiveReading.lineSeconds)
                func x(_ date: Date) -> CGFloat {
                    size.width * CGFloat(date.timeIntervalSince(start) / HeartLiveReading.lineSeconds)
                }
                for number in 1...5 {
                    guard let range = zones?.bpmRange(for: number) else { continue }
                    let top = max(0, min(size.height, y(Double(range.upperBound))))
                    let bottom = max(0, min(size.height, y(Double(range.lowerBound))))
                    guard bottom > top else { continue }
                    let color = Color.loopr(HeartZone(number: number, percentOfMax: 0).token)
                    context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                                 with: .color(color.opacity(0.065)))
                }
                for pair in zip(reading.line, reading.line.dropFirst()) {
                    let first = CGPoint(x: x(pair.0.date), y: y(pair.0.bpm))
                    let second = CGPoint(x: x(pair.1.date), y: y(pair.1.bpm))
                    guard second.x >= 0, first.x <= size.width else { continue }
                    var path = Path()
                    path.move(to: first)
                    path.addLine(to: second)
                    let token = zones.map { HeartZone(number: $0.number(for: pair.1.bpm), percentOfMax: 0).token } ?? .heart
                    let tint = Color.loopr(token)
                    context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
                if let last = reading.line.last {
                    let centre = CGPoint(x: x(last.date), y: y(last.bpm))
                    let token = zones.map { HeartZone(number: $0.number(for: last.bpm), percentOfMax: 0).token } ?? .heart
                    let tint = Color.loopr(token)
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8)),
                                 with: .color(tint))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct HeartZoneSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings: HeartRateZoneSettings
    @State private var manualText: String
    @State private var usesManual: Bool
    let age: Int?
    let restingHeartRate: Double?
    let save: (@Sendable (HeartRateZoneSettings) async -> Void)?
    let onAgePrompt: () -> Void

    init(settings: HeartRateZoneSettings, age: Int?, restingHeartRate: Double?, save: (@Sendable (HeartRateZoneSettings) async -> Void)?,
         onAgePrompt: @escaping () -> Void) {
        _settings = State(initialValue: settings)
        _manualText = State(initialValue: (settings.manualMaximum ?? settings.resolved(age: age)?.maximum)
            .map { String(Int($0.rounded())) } ?? "")
        _usesManual = State(initialValue: settings.manualMaximum != nil)
        self.age = age
        self.restingHeartRate = restingHeartRate
        self.save = save
        self.onAgePrompt = onAgePrompt
    }

    private var preview: HeartRateZones? { settings.resolved(age: age, restingNights: restingHeartRate.map { [$0] } ?? []) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            LooprText("Maximum heart rate", style: .cardTitle)
                            if let preview {
                                LooprValueText(String(Int(preview.maximum.rounded())), unit: "bpm")
                                LooprText(source(preview.source), style: .caption, color: .inkSecondary)
                            } else {
                                Button(ProfileAgePrompt.action, action: onAgePrompt)
                                    .foregroundStyle(Color.loopr(.heartChip))
                                    .accessibilityIdentifier("heart-zone-settings-age-action")
                            }
                            Toggle("Set my maximum", isOn: $usesManual)
                                .tint(Color.loopr(.heart))
                                .onChange(of: usesManual) { _, enabled in
                                    settings.manualMaximum = enabled
                                        ? HeartRateZoneSettings.validMaximum(Double(manualText)) : nil
                                }
                            if usesManual {
                                TextField("Maximum in bpm", text: $manualText)
                                    .keyboardType(.numberPad)
                                    .looprTypography(.metricCompact)
                                    .onChange(of: manualText) { _, value in
                                        settings.manualMaximum = HeartRateZoneSettings.validMaximum(Double(value))
                                    }
                                LooprText("Enter 100 to 240 bpm.", style: .caption, color: .inkSecondary)
                            }
                            if settings.manualMaximum != nil {
                                Button("Reset to automatic") {
                                    settings.resetMaximum()
                                    usesManual = false
                                }
                                .foregroundStyle(Color.loopr(.heartChip))
                            }
                        }
                    }
                    LooprSectionHeader("Zone boundaries")
                    LooprText(preview?.calculationSource ?? "From max heart rate", style: .caption, color: .inkSecondary)
                    if let preview {
                        LooprSurface {
                            VStack(spacing: 0) {
                                ForEach(0..<4, id: \.self) { index in
                                    boundaryRow(index, preview: preview)
                                    if index < 3 { Divider().overlay(Color.loopr(.divider)) }
                                }
                            }
                        }
                        Button("Reset zone boundaries") { settings.resetBoundaries() }
                            .foregroundStyle(Color.loopr(.heartChip))
                    } else {
                        LooprSurface {
                            LooprText("Set a maximum heart rate to adjust zones.", style: .prose, color: .inkSecondary)
                        }
                    }
                }
                .padding(LooprSpacing.screenGutter)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Zone settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = settings
                        Task { await save?(value); dismiss() }
                    }
                    .disabled(usesManual && settings.manualMaximum == nil)
                }
            }
            .accessibilityIdentifier("heart-zone-settings-screen")
        }
    }

    private func boundaryRow(_ index: Int, preview: HeartRateZones) -> some View {
        let values = settings.innerBoundaries
        let lower = (index == 0 ? 50 : values[index - 1]) + 5
        let upper = (index == 3 ? 100 : values[index + 1]) - 5
        return Stepper(value: Binding(get: { values[index] }, set: { newValue in
            var edited = settings.innerBoundaries
            edited[index] = newValue
            _ = settings.setBoundaries(edited)
        }), in: lower...upper) {
            HStack {
                LooprText("Zone \(index + 2) starts", style: .rowTitle)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    LooprText("\(values[index])%", style: .metricValue)
                    LooprText("\(Int(ceil(preview.bpmBoundary(percent: values[index])))) bpm",
                              style: .caption, color: .inkSecondary)
                }
            }
        }
        .padding(.vertical, LooprSpacing.xs)
        .accessibilityIdentifier("heart-zone-boundary-\(index + 1)")
    }

    private func source(_ source: HeartRateMaximumSource) -> String {
        switch source {
        case .estimated: "Estimated from your age"
        case .observed: "Observed during a workout"
        case .manual: "Set by you"
        }
    }
}
