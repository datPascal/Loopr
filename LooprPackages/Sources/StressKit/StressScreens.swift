import Foundation
import Combine
import SwiftUI
import Accessibility
import AnalyticsKit
import DesignSystem

public enum StressRoute: Hashable, Sendable, CaseIterable {
    case stress
    case breathing
    case spotCheck
    case history
}

public enum StressScreenStateFixtures {
    public static let allStates = MetricState.allCases
    public static let accessibilityIdentifiers = ["stress-screen", "stress-breathing", "stress-spot-check", "stress-history"]
    public static let statesByScreen = Dictionary(uniqueKeysWithValues: accessibilityIdentifiers.map { ($0, allStates) })
    public static func accessibilitySummary(for state: MetricState) -> String { "\(state.title). \(state.detail)" }
}

@MainActor
public final class StressViewModel: ObservableObject {
    @Published public private(set) var snapshot: StressScreenSnapshot
    @Published public private(set) var hourlyStress: HourlyStressDay?
    @Published public private(set) var hourlyStressReadFailed = false
    @Published public private(set) var breathingState: BreathingState = .ready
    @Published public private(set) var spotChecks: [SpotCheckResult] = []
    @Published public private(set) var breathingHistory: [BreathingResult] = []
    /// Why the last spot check did not produce a reading. The spot-check
    /// screen renders this; without it a failed 60-second measurement ends in
    /// silence and looks like nothing happened.
    @Published public private(set) var spotCheckErrorMessage: String?
    public let liveActivityAvailability: StressLiveActivityAvailability
    private let breathing: BreathingSessionController?
    private let spotCheck: SpotCheckController?
    private let history: SpotCheckHistory?
    private let store: (any StressStore)?
    private let liveActivityBoundary: any StressLiveActivityBoundary

    public init(
        breathing: BreathingSessionController? = nil,
        spotCheck: SpotCheckController? = nil,
        history: SpotCheckHistory? = nil,
        store: (any StressStore)? = nil,
        liveActivityBoundary: any StressLiveActivityBoundary = UnavailableStressLiveActivityBoundary()
    ) {
        self.breathing = breathing
        self.spotCheck = spotCheck
        self.history = history
        self.store = store
        self.liveActivityBoundary = liveActivityBoundary
        self.liveActivityAvailability = liveActivityBoundary.availability
        snapshot = StressScreenSnapshot(state: .absent)
    }

    public func refresh() async {
        if let breathing { breathingState = await breathing.currentState() }
        if let store {
            do {
                if let observation = try await store.latestObservationChecked() {
                    let detail = StressDetail(observation: observation)
                    snapshot = StressScreenSnapshot(state: detail.value == nil ? .lowConfidence : .ready, stress: detail, day: observation.day)
                } else {
                    snapshot = StressScreenSnapshot(state: .absent)
                }
            } catch {
                // A failed read is not the same as a day without data. Show the
                // error state so the hero does not pretend the day is empty.
                snapshot = StressScreenSnapshot(state: .recoverableError)
            }
            do {
                let next = try await store.hourlyStress()
                if hourlyStress != next { hourlyStress = next }
                hourlyStressReadFailed = false
            } catch { hourlyStressReadFailed = true }
            spotChecks = await store.spotChecks()
            breathingHistory = await store.breathingHistory()
        } else if let history {
            spotChecks = await history.all()
        }
        if store == nil, let breathing {
            breathingHistory = await breathing.history()
        }
    }

    public func runSpotCheck() async {
        guard let spotCheck else {
            spotCheckErrorMessage = StressError.liveUnavailable.localizedDescription
            return
        }
        spotCheckErrorMessage = nil
        do {
            let result = try await spotCheck.run()
            try await store?.saveSpotCheck(result)
            await refresh()
        } catch {
            // The stress reading already on screen is still the last real
            // measurement. A failed spot check is news about the spot check,
            // not a reason to blank the day.
            spotCheckErrorMessage = error.localizedDescription
            if let store {
                spotChecks = await store.spotChecks()
            } else if let history {
                spotChecks = await history.all()
            }
        }
    }

    public func startBreathing(cadence: Double = 6, id: UUID = UUID()) async throws {
        guard let breathing else { throw StressError.liveUnavailable }
        let sessionID = try await breathing.start(cadence: cadence, id: id)
        await liveActivityBoundary.update(sessionID: sessionID, result: nil)
        breathingState = await breathing.currentState()
    }

    @discardableResult
    public func finishBreathing(now: Date = Date()) async throws -> BreathingResult {
        guard let breathing else { throw StressError.liveUnavailable }
        let result = try await breathing.finish(now: now)
        try await saveBreathingResult(result)
        await liveActivityBoundary.finish(sessionID: result.id, result: result)
        breathingState = await breathing.currentState()
        return result
    }

    @discardableResult
    public func saveBreathingResult(_ result: BreathingResult) async throws -> BreathingResult {
        guard let store else { throw StressError.liveUnavailable }
        try await store.saveBreathingResult(result)
        breathingHistory = await store.breathingHistory()
        return result
    }

    public func interruptBreathing() async throws {
        guard let breathing else { throw StressError.liveUnavailable }
        try await breathing.interrupt()
        breathingState = await breathing.currentState()
    }
}

public enum StressFixtures {
    public static let lowCoverage = StressDetail(observation: StressObservation(day: "2026-08-18", value: 62, coverage: 0.35, confidence: 0.9))
    public static let qualified = StressDetail(observation: StressObservation(day: "2026-08-18", value: 62, coverage: 0.85, confidence: 0.8))
}

public struct StressScreen: View {
    @Environment(\.looprMetricLink) private var metricLink
    @ObservedObject private var viewModel: StressViewModel
    @State private var trendPoints: [LooprChartPoint] = []
    @State private var trendRange: LooprChartRange = .month
    private let route: (StressRoute) -> Void

    public init(viewModel: StressViewModel, route: @escaping (StressRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        LooprDetailScaffold {
            StressMetricFace(
                value: viewModel.snapshot.stress?.value,
                state: viewModel.snapshot.state.metricState,
                day: viewModel.snapshot.day.map { _ in displayedDate },
                confidence: viewModel.snapshot.stress?.confidence,
                usual: usualRange,
                measuredDays: measuredDays
            )

            LooprSectionGroup(title: "Daytime stress") {
                if viewModel.hourlyStressReadFailed {
                    LooprFormCard { LooprText("Could not load daytime stress. Try refreshing.", style: .prose, color: .inkSecondary) }
                } else {
                    HourlyStressCard(day: viewModel.hourlyStress, openBreathing: { route(.breathing) })
                }
            }

            LooprSectionGroup(title: "Recent days") {
                LooprMetricTrendCard(
                    title: "Stress",
                    points: trendPoints,
                    endingOn: displayedDate,
                    range: $trendRange,
                    kind: .line,
                    accent: .stress,
                    unit: "/100",
                    valueFormat: { String(Int($0.rounded())) },
                    baseline: usualRange,
                    identifier: "stress-trend",
                    showsRangePicker: false
                )
            }

            LooprSectionGroup(title: "Explore") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    navigationButton(
                        title: "Calm breathing",
                        subtitle: "Follow a six-breaths-per-minute session",
                        symbol: "wind",
                        destination: .breathing,
                        identifier: "stress-breathing"
                    )
                    navigationButton(
                        title: "Spot check",
                        subtitle: "Measure HRV in 60 seconds",
                        symbol: "timer",
                        destination: .spotCheck,
                        identifier: "stress-spot-check"
                    )
                    navigationButton(
                        title: "Spot-check history",
                        subtitle: "Review completed readings",
                        symbol: "clock.arrow.circlepath",
                        destination: .history,
                        identifier: "stress-history"
                    )
                }
            }
        }
        .navigationTitle("Stress")
        .accessibilityIdentifier("stress-screen")
        .task(id: viewModel.snapshot.day) {
            guard viewModel.snapshot.day != nil else {
                trendPoints = []
                return
            }
            if let historyEndingOn = metricLink?.historyEndingOn {
                trendPoints = await historyEndingOn(LooprMetricLinkID.stress, 31, displayedDate)
            } else {
                trendPoints = await metricLink?.history(LooprMetricLinkID.stress, 31) ?? []
            }
        }
    }

    private var displayedDate: Date {
        guard let day = viewModel.snapshot.day else { return Date() }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }

    private var usualRange: LooprBaselineBand? {
        LooprBaselineBand.trailing(trendPoints, before: displayedDate)
    }

    private var measuredDays: Int {
        let start = Calendar.current.date(byAdding: .day, value: -LooprBaselineBand.windowDays, to: displayedDate) ?? displayedDate
        return trendPoints.filter { $0.date >= start && $0.date < displayedDate }.count
    }

    private func navigationButton(
        title: String,
        subtitle: String,
        symbol: String,
        destination: StressRoute,
        identifier: String
    ) -> some View {
        Button { route(destination) } label: {
            LooprSurface {
                StressNavigationRow(title: title, subtitle: subtitle, symbol: symbol)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

public struct StressBreathingScreen: View {
    @Environment(\.bandConnected) private var bandConnected
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private let controller: BreathingSessionController
    public let onFinish: () -> Void
    private let onFinishResult: @Sendable (BreathingResult) async throws -> Void
    @State private var state: BreathingState = .ready
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var paceWithBand: Bool
    @State private var result: BreathingResult?
    @State private var pacingStartedAt: Date?
    private let autoStart: Bool
    private let bandPacingUnavailableReason: (@Sendable () async -> String?)?
    @State private var pacingUnavailableReason: String?

    public init(
        controller: BreathingSessionController = BreathingSessionController(),
        onFinish: @escaping () -> Void = {},
        onFinishResult: @escaping @Sendable (BreathingResult) async throws -> Void = { _ in },
        paceWithBand: Bool = false, autoStart: Bool = false,
        bandPacingUnavailableReason: (@Sendable () async -> String?)? = nil
    ) {
        self.controller = controller
        self.onFinish = onFinish
        self.onFinishResult = onFinishResult
        _paceWithBand = State(initialValue: paceWithBand)
        self.autoStart = autoStart
        self.bandPacingUnavailableReason = bandPacingUnavailableReason
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Guided exercise") {
                LooprSurface(emphasis: .hero(.stress)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        StatusChip(
                            breathingStatusLabel,
                            symbol: breathingStatusSymbol,
                            tone: breathingStatusTone
                        )
                        LooprText("Six breaths per minute", style: .titleLarge)
                        LooprText(
                            guidanceInstruction,
                            style: .prose,
                            color: .inkSecondary
                        )
                        StressBreathingGuide(isRunning: state == .running, startedAt: pacingStartedAt)
                    }
                }
            }

            LooprSurface {
                Toggle(isOn: $paceWithBand) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText("Pace with band buzzes", style: .rowTitle)
                        LooprText(!bandConnected ? "Connect your band to use buzzes." : pacingUnavailableReason ?? "One buzz to inhale. Two to exhale.", style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .tint(Color.loopr(.stress))
                    .disabled(!bandConnected || pacingUnavailableReason != nil || [.running, .paused, .interrupted].contains(state) || isWorking)
                    .accessibilityIdentifier("stress-band-pacing")
            }
            if let result {
                LooprSectionGroup(title: "Session result") {
                    HairlineMetricList(rows: [
                        HairlineMetricRow(id: "before", title: "Heart rate at start", value: result.beforeHeartRate.map(String.init) ?? "Not recorded", unit: result.beforeHeartRate == nil ? nil : "bpm", accent: .stress),
                        HairlineMetricRow(id: "after", title: "Heart rate at finish", value: result.afterHeartRate.map(String.init) ?? "Not recorded", unit: result.afterHeartRate == nil ? nil : "bpm", accent: .stress)
                    ])
                }
            }
            LooprSectionGroup(title: "Actions") {
                Button(action: handlePrimaryAction) {
                    Text(primaryActionTitle)
                        .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LooprPrimaryButtonStyle(accent: .stress))
                .disabled(isWorking)
                .accessibilityIdentifier(state == .running ? "stress-breathing-finish" : "stress-breathing-start")
            }

            if let errorMessage {
                LooprFormCard {
                    LooprInlineMessage(errorMessage, tone: .critical)
                        .accessibilityIdentifier("stress-breathing-error")
                }
            }
        }
        .navigationTitle("Calm breathing")
        .accessibilityIdentifier("stress-breathing-screen")
        .task {
            state = await controller.currentState()
            pacingStartedAt = await controller.currentPacingStart()
            pacingUnavailableReason = await bandPacingUnavailableReason?()
            if state == .completed { result = await controller.history().last }
            if autoStart, state != .running { handlePrimaryAction() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                state = await controller.currentState()
                pacingUnavailableReason = await bandPacingUnavailableReason?()
            }
        }
    }

    private var primaryActionTitle: String {
        if state == .running { return "Finish breathing" }
        if state == .paused || state == .interrupted { return "Resume breathing" }
        return "Start breathing"
    }

    private var breathingStatusLabel: String {
        switch state {
        case .running:
            "Session active"
        case .paused:
            "Session paused"
        case .interrupted:
            "Session interrupted"
        case .completed:
            "Session complete"
        case .cancelled:
            "Ready"
        case .staleGeneration:
            "Session ended"
        case .ready:
            "Ready"
        }
    }

    private var breathingStatusTone: ChipTone {
        switch state {
        case .running, .completed:
            .positive
        case .paused, .cancelled, .ready:
            .neutral
        case .interrupted, .staleGeneration:
            .warning
        }
    }

    private var breathingStatusSymbol: String {
        switch state {
        case .running:
            "wind"
        case .paused:
            "pause.circle"
        case .interrupted, .staleGeneration:
            "exclamationmark.triangle"
        case .completed:
            "checkmark.circle"
        case .cancelled, .ready:
            "play.circle"
        }
    }

    private var guidanceInstruction: String {
        shouldReduceMotion
            ? "Follow the count for each inhale and exhale."
            : "Breathe in as the circle grows. Breathe out as it shrinks."
    }

    private var shouldReduceMotion: Bool {
        accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }

    private func handlePrimaryAction() {
        let actionState = state
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            do {
                if actionState == .running {
                    let result = try await controller.finish()
                    self.result = result
                    try await onFinishResult(result)
                    state = await controller.currentState()
                    onFinish()
                } else if actionState == .paused || actionState == .interrupted {
                    try await controller.resume()
                    state = await controller.currentState()
                } else {
                    _ = try await controller.start(paceWithBand: paceWithBand && bandConnected && pacingUnavailableReason == nil)
                    result = nil
                    state = await controller.currentState()
                }
            } catch {
                state = await controller.currentState()
                errorMessage = error.localizedDescription
            }
            pacingStartedAt = await controller.currentPacingStart()
            isWorking = false
        }
    }
}

public struct StressSpotCheckScreen: View {
    private let onRun: (() -> Void)?
    private let controller: SpotCheckController?
    private let providedLatestResult: SpotCheckResult?
    @State private var errorMessage: String?
    @State private var runTask: Task<Void, Never>?
    @State private var localLatestResult: SpotCheckResult?

    /// A failure reported by whoever owns `onRun`. The screen cannot see
    /// inside that closure, so the caller passes the reason back in.
    private let providedErrorMessage: String?

    public init(
        controller: SpotCheckController? = nil,
        latestResult: SpotCheckResult? = nil,
        errorMessage: String? = nil,
        onRun: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.providedLatestResult = latestResult
        self.providedErrorMessage = errorMessage
        self.onRun = onRun
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Latest result") {
                if let latestResult {
                    resultContent(latestResult)
                } else {
                    LooprSurface(emphasis: .hero(.stress)) {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            LooprText("No spot check yet", style: .title)
                            LooprText(
                                "Take a reading to see your HRV and heart rate here.",
                                style: .prose,
                                color: .inkSecondary
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("No spot check yet. Take a reading to see your HRV and heart rate here.")
                    }
                }
            }

            LooprSectionGroup(title: "Measure") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprText(
                            "Take a 60-second reading while sitting still and keeping the strap snug.",
                            style: .prose,
                            color: .inkSecondary
                        )
                        Button("Start spot check", action: startSpotCheck)
                            .buttonStyle(LooprPrimaryButtonStyle(accent: .stress))
                            .accessibilityIdentifier("stress-spot-check-start")

                        if let message = errorMessage ?? providedErrorMessage {
                            LooprInlineMessage(message, tone: .warning)
                                .accessibilityIdentifier("stress-spot-check-error")
                        }
                    }
                }
            }
        }
        .navigationTitle("Stress spot check")
        .accessibilityIdentifier("stress-spot-check-screen")
        .onDisappear {
            runTask?.cancel()
            runTask = nil
            if let controller {
                Task { await controller.interrupt() }
            }
        }
    }

    private var latestResult: SpotCheckResult? {
        providedLatestResult ?? localLatestResult
    }

    @ViewBuilder
    private func resultContent(_ result: SpotCheckResult) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            if let rmssd = result.rmssd.flatMap(formattedRMSSD) {
                LooprSurface(emphasis: .hero(.stress)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprText("HRV", style: .sectionLabel, color: .inkSecondary)
                        LooprValueText(rmssd, unit: "ms",
                                       valueStyle: .display, unitStyle: .metricValue)
                        if let confidence = resultConfidence(result) {
                            LooprText(confidence, style: .confidence, color: .inkSecondary)
                        }
                    }
                }
            } else if let heartRate = formattedHeartRate(result.heartRate) {
                LooprSurface(emphasis: .hero(.stress)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprText("HEART RATE", style: .sectionLabel, color: .inkSecondary)
                        LooprValueText(heartRate, unit: "bpm", valueStyle: .display, unitStyle: .metricValue)
                    }
                }
            } else {
                LooprSurface {
                    StateMessage(resultMetricState(result), accent: .stress)
                }
            }

            if result.rmssd != nil, let heartRate = formattedHeartRate(result.heartRate) {
                HairlineMetricList(rows: [
                    HairlineMetricRow(id: "stress-spot-check-heart-rate", title: "Heart rate",
                                     value: heartRate, unit: "bpm", accent: .stress)
                ])
            }

            if result.resolvedAvailability == .insufficientQuality {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        StateMessage(.lowConfidence)
                            .accessibilityIdentifier("stress-spot-check-insufficient-quality")
                        LooprInlineMessage(
                            "The reading was captured, but the signal was not clean enough for a reliable result. Keep the strap snug, sit still, and try again.",
                            tone: .neutral
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("stress-spot-check-result")
    }

    private func startSpotCheck() {
        errorMessage = nil
        if let onRun {
            onRun()
        } else if let controller {
            runTask?.cancel()
            runTask = Task { @MainActor in
                do {
                    localLatestResult = try await controller.run(duration: .seconds(60))
                } catch {
                    if Task.isCancelled { return }
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            errorMessage = StressError.liveUnavailable.localizedDescription
        }
    }

    private func resultMetricState(_ result: SpotCheckResult) -> MetricState {
        switch result.resolvedAvailability {
        case .complete:
            .partial
        case .insufficientQuality:
            .lowConfidence
        case .unavailable:
            .absent
        }
    }

    private func resultConfidence(_ result: SpotCheckResult) -> String? {
        switch result.resolvedAvailability {
        case .complete:
            guard let quality = result.qualityAvailable else { return nil }
            return "\(Int((quality * 100).rounded()))% signal quality"
        case .insufficientQuality:
            return "Low confidence"
        case .unavailable:
            return nil
        }
    }

    private func formattedHeartRate(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    private func formattedRMSSD(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

public struct StressHistoryScreen: View {
    @State private var trendRange: LooprChartRange = .month
    public let results: [SpotCheckResult]
    public let breathingHistory: [BreathingResult]
    public init(results: [SpotCheckResult] = [], breathingHistory: [BreathingResult] = []) {
        self.results = results
        self.breathingHistory = breathingHistory
    }

    public var body: some View {
        LooprDetailScaffold {
            if results.isEmpty && breathingHistory.isEmpty {
                LooprSectionGroup(title: "History") {
                    LooprFormCard {
                        StateMessage(.noRecords, accent: .stress)
                    }
                }
            } else {
                LooprSectionGroup(title: "Trend") {
                    if trendPoints.count < 2 {
                        LooprFormCard {
                            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                                if trendPoints.isEmpty {
                                    StateMessage(trendState, accent: .stress)
                                    if !results.isEmpty {
                                        LooprText(
                                            "The chart needs a complete spot check. Captured readings remain below.",
                                            style: .prose,
                                            color: .inkSecondary
                                        )
                                    }
                                } else {
                                    LooprText("Another day of readings will start your trend.", style: .cardTitle)
                                    LooprText("Your completed spot check is below.", style: .prose, color: .inkSecondary)
                                }
                            }
                        }
                    } else {
                        LooprMetricTrendCard(
                            title: "Daily spot-check heart rate",
                            points: trendPoints,
                            endingOn: sortedResults.last?.startedAt ?? Date(),
                            range: $trendRange,
                            kind: .line,
                            accent: .stress,
                            unit: "bpm",
                            valueFormat: { String(Int($0.rounded())) },
                            identifier: "stress-history-trend"
                        )
                    }
                }

                if !spotCheckRows.isEmpty {
                    LooprSectionGroup(title: "Spot checks") {
                        HairlineMetricList(rows: spotCheckRows)
                    }
                }

                if !breathingRows.isEmpty {
                    LooprSectionGroup(title: "Breathing sessions") {
                        HairlineMetricList(rows: breathingRows)
                    }
                }
            }
        }
        .navigationTitle("Stress history")
        .accessibilityIdentifier("stress-history-screen")
    }

    private var sortedResults: [SpotCheckResult] {
        results.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    private var sortedBreathingHistory: [BreathingResult] {
        breathingHistory.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    private var trendPoints: [LooprChartPoint] {
        var latestByDay: [Date: Double] = [:]
        for result in sortedResults {
            guard result.resolvedAvailability == .complete,
                  let value = result.heartRate,
                  value.isFinite else { continue }
            latestByDay[Calendar.current.startOfDay(for: result.startedAt)] = value
        }
        return latestByDay.map { LooprChartPoint(date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }

    private var trendState: MetricState {
        if results.contains(where: { $0.resolvedAvailability == .insufficientQuality }) {
            return .lowConfidence
        }
        if results.contains(where: { $0.resolvedAvailability == .complete }) {
            return .partial
        }
        return .absent
    }

    private var spotCheckRows: [HairlineMetricRow] {
        sortedResults.map { result in
            let value = formattedHeartRate(result.heartRate) ?? resultMetricState(result).title
            return HairlineMetricRow(
                id: "stress-history-spot-check-\(result.id.uuidString)",
                title: result.startedAt.formatted(date: .abbreviated, time: .shortened),
                confidence: resultConfidence(result),
                value: value,
                unit: formattedHeartRate(result.heartRate) == nil ? nil : "bpm",
                accent: formattedHeartRate(result.heartRate) == nil ? .inkSecondary : .stress
            )
        }
    }

    private var breathingRows: [HairlineMetricRow] {
        sortedBreathingHistory.map { result in
            HairlineMetricRow(
                id: "stress-history-breathing-\(result.id.uuidString)",
                title: result.startedAt.formatted(date: .abbreviated, time: .shortened),
                confidence: "\(result.samples) samples",
                value: result.cadence.formatted(.number.precision(.fractionLength(0))),
                unit: "breaths/min",
                accent: .stress
            )
        }
    }

    private func resultMetricState(_ result: SpotCheckResult) -> MetricState {
        switch result.resolvedAvailability {
        case .complete:
            .partial
        case .insufficientQuality:
            .lowConfidence
        case .unavailable:
            .absent
        }
    }

    private func resultConfidence(_ result: SpotCheckResult) -> String? {
        switch result.resolvedAvailability {
        case .complete:
            guard let quality = result.qualityAvailable else { return nil }
            return "\(Int((quality * 100).rounded()))% signal quality"
        case .insufficientQuality:
            return "Low confidence"
        case .unavailable:
            return nil
        }
    }

    private func formattedHeartRate(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

}

private struct StressNavigationRow: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: LooprSpacing.md) {
            Image(systemName: symbol)
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(.stress))
                .frame(width: LooprSpacing.xxl, height: LooprSpacing.xxl)
                .background(Color.loopr(.stress).opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(title, style: .rowTitle)
                LooprText(subtitle, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: LooprSpacing.sm)

            LooprChevron()
        }
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

private struct StressBreathingGuide: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let isRunning: Bool
    let startedAt: Date?

    @State private var phase: StressBreathingPhase = .ready
    @State private var breathNumber = 0
    @State private var isExpanded = false

    private let cadence: Double = 6

    var body: some View {
        VStack(alignment: .center, spacing: LooprSpacing.sm) {
            if isRunning {
                if shouldReduceMotion {
                    discreteGuide
                } else {
                    SpectralLens(
                        value: phase.lensValue,
                        caption: "BREATHE",
                        accent: .stress,
                        diameter: LooprSpacing.hero * 3
                    )
                    .scaleEffect(isExpanded ? 1 : 0.78)
                    .animation(phaseAnimation, value: isExpanded)
                }

                LooprText(phase.title, style: .title)
                if !shouldReduceMotion {
                    breathCount
                }
            } else {
                LooprText("Start the session to begin.", style: .prose, color: .inkSecondary)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: isRunning ? LooprSpacing.hero * 3 : LooprSpacing.none
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(phase.title)
        .onChange(of: phase) { _, newPhase in
            guard isRunning, newPhase != .ready else { return }
            if #available(iOS 17.0, macOS 14.0, *) {
                AccessibilityNotification.Announcement(newPhase.title).post()
            }
        }
        .task(id: taskIdentity) {
            await runGuide()
        }
    }

    private var discreteGuide: some View {
        VStack(spacing: LooprSpacing.xxs) {
            MetricNumeral(String(max(breathNumber + 1, 1)))
            LooprText("breath", style: .metricUnit, color: .inkSecondary)
        }
        .frame(minHeight: LooprSpacing.hero * 3)
    }

    private var breathCount: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            MetricNumeral(String(max(breathNumber + 1, 1)), compact: true)
            LooprText("breath", style: .metricUnit, color: .inkSecondary)
        }
    }

    private var accessibilitySummary: String {
        guard isRunning else { return "Breathing guide ready" }
        return "Breathing guide, breath \(max(breathNumber + 1, 1))"
    }

    private var taskIdentity: String {
        "\(isRunning)-\(shouldReduceMotion)"
    }

    private var shouldReduceMotion: Bool {
        accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }

    private var halfCycle: Double {
        60 / cadence / 2
    }

    private var phaseAnimation: Animation {
        guard !shouldReduceMotion else { return LooprMotion.stateChange }
        return LooprMotion.revealAnimation.speed(LooprMotion.deliberate / halfCycle)
    }

    @MainActor
    private func runGuide() async {
        guard isRunning else {
            phase = .ready
            breathNumber = 0
            isExpanded = false
            return
        }

        let start = startedAt ?? Date()
        while !Task.isCancelled {
            let index = Int(max(0, Date().timeIntervalSince(start)) / halfCycle)
            phase = index.isMultiple(of: 2) ? .inhale : .exhale
            breathNumber = index / 2
            if !shouldReduceMotion {
                withAnimation(phaseAnimation) { isExpanded = phase == .inhale }
            } else { isExpanded = false }
            do {
                try await Task.sleep(for: .seconds(max(0.01, Double(index + 1) * halfCycle - Date().timeIntervalSince(start))))
            } catch { return }
        }
    }
}

private enum StressBreathingPhase: Equatable {
    case ready
    case inhale
    case exhale

    var title: String {
        switch self {
        case .ready:
            "Get ready"
        case .inhale:
            "Inhale"
        case .exhale:
            "Exhale"
        }
    }

    var lensValue: String {
        switch self {
        case .ready:
            "READY"
        case .inhale:
            "IN"
        case .exhale:
            "OUT"
        }
    }
}

private extension StressScreenSnapshot.State {
    var metricState: MetricState {
        switch self {
        case .loading:
            .loading
        case .noRecords:
            .noRecords
        case .absent:
            .absent
        case .measuredZero:
            .measuredZero
        case .partial:
            .partial
        case .lowConfidence:
            .lowConfidence
        case .settling:
            .settling
        case .stale:
            .stale
        case .disconnected:
            .disconnected
        case .bluetoothOff:
            .bluetoothOff
        case .permissionDenied:
            .permissionDenied
        case .unsupportedHardware:
            .unsupportedHardware
        case .recoverableError:
            .recoverableError
        case .destructiveFailure:
            .destructiveFailure
        case .migrationFailure:
            .recoverableError
        case .ready:
            .partial
        }
    }
}
