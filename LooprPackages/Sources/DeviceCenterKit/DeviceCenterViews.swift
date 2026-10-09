#if canImport(SwiftUI) && canImport(Combine)
import Combine
import DesignSystem
import Foundation
import SwiftUI

@MainActor
public final class DeviceCenterViewModel: ObservableObject {
    @Published public private(set) var viewState: DeviceCenterViewState
    @Published public private(set) var lastActionError: String?

    private let repository: any DeviceCenterRepository
    private let actionService: CapabilityGatedDeviceActionService

    public init(
        repository: any DeviceCenterRepository,
        actionService: CapabilityGatedDeviceActionService
    ) {
        self.repository = repository
        self.actionService = actionService
        self.viewState = DeviceCenterViewState(universalState: .loading, identity: nil, status: nil)
    }

    public func load() {
        Task {
            do {
                viewState = try await DeviceCenterViewStateLoader.load(from: repository)
                lastActionError = nil
            } catch {
                lastActionError = error.localizedDescription
                viewState = DeviceCenterViewState(universalState: .recoverableError, identity: nil, status: nil, message: error.localizedDescription)
            }
        }
    }

    /// Reads the band again while the screen is open. The current state stays
    /// on screen until the new one arrives, and a failed read keeps it, so a
    /// reconnect does not flash the loading or error state.
    public func reload() async {
        guard let next = try? await DeviceCenterViewStateLoader.load(from: repository) else { return }
        if next != viewState { viewState = next }
    }

    public func send(_ command: DeviceCommand, onSuccess: (@MainActor () async -> Void)? = nil) {
        Task {
            do {
                _ = try await actionService.perform(command)
                lastActionError = nil
                await onSuccess?()
                viewState = try await DeviceCenterViewStateLoader.load(from: repository)
            } catch {
                lastActionError = error.localizedDescription
            }
        }
    }

    public func exportDiagnostics() async throws -> Data {
        let identity = try await repository.readIdentity()
        let status = try await repository.readStatus()
        let export = DeviceDiagnosticExporter.make(identity: identity, status: status, generatedAt: Date())
        return try DeviceDiagnosticExporter.encode(export)
    }
}

@available(macOS 13.0, iOS 17.0, *)
public struct DeviceCenterScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isForgetConfirmationPresented = false
    @State private var isRePairConfirmationPresented = false
    @State private var nameDraft = ""
    @State private var seededNameFor: String?

    public let viewState: DeviceCenterViewState
    public let modelLabel: String?
    public let heartRateSharingEnabled: Bool?
    public let heartRateSharingMessage: String?
    public let onHeartRateSharingChange: @MainActor @Sendable (Bool) -> Void
    public let onCommand: (DeviceCommand) -> Void
    public let onExportDiagnostics: () -> Void
    public let experimentalSupportEnabled: Bool?
    public let onExperimentalSupportChange: (Bool) -> Void

    public init(
        viewState: DeviceCenterViewState,
        modelLabel: String? = nil,
        onCommand: @escaping (DeviceCommand) -> Void,
        onExportDiagnostics: @escaping () -> Void = {},
        experimentalSupportEnabled: Bool? = nil,
        onExperimentalSupportChange: @escaping (Bool) -> Void = { _ in },
        heartRateSharingEnabled: Bool? = nil,
        heartRateSharingMessage: String? = nil,
        onHeartRateSharingChange: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
    ) {
        self.viewState = viewState
        self.modelLabel = modelLabel
        self.heartRateSharingEnabled = heartRateSharingEnabled
        self.heartRateSharingMessage = heartRateSharingMessage
        self.onHeartRateSharingChange = onHeartRateSharingChange
        self.onCommand = onCommand
        self.onExportDiagnostics = onExportDiagnostics
        self.experimentalSupportEnabled = experimentalSupportEnabled
        self.onExperimentalSupportChange = onExperimentalSupportChange
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Device") {
                identityContent
            }

            LooprSectionGroup(title: "Status") {
                statusContent
            }

            if let experimentalSupportEnabled {
                LooprSectionGroup(title: "Experimental bands") {
                    LooprSurface {
                        Toggle(isOn: Binding(
                            get: { experimentalSupportEnabled },
                            set: onExperimentalSupportChange
                        )) {
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText("WHOOP 5.0 and MG", style: .cardTitle)
                                LooprText(
                                    "Pairing and band data are experimental. Turn this off to stop a 5.0 or MG connection. Your saved history stays on this iPhone.",
                                    style: .prose,
                                    color: .inkSecondary
                                )
                            }
                        }
                        .accessibilityIdentifier("device-experimental-support")
                    }
                }
            }

            if let diagnostics = viewState.diagnostics {
                LooprSectionGroup(title: "First-session diagnostics") {
                    diagnosticsContent(diagnostics)
                }
                .accessibilityIdentifier("device-first-session-diagnostics")
            }

            if viewState.identity != nil {
                actionContent
            }

            if viewState.identity != nil {
                LooprSectionGroup(title: "Capabilities") {
                    capabilityContent
                }
            }
        }
        .navigationTitle("Device Center")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("device-center-screen")
        .confirmationDialog(
            "Forget this strap?",
            isPresented: $isForgetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Forget this strap", role: .destructive) {
                onCommand(DeviceCommand(action: .forgetBand))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the strap, its connection record, and its saved alarm from Loopr.")
        }
        .confirmationDialog(
            "Pair this strap again?",
            isPresented: $isRePairConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Pair again") {
                onCommand(DeviceCommand(action: .rePair))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Loopr drops the current pairing and opens the picker so you can choose the strap again. Wake it until its side light pulses blue.")
        }
        .onChange(of: viewState.identity?.displayName, initial: true) { _, name in
            seedNameDraft(with: name)
        }
        // A new reading of the band settles in place: the battery rolls, the
        // connection word crossfades, and sections that come or go slide.
        .animation(
            LooprMotion.reducesMotion(reduceMotion) ? .easeInOut(duration: LooprMotion.fast) : .smooth(duration: LooprMotion.standard),
            value: viewState
        )
        // A rename that reached the band taps once.
        .sensoryFeedback(.success, trigger: viewState.identity?.displayName) { old, new in
            old != nil && new != nil && old != new
        }
    }

    /// The field follows the stored name until the user edits it, then stops
    /// so a background refresh cannot overwrite what they are typing.
    private func seedNameDraft(with name: String?) {
        let stored = name ?? ""
        guard seededNameFor != stored else { return }
        seededNameFor = stored
        nameDraft = StrapNameRules.userName(fromBandName: stored)
    }

    @ViewBuilder
    private var identityContent: some View {
        if let identity = viewState.identity {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprSurface(emphasis: .hero(.brand)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        HStack(alignment: .top, spacing: LooprSpacing.sm) {
                            Image(systemName: "applewatch")
                                .looprTypography(.title)
                                .foregroundStyle(Color.loopr(.brand))
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText(
                                    identity.displayName ?? identity.modelName ?? "Unknown device",
                                    style: .cardTitle
                                )
                                LooprText(modelLabel ?? identity.generation.displayName, style: .prose, color: .inkSecondary)
                                if identity.generation == .betaGen5 || identity.generation == .betaMG || identity.generation == .betaUnknownGen5 {
                                    LooprText("Experimental", style: .prose, color: .inkSecondary)
                                }
                            }
                        }

                        if let status = viewState.status {
                            identityStatusContent(status)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(identityAccessibilityLabel(for: identity))
                }

                HairlineMetricList(rows: identityRows(for: identity))
            }
        } else {
            LooprSurface(emphasis: .hero(.brand)) {
                if let metricState { StateMessage(metricState) }
            }
        }
    }

    @ViewBuilder
    private func identityStatusContent(_ status: DeviceStatusSnapshot) -> some View {
        LooprHairline()
        if status.charging == true {
            Label("Charging", systemImage: "bolt.fill")
                .font(.subheadline)
                .foregroundStyle(Color.loopr(.brand))
        }

        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.md))
            : AnyLayout(HStackLayout(alignment: .top, spacing: LooprSpacing.lg))
        layout {
            deviceHeroMetric(
                title: "Battery",
                value: batteryHeroValue(status.batteryPercent),
                unit: batteryHeroUnit(status.batteryPercent),
                accent: batteryHeroAccent(status.batteryPercent)
            )

            deviceHeroMetric(
                title: "Connection",
                value: status.connection.displayName,
                accent: connectionAccent(status.connection)
            )
        }
    }

    private func deviceHeroMetric(
        title: String,
        value: String,
        unit: String? = nil,
        accent: LooprColorToken
    ) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(title.uppercased(), style: .sectionLabel, color: .inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                LooprText(value, style: .metricValue, color: accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
                if let unit {
                    LooprText(unit, style: .metricUnit, color: .inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capabilityContent: some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(viewState.capabilityRows.enumerated()), id: \.element.action) { index, row in
                    capabilityRow(row)
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .accessibilityLabel(row.accessibilityLabel)
                    .accessibilityIdentifier("device-capability-\(row.action.rawValue)")

                    if index < viewState.capabilityRows.count - 1 {
                        LooprHairline()
                    }
                }
            }
        }
    }

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprSurface(emphasis: .hero(metricState?.accent ?? .brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    if let metricState {
                        StateMessage(metricState)
                        if let message = viewState.message {
                            LooprInlineMessage(message, tone: metricState.messageTone)
                        }
                    } else {
                        LooprInlineMessage(viewState.message ?? "Connected and ready.", tone: .positive)
                    }
                }
            }

            if let status = viewState.status {
                HairlineMetricList(rows: statusRows(for: status))
            }
        }
    }

    private func diagnosticsContent(_ diagnostics: DeviceFirstSessionDiagnostics) -> some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(diagnostics.rows.enumerated()), id: \.element.id) { index, row in
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                            LooprText(row.title, style: .prose)
                            Spacer(minLength: LooprSpacing.sm)
                            if let timestamp = row.timestamp {
                                LooprText(
                                    timestamp.formatted(date: .abbreviated, time: .standard),
                                    style: .caption,
                                    color: .inkSecondary
                                )
                            }
                        }
                        LooprText(row.detail, style: .caption, color: .inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.sm)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("device-diagnostic-\(row.category.rawValue)-\(index)")

                    if index < diagnostics.rows.count - 1 {
                        LooprHairline()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprSectionGroup(title: "Actions") {
                LooprFormCard {
                    VStack(spacing: LooprSpacing.sm) {
                        if viewState.isActionAvailable(.manualSync) {
                            Button("Sync now") {
                                onCommand(DeviceCommand(action: .manualSync))
                            }
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("device-manual-sync")
                        }

                        Button("Export diagnostics", action: onExportDiagnostics)
                            .buttonStyle(LooprButtonStyle(prominent: false))
                            .accessibilityIdentifier("device-export-diagnostics")
                    }
                }
            }

            if let heartRateSharingEnabled {
                LooprSectionGroup(title: "Heart rate") {
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            Toggle(isOn: Binding(get: { heartRateSharingEnabled }, set: { value in onHeartRateSharingChange(value) })) {
                                LooprText("Share heart rate", style: .rowTitle)
                            }
                            .tint(Color.loopr(.brand))
                            .accessibilityIdentifier("device-share-heart-rate")
                            LooprText("Other apps and equipment can read live heart rate. This uses more battery.", style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let heartRateSharingMessage {
                                LooprText(heartRateSharingMessage, style: .caption, color: .inkSecondary)
                            }
                        }
                    }
                }
            }

            if viewState.isActionAvailable(.rename) {
                LooprSectionGroup(title: "Name") {
                    renameContent
                }
            }

            if !exploreRows.isEmpty {
                LooprMenuGroup(title: "Explore", rows: exploreRows)
            }

            if viewState.isActionAvailable(.rePair) {
                LooprSectionGroup(title: "Pairing") {
                    LooprFormCard {
                        Button("Pair again") {
                            isRePairConfirmationPresented = true
                        }
                        .buttonStyle(LooprButtonStyle(prominent: false))
                        .accessibilityIdentifier("device-re-pair")
                    }
                }
            }

            if viewState.isActionAvailable(.forgetBand) {
                LooprSectionGroup(title: "Forget") {
                    LooprFormCard {
                        Button("Forget this strap") {
                            isForgetConfirmationPresented = true
                        }
                        .buttonStyle(LooprDestructiveButtonStyle())
                        .accessibilityIdentifier("device-forget-band")
                    }
                }
            }
        }
    }

    private var renameContent: some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(alignment: .leading, spacing: LooprSpacing.none) {
                LooprTextFieldRow(
                    title: "Strap name",
                    placeholder: "Bedroom strap",
                    text: $nameDraft
                )
                .accessibilityIdentifier("device-rename-field")

                LooprHairline()

                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    LooprText(StrapNameRules.limitExplanation, style: .caption, color: .inkSecondary)

                    Button("Save name") {
                        onCommand(DeviceCommand(action: .rename, argument: nameDraft))
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .disabled(!isNameDraftValid)
                    .accessibilityIdentifier("device-rename-save")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            }
        }
    }

    private var isNameDraftValid: Bool {
        (try? StrapNameRules.validatedUserName(nameDraft)) != nil
    }

    private var exploreRows: [LooprMenuItem] {
        var rows: [LooprMenuItem] = []

        if viewState.isActionAvailable(.findMyStrap) {
            rows.append(
                LooprMenuItem(
                    title: "Find my strap",
                    accessibilityIdentifier: "device-find-my-strap",
                    action: { onCommand(DeviceCommand(action: .findMyStrap)) }
                )
            )
        }

        if viewState.isActionAvailable(.displayGestureMapping) {
            rows.append(
                LooprMenuItem(
                    title: "Gesture controls",
                    accessibilityIdentifier: "device-gesture-mapping",
                    action: { onCommand(DeviceCommand(action: .displayGestureMapping)) }
                )
            )
        }

        if viewState.isActionAvailable(.strapAlarmSetup) {
            rows.append(
                LooprMenuItem(
                    title: "Wake alarm",
                    accessibilityIdentifier: "strap-alarm-setup",
                    action: { onCommand(DeviceCommand(action: .strapAlarmSetup)) }
                )
            )
        }

        if viewState.isActionAvailable(.strapAlarmReadback) {
            rows.append(
                LooprMenuItem(
                    title: "Alarm status",
                    accessibilityIdentifier: "strap-alarm-status",
                    action: { onCommand(DeviceCommand(action: .strapAlarmReadback)) }
                )
            )
        }

        return rows
    }

    private var metricState: MetricState? {
        viewState.universalState.metricState
    }

    private func identityRows(for identity: DeviceIdentity) -> [HairlineMetricRow] {
        var rows = [
            HairlineMetricRow(
                id: "device-model",
                title: "Model",
                value: modelLabel ?? identity.generation.displayName,
                valueStyle: .caption
            )
        ]

        if let firmware = identity.firmwareVersion {
            rows.append(HairlineMetricRow(id: "device-firmware", title: "Firmware", value: firmware, valueStyle: .caption))
        }
        if let serial = identity.serialNumber {
            rows.append(HairlineMetricRow(id: "device-serial", title: "Serial number", value: serial, valueStyle: .caption))
        }
        if let betaStatus = identity.betaStatus {
            rows.append(HairlineMetricRow(id: "device-beta-status", title: "Beta status", value: betaStatus, valueStyle: .caption))
        }
        return rows
    }

    private func identityAccessibilityLabel(for identity: DeviceIdentity) -> String {
        var parts = [
            "Device \(identity.displayName ?? identity.modelName ?? "unknown")",
            modelLabel ?? identity.generation.displayName
        ]
        if let status = viewState.status {
            parts.append(viewState.batteryAccessibilityValue)
            if status.charging == true { parts.append("Charging") }
            if status.wristState == .notWorn { parts.append("Off wrist") }
            parts.append("Connection \(status.connection.displayName)")
        }
        return parts.joined(separator: ", ")
    }

    private func statusRows(for status: DeviceStatusSnapshot) -> [HairlineMetricRow] {
        var rows = [
            status.charging == true
                ? HairlineMetricRow(id: "device-status-forecast", title: "Battery forecast", value: "Paused while charging", valueStyle: .caption)
                : forecastRow(status.batteryForecast),
            HairlineMetricRow(
                id: "device-status-bluetooth",
                title: "Bluetooth",
                value: status.bluetooth.displayName,
                accent: status.bluetooth == .poweredOn ? .inkSecondary : .strain,
                valueStyle: .caption
            ),
            HairlineMetricRow(
                id: "device-status-wrist",
                title: "Wear status",
                value: status.wristState.displayName,
                valueStyle: .caption
            ),
            freshnessRow(status.freshness)
        ]

        if let lastPacketAt = status.lastPacketAt {
            rows.append(timestampRow(id: "device-status-last-packet", title: "Last packet", date: lastPacketAt))
        }
        if let historyCommitAt = status.historyCommitAt {
            rows.append(timestampRow(id: "device-status-history-commit", title: "History committed", date: historyCommitAt))
        }
        if let completedSyncAt = status.completedSyncAt {
            rows.append(timestampRow(id: "device-status-sync", title: "Sync completed", date: completedSyncAt))
        }
        if let storedAt = status.storedAt {
            rows.append(timestampRow(id: "device-status-stored", title: "Stored", date: storedAt))
        }
        return rows
    }

    private func batteryHeroValue(_ reading: MetricReading<Int>) -> String {
        switch reading {
        case .absent: MetricState.absent.title
        case .measured(let value): String(value)
        }
    }

    private func batteryHeroUnit(_ reading: MetricReading<Int>) -> String? {
        switch reading {
        case .absent: nil
        case .measured: "percent"
        }
    }

    private func batteryHeroAccent(_ reading: MetricReading<Int>) -> LooprColorToken {
        switch reading {
        case .absent: .inkSecondary
        case .measured: .brand
        }
    }

    private func forecastRow(_ reading: MetricReading<BatteryForecast>) -> HairlineMetricRow {
        switch reading {
        case .absent:
            HairlineMetricRow(
                id: "device-status-forecast",
                title: "Battery forecast",
                value: MetricState.absent.title,
                accent: .inkSecondary,
                valueStyle: .caption
            )
        case .measured(let forecast):
            HairlineMetricRow(
                id: "device-status-forecast",
                title: "Battery forecast",
                confidence: confidenceDescription(forecast.confidence),
                value: forecast.hoursRemaining.formatted(.number.precision(.fractionLength(1))),
                unit: "hours",
                accent: .inkSecondary,
                valueStyle: .caption
            )
        }
    }

    private func freshnessRow(_ reading: MetricReading<Date>) -> HairlineMetricRow {
        switch reading {
        case .absent:
            HairlineMetricRow(
                id: "device-status-freshness",
                title: "Freshness",
                value: MetricState.absent.title,
                accent: .inkSecondary,
                valueStyle: .caption
            )
        case .measured(let date):
            HairlineMetricRow(
                id: "device-status-freshness",
                title: "Freshness",
                value: date.formatted(date: .abbreviated, time: .shortened),
                valueStyle: .caption
            )
        }
    }

    private func timestampRow(id: String, title: String, date: Date) -> HairlineMetricRow {
        HairlineMetricRow(
            id: id,
            title: title,
            value: date.formatted(date: .abbreviated, time: .shortened),
            valueStyle: .caption
        )
    }

    @ViewBuilder
    private func capabilityRow(_ row: DeviceCapabilityRow) -> some View {
        HairlineMetricRow(
            id: "device-capability-\(row.action.rawValue)",
            title: row.action.displayName,
            value: row.presentationTitle,
            accent: capabilityAccent(for: row.status)
        )
    }

    private func capabilityAccent(for status: DeviceCapabilityStatus) -> LooprColorToken {
        switch status {
        case .supported, .unknown, .notInLoopr: .inkSecondary
        case .unsupported: .strain
        }
    }

    private func connectionAccent(_ connection: DeviceConnection) -> LooprColorToken {
        connection == .disconnected ? .strain : .brand
    }

    private func confidenceDescription(_ confidence: Confidence) -> String {
        switch confidence {
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .low: "Low confidence"
        }
    }


}

@available(macOS 13.0, iOS 17.0, *)
public struct FindMyStrapScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    public let feedback: FindMyStrapFeedback
    public let message: String?
    public let onFind: () -> Void

    public init(
        feedback: FindMyStrapFeedback,
        message: String? = nil,
        onFind: @escaping () -> Void
    ) {
        self.feedback = feedback
        self.message = message
        self.onFind = onFind
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Signal") {
                LooprSurface(emphasis: .hero(guidanceAccent)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        HStack(alignment: .top, spacing: LooprSpacing.sm) {
                            Image(systemName: guidanceSymbol)
                                .looprTypography(.title)
                                .foregroundStyle(Color.loopr(guidanceAccent))
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText("Signal guidance", style: .cardTitle)
                                guidanceDetail
                            }
                            .layoutPriority(1)

                            StatusChip(
                                guidanceLabel,
                                symbol: guidanceSymbol,
                                accent: guidanceAccent
                            )
                        }

                        LooprHairline()

                        HairlineMetricRow(
                            id: "find-my-strap-haptic",
                            title: "Haptic cue",
                            value: hapticText,
                            accent: feedback.haptic == .unavailable ? .strain : .brand
                        )
                    }
                }
            }

            LooprSectionGroup(title: "Actions") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprText(
                            "The strap buzzes twice. Keep it within Bluetooth range, because Loopr can only buzz a strap it is connected to.",
                            style: .prose,
                            color: .inkSecondary
                        )

                        if let message {
                            LooprInlineMessage(message, tone: .warning)
                        }

                        Button("Buzz the strap", action: onFind)
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("find-my-strap-scan")
                    }
                }
            }
        }
        .navigationTitle("Find my strap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("find-my-strap-screen")
    }

    private var guidanceText: String {
        switch feedback.guidance {
        case .warmer: "Signal is stronger than the last scan."
        case .colder: "Signal is weaker than the last scan."
        case .nearby: "Signal is steady near the strap."
        case .unavailable: "Loopr has no signal-strength reading for this strap, so it cannot tell you whether you are getting closer."
        }
    }

    @ViewBuilder
    private var guidanceDetail: some View {
        if feedback.guidance == .unavailable {
            LooprInlineMessage(guidanceText, tone: .warning)
        } else {
            LooprText(guidanceText, style: .prose, color: .inkSecondary)
        }
    }

    private var guidanceLabel: String {
        switch feedback.guidance {
        case .warmer: "Stronger signal"
        case .colder: "Weaker signal"
        case .nearby: "Nearby"
        case .unavailable: "Unavailable"
        }
    }

    private var guidanceSymbol: String {
        switch feedback.guidance {
        case .warmer: "location.north.line"
        case .colder: "location.south.line"
        case .nearby: "location.fill"
        case .unavailable: "location.slash"
        }
    }

    private var guidanceAccent: LooprColorToken {
        feedback.guidance == .unavailable ? .strain : .brand
    }

    private var hapticText: String {
        switch feedback.haptic {
        case .intensify: "Stronger pulse"
        case .soften: "Softer pulse"
        case .neutral: "Steady pulse"
        case .unavailable: "Unavailable"
        }
    }
}

@available(macOS 13.0, iOS 17.0, *)
public struct StrapAlarmSetupScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isEnabled: Bool
    @State private var startTime: Date?
    @State private var endTime: Date?
    @State private var weekdays: Set<AlarmWeekday>
    @State private var mode: StrapAlarmMode

    public let onTest: (() -> Void)?
    public let onSave: (StrapAlarmConfiguration) -> Void

    public init(
        configuration: StrapAlarmConfiguration? = nil,
        onTest: (() -> Void)? = nil,
        onSave: @escaping (StrapAlarmConfiguration) -> Void
    ) {
        self.onTest = onTest
        self.onSave = onSave
        _isEnabled = State(initialValue: configuration?.isEnabled ?? false)
        _startTime = State(initialValue: Self.date(for: configuration?.startMinute))
        _endTime = State(initialValue: Self.date(for: configuration?.endMinute))
        _weekdays = State(initialValue: configuration?.weekdays ?? [])
        _mode = State(initialValue: configuration?.mode ?? .exactTime)
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "How you want to wake") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        Picker("How you want to wake", selection: $mode) {
                            Text("At a set time").tag(StrapAlarmMode.exactTime)
                            Text("In a window").tag(StrapAlarmMode.wakeWindow)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("strap-alarm-mode")

                        LooprText(modeExplanation, style: .prose, color: .inkSecondary)
                    }
                }
            }

            LooprSectionGroup(title: "Schedule") {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        LooprToggleRow(
                            title: "Strap alarm enabled",
                            subtitle: "Use the strap alarm on the selected days.",
                            isOn: $isEnabled
                        )

                        LooprHairline()

                        timeRow(title: startRowTitle, selection: $startTime)

                        LooprHairline()

                        timeRow(title: endRowTitle, selection: $endTime)
                    }
                }
            }

            LooprSectionGroup(title: "Weekdays") {
                LooprFormCard(padding: LooprSpacing.none) {
                    HStack(spacing: LooprSpacing.xxs) {
                        ForEach(AlarmWeekday.allCases, id: \.self) { day in
                            weekdayButton(for: day)
                        }
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                }
            }

            LooprSectionGroup(title: "Save") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprText(
                            "Choose your times and at least one weekday.",
                            style: .prose,
                            color: .inkSecondary
                        )

                        if let validationMessage {
                            LooprInlineMessage(validationMessage, tone: .warning)
                        }

                        Button("Save strap alarm setup") {
                            guard validationMessage == nil else { return }
                            onSave(StrapAlarmConfiguration(
                                isEnabled: isEnabled,
                                startMinute: startTime.map(Self.minute(from:)),
                                endMinute: endTime.map(Self.minute(from:)),
                                weekdays: weekdays,
                                mode: mode
                            ))
                        }
                        .buttonStyle(LooprPrimaryButtonStyle())
                        .accessibilityIdentifier("strap-alarm-save")

                        if let onTest {
                            Button("Test alarm", action: onTest)
                                .buttonStyle(LooprButtonStyle(prominent: false))
                                .accessibilityIdentifier("strap-alarm-test")
                        }
                    }
                }
            }
        }
        .navigationTitle("Strap alarm setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("strap-alarm-setup-screen")
    }

    @ViewBuilder
    private func timeRow(title: String, selection: Binding<Date?>) -> some View {
        if selection.wrappedValue == nil {
            Button {
                selection.wrappedValue = Date()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    LooprText(title, style: .settingsRow)
                    Spacer(minLength: LooprSpacing.sm)
                    LooprText(MetricState.absent.title, style: .metricUnit, color: .inkMuted)
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            DatePicker(
                title,
                selection: Binding(
                    get: { selection.wrappedValue ?? Date() },
                    set: { selection.wrappedValue = $0 }
                ),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.compact)
            .looprTypography(.settingsRow)
            .foregroundStyle(Color.loopr(.ink))
            .tint(Color.loopr(.brand))
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        }
    }

    private func weekdayButton(for day: AlarmWeekday) -> some View {
        let isSelected = weekdays.contains(day)

        return Button {
            withAnimation(.snappy(duration: LooprMotion.fast)) {
                if isSelected {
                    weekdays.remove(day)
                } else {
                    weekdays.insert(day)
                }
            }
        } label: {
            Text(day.shortTitle)
                .looprTypography(.metricUnit)
                .foregroundStyle(Color.loopr(isSelected ? .background : .inkSecondary))
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
                .background(
                    Color.loopr(isSelected ? .brand : .surfaceElevated),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.loopr(.surfaceStroke), lineWidth: LooprSpacing.hairline)
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(.looprPressableCard)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityLabel(day.rawValue.capitalized)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var modeExplanation: String {
        switch mode {
        case .exactTime:
            "Your band buzzes at the time you set, and your iPhone rings at the same moment as a backup."
        case .wakeWindow:
            "Loopr wakes you in the lightest sleep it can find inside the window. "
                + "You are always awake by the end of it: the band alarm and the iPhone alarm are both set for that time."
        }
    }

    private var startRowTitle: String {
        mode == .wakeWindow ? "Earliest" : "Alarm time"
    }

    private var endRowTitle: String {
        mode == .wakeWindow ? "Latest" : "Stop buzzing at"
    }

    private var validationMessage: String? {
        guard isEnabled else { return nil }
        guard startTime != nil, endTime != nil else {
            return mode == .wakeWindow
                ? "Choose the earliest and latest time you want to be woken."
                : "Choose an alarm time and when it should stop."
        }
        guard !weekdays.isEmpty else {
            return "Select at least one weekday."
        }
        return nil
    }

    private static func date(for minute: Int?) -> Date? {
        guard let minute, (0..<1_440).contains(minute) else { return nil }
        var calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minute, to: startOfDay)
    }

    private static func minute(from date: Date) -> Int {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

/// What the band reports when Loopr asks it for its current alarm.
public enum StrapAlarmStatusReading: Equatable, Sendable {
    case loading
    case armed(Date)
    case noAlarmReported
    case failed(String)
}

/// Everything Loopr knows about whether this person will actually be woken.
///
/// Three things can wake them and each one can fail on its own, so the screen
/// states them separately rather than showing a single green tick. The copy
/// never says "confirmed" unless the band said so.
public struct StrapAlarmAssurance: Equatable, Sendable {
    public enum BandState: Equatable, Sendable {
        /// No alarm is set, so there is nothing to confirm.
        case off
        /// The band answered event 56, or read back the time Loopr wrote.
        case confirmed
        /// Loopr wrote the alarm and is still waiting for the band to answer.
        case waiting
        /// Loopr wrote the alarm, the wait elapsed, and the band never agreed.
        case unconfirmed
        /// The write itself failed, so the band is holding nothing.
        case notArmed
    }

    public enum PhoneBackup: Equatable, Sendable {
        case systemAlarm
        case notification
        case unavailable(String)
    }

    public let band: BandState
    public let fireDate: Date?
    public let lastReadbackAt: Date?
    public let phoneBackup: PhoneBackup
    /// Set when the alarm is a wake window, so the screen can say Loopr may
    /// wake this person earlier than the time on display.
    public let windowStart: Date?

    public init(
        band: BandState,
        fireDate: Date? = nil,
        lastReadbackAt: Date? = nil,
        phoneBackup: PhoneBackup = .unavailable("Loopr has no backup alarm on this iPhone."),
        windowStart: Date? = nil
    ) {
        self.band = band
        self.fireDate = fireDate
        self.lastReadbackAt = lastReadbackAt
        self.phoneBackup = phoneBackup
        self.windowStart = windowStart
    }

    public var headline: String {
        switch band {
        case .off: "No alarm set"
        case .confirmed: "Set on your band and confirmed"
        case .waiting: "Set on your band, waiting for it to confirm"
        case .unconfirmed: "Your band did not confirm the alarm"
        case .notArmed: "Loopr could not set the alarm on your band"
        }
    }

    public var detail: String {
        switch band {
        case .off:
            return "Turn the alarm on and pick the days you want it."
        case .confirmed:
            return "\(timeLine) \(phoneLine)"
        case .waiting:
            return "Loopr wrote the alarm and is waiting for your band to answer. \(phoneLine)"
        case .unconfirmed:
            return "Loopr wrote the alarm but your band never said it took it. \(phoneLine)"
        case .notArmed:
            return "The write did not reach your band. \(phoneLine)"
        }
    }

    private var timeLine: String {
        guard let fireDate else { return "Your band will buzz at the time you set." }
        let time = fireDate.formatted(date: .abbreviated, time: .shortened)
        guard let windowStart else { return "Your band will buzz at \(time)." }
        return "Your band will buzz by \(time), or earlier from "
            + "\(windowStart.formatted(date: .omitted, time: .shortened)) if Loopr sees you surfacing."
    }

    private var phoneLine: String {
        switch phoneBackup {
        case .systemAlarm:
            "Your iPhone will ring at the same time as a backup. It breaks through silent mode and Focus."
        case .notification:
            "Your iPhone will alert you at the same time as a backup. That alert is a notification, "
                + "so the ring switch can quiet it."
        case .unavailable(let reason):
            reason
        }
    }
}

@available(macOS 13.0, iOS 17.0, *)
public struct StrapAlarmStatusScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    public let reading: StrapAlarmStatusReading
    public let savedFireDate: Date?
    public let assurance: StrapAlarmAssurance?
    public let onRefresh: () -> Void

    public init(
        reading: StrapAlarmStatusReading,
        savedFireDate: Date? = nil,
        assurance: StrapAlarmAssurance? = nil,
        onRefresh: @escaping () -> Void
    ) {
        self.reading = reading
        self.savedFireDate = savedFireDate
        self.assurance = assurance
        self.onRefresh = onRefresh
    }

    public var body: some View {
        LooprDetailScaffold {
            if let assurance {
                LooprSectionGroup(title: "Will you be woken") {
                    LooprSurface(emphasis: .hero(assuranceAccent(assurance))) {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText(assurance.headline, style: .cardTitle)
                            LooprText(assurance.detail, style: .prose, color: .inkSecondary)
                        }
                    }
                    .accessibilityIdentifier("strap-alarm-assurance")
                }
            }

            LooprSectionGroup(title: "On the strap") {
                LooprSurface(emphasis: .hero(accent)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprText(headline, style: .cardTitle)
                        LooprText(detail, style: .prose, color: .inkSecondary)
                    }
                }
            }

            LooprSectionGroup(title: "In Loopr") {
                HairlineMetricList(rows: [
                    HairlineMetricRow(
                        id: "strap-alarm-saved",
                        title: "Next alarm Loopr set",
                        value: savedFireDate?.formatted(date: .abbreviated, time: .shortened)
                            ?? MetricState.absent.title,
                        accent: savedFireDate == nil ? .inkSecondary : .brand
                    ),
                    HairlineMetricRow(
                        id: "strap-alarm-readback",
                        title: "Last answer from your strap",
                        value: assurance?.lastReadbackAt?.formatted(date: .omitted, time: .shortened)
                            ?? MetricState.absent.title,
                        accent: assurance?.lastReadbackAt == nil ? .inkSecondary : .brand
                    )
                ])
            }

            LooprSectionGroup(title: "Actions") {
                Button("Ask the strap again", action: onRefresh)
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("strap-alarm-status-refresh")
            }
        }
        .navigationTitle("Alarm status")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("strap-alarm-status-screen")
    }

    private var headline: String {
        switch reading {
        case .loading: "Asking the strap"
        case .armed: "Alarm armed"
        case .noAlarmReported: "No alarm reported"
        case .failed: "Could not read the alarm"
        }
    }

    private var detail: String {
        switch reading {
        case .loading:
            "Reading the alarm the strap is holding."
        case .armed(let date):
            "The strap says it will buzz at \(date.formatted(date: .abbreviated, time: .shortened))."
        case .noAlarmReported:
            // Per the protocol notes, the readback is unconfirmed on WHOOP 4
            // firmware, so an empty answer is not proof the alarm is gone.
            "The strap did not report an alarm. If Loopr shows one below, that is still the alarm it wrote."
        case .failed(let reason):
            reason
        }
    }

    private var accent: LooprColorToken {
        switch reading {
        case .armed: .brand
        case .loading, .noAlarmReported: .inkSecondary
        case .failed: .strain
        }
    }

    private func assuranceAccent(_ assurance: StrapAlarmAssurance) -> LooprColorToken {
        switch assurance.band {
        case .confirmed: .brand
        case .off, .waiting: .inkSecondary
        case .unconfirmed, .notArmed: .strain
        }
    }
}

private extension AlarmWeekday {
    var shortTitle: String {
        switch self {
        case .sunday: "Su"
        case .monday: "Mo"
        case .tuesday: "Tu"
        case .wednesday: "We"
        case .thursday: "Th"
        case .friday: "Fr"
        case .saturday: "Sa"
        }
    }
}

@available(macOS 13.0, iOS 17.0, *)
public struct GestureMappingScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    public let mappings: [DeviceGestureMapping]
    /// The actions a double tap may run. Empty keeps the screen read-only,
    /// which is what the fixture composition wants.
    public let options: [DeviceAction]
    public let selectedAction: DeviceAction?
    public let onSelect: ((DeviceAction?) -> Void)?

    public init(mappings: [DeviceGestureMapping]) {
        self.mappings = mappings
        self.options = []
        self.selectedAction = nil
        self.onSelect = nil
    }

    public init(
        selectedAction: DeviceAction?,
        options: [DeviceAction],
        onSelect: @escaping (DeviceAction?) -> Void
    ) {
        self.mappings = [DeviceGestureMapping(gesture: .doubleTap, action: selectedAction)]
        self.options = options
        self.selectedAction = selectedAction
        self.onSelect = onSelect
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Gestures") {
                if mappings.isEmpty {
                    LooprSurface {
                        StateMessage(.noRecords)
                    }
                } else {
                    HairlineMetricList(
                        rows: mappings.map { mapping in
                            HairlineMetricRow(
                                id: "gesture-mapping-\(mapping.gesture.rawValue)",
                                title: mapping.gesture.displayName,
                                value: mapping.action?.displayName ?? "Not mapped",
                                accent: mapping.action == nil ? .inkSecondary : .brand
                            )
                        }
                    )
                }
            }

            if let onSelect, !options.isEmpty {
                LooprSectionGroup(title: "Double tap") {
                    LooprFormCard(padding: LooprSpacing.none) {
                        VStack(spacing: LooprSpacing.none) {
                            choiceRow(title: "Nothing", action: nil, onSelect: onSelect)

                            ForEach(options, id: \.self) { option in
                                LooprHairline()
                                choiceRow(title: option.displayName, action: option, onSelect: onSelect)
                            }
                        }
                    }
                }

                LooprSectionGroup(title: "How it works") {
                    LooprFormCard {
                        LooprText(
                            "Tap the strap twice while Loopr is open. The strap sends the tap and this iPhone runs the action.",
                            style: .prose,
                            color: .inkSecondary
                        )
                    }
                }
            }
        }
        .navigationTitle(onSelect == nil ? "Supported gestures" : "Gesture controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("gesture-mapping-screen")
    }

    @ViewBuilder
    private func choiceRow(
        title: String,
        action: DeviceAction?,
        onSelect: @escaping (DeviceAction?) -> Void
    ) -> some View {
        let isSelected = selectedAction == action

        Button {
            onSelect(action)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                LooprText(title, style: .settingsRow)
                Spacer(minLength: LooprSpacing.sm)
                if isSelected {
                    Image(systemName: "checkmark")
                        .looprTypography(.metricUnit)
                        .foregroundStyle(Color.loopr(.brand))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .sensoryFeedback(.selection, trigger: isSelected) { _, selected in selected }
        .accessibilityIdentifier("gesture-option-\(action?.rawValue ?? "none")")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension DeviceCenterUniversalState {
    var metricState: MetricState? {
        switch self {
        case .ready: nil
        case .loading: .loading
        case .noRecordsYet: .noRecords
        case .absentMetric: .absent
        case .measuredZero: .measuredZero
        case .partialData: .partial
        case .lowConfidence: .lowConfidence
        case .settlingOrRecomputing: .settling
        case .stale: .stale
        case .disconnected: .disconnected
        case .bluetoothOff: .bluetoothOff
        case .permissionDenied: .permissionDenied
        case .unsupportedHardware: .unsupportedHardware
        case .recoverableError: .recoverableError
        case .destructiveOrMigrationFailure: .destructiveFailure
        }
    }
}

private extension MetricState {
    var accent: LooprColorToken {
        switch self {
        case .recoverableError, .lowConfidence, .partial, .stale, .disconnected,
             .bluetoothOff, .permissionDenied, .unsupportedHardware:
            .strain
        case .destructiveFailure:
            .critical
        default:
            .brand
        }
    }

    var messageTone: ChipTone {
        switch self {
        case .destructiveFailure: .critical
        case .partial, .lowConfidence, .stale, .disconnected, .bluetoothOff,
             .permissionDenied, .unsupportedHardware, .recoverableError: .warning
        default: .neutral
        }
    }
}
#endif
