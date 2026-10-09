import SwiftUI
import UIKit
import DesignSystem
import HealthKitBridge

struct AppleHealthSettingsScreen: View {
    let runtime: LooprHealthSyncRuntime?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var status = LooprHealthSyncStatus()
    @State private var loaded = false
    @State private var changingPreference = false
    @State private var requestingPermission = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprSectionGroup(title: "Apple Health") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            Toggle("Sync with Apple Health", isOn: Binding(
                                get: { status.enabled },
                                set: { changeMaster($0) }
                            ))
                            .frame(minHeight: 56)
                            .tint(Color.loopr(.brand))
                            .disabled(!loaded || runtime == nil || changingPreference)
                            .accessibilityIdentifier("settings-health-sync-enabled")
                            LooprText("Choose what Loopr reads and saves below.", style: .prose, color: .inkSecondary)
                            LooprText("Turning sync off leaves data already in Apple Health in place.", style: .caption, color: .inkSecondary)
                        }
                    }
                }
                LooprSectionGroup(title: "Access") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText(connectionTitle, style: .rowTitle)
                                .accessibilityIdentifier("settings-health-sync-status")
                            if status.unavailable || runtime == nil {
                                LooprText("Apple Health is unavailable in this session.", style: .prose, color: .inkSecondary)
                            } else if !status.undetermined.isEmpty || status.readPermissionNeeded {
                                Button(requestingPermission ? "Waiting for permission…" : "Connect Apple Health") {
                                    guard let runtime else { return }
                                    requestingPermission = true
                                    Task {
                                        await runtime.requestPermission()
                                        requestingPermission = false
                                        await refresh()
                                        await runtime.synchronizeNow()
                                        await refresh()
                                    }
                                }
                                .buttonStyle(LooprPrimaryButtonStyle())
                                .disabled(!loaded || !status.enabled || requestingPermission)
                                .accessibilityIdentifier("settings-healthKit-request-permission")
                            }
                            Button {
                                AppleHealthAccessLink.open()
                            } label: {
                                HStack(spacing: LooprSpacing.sm) {
                                    LooprText("Manage access in the Health app", style: .rowTitle)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .accessibilityHidden(true)
                                }
                                .frame(minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings-health-manage-access")
                            LooprText("Change system permission in the Health app. The switches below control what Loopr uses.", style: .caption, color: .inkSecondary)
                        }
                    }
                }
                LooprSectionGroup(title: "Read from Apple Health") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.none) {
                            ForEach(HealthHistoryQuantity.allCases, id: \.self) { quantity in
                                Toggle(quantity.healthDisplayName, isOn: Binding(
                                    get: { !status.disabledRead.contains(quantity) },
                                    set: { changeRead($0, quantity: quantity) }
                                ))
                                .frame(minHeight: 56)
                                .accessibilityIdentifier("settings-health-read-\(quantity.rawValue)")
                            }
                            Toggle("Sleep", isOn: Binding(
                                get: { status.sleepReadEnabled },
                                set: { changeRead($0, quantity: nil) }
                            ))
                            .frame(minHeight: 56)
                            .accessibilityIdentifier("settings-health-read-sleep")
                        }
                        .tint(Color.loopr(.brand))
                        .disabled(!loaded || runtime == nil || !status.enabled || changingPreference)
                    }
                }
                LooprSectionGroup(title: "Save to Apple Health") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.none) {
                            ForEach(LooprHealthSyncRuntime.metrics.sorted { $0.rawValue < $1.rawValue }, id: \.self) { metric in
                                Toggle(metric.healthDisplayName, isOn: Binding(
                                    get: { !status.disabledWrite.contains(metric) },
                                    set: { changeWrite($0, metric: metric) }
                                ))
                                .frame(minHeight: 56)
                                .accessibilityIdentifier("settings-health-write-\(metric.rawValue)")
                            }
                            LooprText("Loopr saves estimates only when enough reliable data is available.", style: .caption, color: .inkSecondary)
                        }
                        .tint(Color.loopr(.brand))
                        .disabled(!loaded || runtime == nil || !status.enabled || changingPreference)
                    }
                }
                if loaded && runtime != nil && !status.unavailable {
                    LooprSectionGroup(title: "Sync") {
                        LooprFormCard {
                            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                                LooprText("Available history syncs when you connect. New data syncs while Loopr is running.", style: .prose, color: .inkSecondary)
                                if status.syncing {
                                    ProgressView("Saving to Apple Health…")
                                } else if let lastSync = status.lastSync {
                                    Text("Last saved \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                                        .looprTypography(.caption)
                                } else {
                                    LooprText("No data saved yet.", style: .caption, color: .inkSecondary)
                                }
                                if status.pendingCount > 0 {
                                    LooprText("\(status.pendingCount) updates waiting to sync.", style: .caption, color: .inkSecondary)
                                }
                                if status.enabled && hasActiveCategory
                                    && (!status.allowed.isEmpty || (status.undetermined.isEmpty && !status.readPermissionNeeded)) {
                                    Button("Sync now") {
                                        guard let runtime else { return }
                                        status.syncing = true
                                        Task {
                                            await LooprMetricHistory.shared.appleHealthConnected()
                                            await runtime.synchronizeNow()
                                            await refresh()
                                        }
                                    }
                                    .buttonStyle(LooprButtonStyle(prominent: false))
                                    .disabled(status.syncing || requestingPermission)
                                    .accessibilityIdentifier("settings-health-sync-now")
                                }
                                if let error = actionError ?? status.error {
                                    LooprInlineMessage("Apple Health sync could not finish: \(error)", tone: .warning)
                                }
                            }
                        }
                    }
                }
            }
            .padding(LooprSpacing.screenGutter)
        }
        .background(Color.loopr(.background))
        .foregroundStyle(Color.loopr(.ink))
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("settings-destination-healthKit")
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                await refresh()
            }
        }
    }

    private var connectionTitle: String {
        if !loaded { return "Checking Apple Health…" }
        if !status.enabled { return "Syncing is off" }
        if status.unavailable || runtime == nil { return "Unavailable" }
        if status.allowed.isEmpty { return "Permission needed" }
        return "Connected to Apple Health"
    }

    private var hasActiveCategory: Bool {
        !status.allowed.subtracting(status.disabledWrite).isEmpty
            || status.sleepReadEnabled
            || HealthHistoryQuantity.allCases.contains { !status.disabledRead.contains($0) }
    }

    private func changeMaster(_ enabled: Bool) {
        guard let runtime else { return }
        change {
            try await runtime.setEnabled(enabled)
            if enabled {
                await LooprMetricHistory.shared.appleHealthConnected()
                await runtime.synchronizeNow()
            }
        }
    }

    private func changeRead(_ enabled: Bool, quantity: HealthHistoryQuantity?) {
        guard let runtime else { return }
        change { try await runtime.setReadEnabled(enabled, for: quantity) }
    }

    private func changeWrite(_ enabled: Bool, metric: ExportMetricKind) {
        guard let runtime else { return }
        change {
            try await runtime.setWriteEnabled(enabled, for: metric)
            if enabled { await runtime.synchronizeNow() }
        }
    }

    private func change(_ operation: @escaping () async throws -> Void) {
        changingPreference = true
        Task {
            do { try await operation(); actionError = nil }
            catch { actionError = error.localizedDescription }
            await refresh()
            changingPreference = false
        }
    }

    private func refresh() async {
        if let runtime { status = await runtime.status() }
        loaded = true
    }
}

nonisolated enum AppleHealthAccessLink {
    static let healthURL = URL(string: "x-apple-health://")!

    static func destination(canOpenHealthURL: Bool) -> URL {
        canOpenHealthURL ? healthURL : URL(string: UIApplication.openSettingsURLString)!
    }

    @MainActor static func open() {
        open(application: .shared)
    }

    @MainActor static func open(application: UIApplication) {
        open(canOpen: { application.canOpenURL($0) }, open: { application.open($0) })
    }

    @MainActor static func open(canOpen: (URL) -> Bool, open: (URL) -> Void) {
        open(destination(canOpenHealthURL: canOpen(healthURL)))
    }
}

private extension HealthHistoryQuantity {
    var healthDisplayName: String {
        switch self {
        case .heartRate: "Heart rate"
        case .restingHeartRate: "Resting heart rate"
        case .heartRateVariabilitySDNN: "HRV, SDNN"
        case .respiratoryRate: "Respiratory rate"
        case .oxygenSaturation: "Blood oxygen"
        case .vo2Max: "VO₂ max"
        case .steps: "Steps"
        case .activeEnergy: "Active energy"
        }
    }
}

private extension ExportMetricKind {
    var healthDisplayName: String {
        switch self {
        case .heartRate: "Heart rate"
        case .restingHeartRate: "Resting heart rate"
        case .heartRateVariabilitySDNN: "HRV, SDNN"
        case .respiratoryRate: "Respiratory rate"
        case .sleepStages: "Sleep"
        case .steps: "Estimated steps"
        case .activeEnergy: "Active energy"
        case .completedWorkout: "Workouts"
        }
    }
}
