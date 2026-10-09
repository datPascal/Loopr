import DesignSystem
import DeviceCenterKit
import SleepKit
import SwiftUI

/// SwiftUI restarts the screen's polling task when this value changes. A save
/// moves a connected band from off to waiting, so the old 15-second sleep
/// must end before the first confirmation check.
struct WakeAlarmPollingCadence: Equatable {
    let isWaiting: Bool

    init(band: WakeAlarmBandLayer?) {
        isWaiting = band == .waiting
    }

    var interval: Duration { isWaiting ? .seconds(2) : .seconds(15) }
}

/// The wake alarm screen, reachable from the Today card, the Sleep card,
/// Settings, and Band settings.
@MainActor
struct WakeAlarmFeatureRoot: View {
    let repositories: ProductRepositoryContainer?
    var suggestion: WakeAlarmSuggestion?

    @State private var controller: (any WakeAlarmControlling)?
    @State private var didResolve = false
    @State private var snapshot: WakeAlarmSnapshot?
    @State private var isBusy = false
    @State private var message: String?
    @State private var isPhoneOffConfirmationPresented = false

    init(repositories: ProductRepositoryContainer?, suggestion: WakeAlarmSuggestion? = nil) {
        self.repositories = repositories
        self.suggestion = suggestion
    }

    var body: some View {
        content
            .task(id: WakeAlarmPollingCadence(band: snapshot?.band)) {
                if !didResolve {
                    controller = WakeAlarmControllerFactory.make(repositories: repositories)
                    didResolve = true
                }
                await refresh()
                // Event 56 arrives on the band's own schedule, so the layer
                // status is re-read while the screen is open: quickly while
                // Loopr waits for the band, slowly otherwise.
                while !Task.isCancelled {
                    let cadence = WakeAlarmPollingCadence(band: snapshot?.band)
                    do { try await Task.sleep(for: cadence.interval) } catch { return }
                    await refresh()
                }
            }
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                message = nil
            }
            .confirmationDialog(
                "Turn off the phone alarm?",
                isPresented: $isPhoneOffConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Turn off phone alarm", role: .destructive) { setPhoneLayer(false) }
                Button("Keep it on", role: .cancel) {}
            } message: {
                Text("Only your band will wake you. It has accepted alarms before and not buzzed.")
            }
            .productStorageGate(repositories)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot, let controller {
            WakeAlarmScreen(
                model: snapshot.screenModel(suggestion: suggestion),
                isBusy: isBusy,
                message: message,
                actions: actions(controller)
            )
        } else if didResolve, controller == nil {
            ContentUnavailableView {
                Label("Wake alarm unavailable", systemImage: "alarm")
            } description: {
                Text("Loopr could not open the store that holds your alarm. Close Loopr and open it again.")
            }
            .accessibilityIdentifier("wake-alarm-screen")
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.loopr(.background).ignoresSafeArea())
                .accessibilityIdentifier("wake-alarm-screen")
        }
    }

    private func actions(_ controller: any WakeAlarmControlling) -> WakeAlarmScreenActions {
        WakeAlarmScreenActions(
            save: { plan in
                run(controller) {
                    try await controller.save(plan)
                    return "Alarm saved."
                }
            },
            turnOff: {
                run(controller) {
                    try await controller.turnOff()
                    return "Alarm off. Nothing will ring."
                }
            },
            retryBand: {
                run(controller) {
                    try await controller.retryBand()
                    return "Sending the alarm to your band again."
                }
            },
            testBuzz: {
                run(controller) {
                    try await controller.testBuzz()
                    return "Test sent. Your band should buzz now."
                }
            },
            setPhoneLayer: { enabled in
                if enabled {
                    setPhoneLayer(true)
                } else {
                    isPhoneOffConfirmationPresented = true
                }
            }
        )
    }

    private func setPhoneLayer(_ enabled: Bool) {
        guard let controller else { return }
        run(controller) {
            await controller.setPhoneLayerEnabled(enabled)
            return enabled ? "Phone alarm on." : "Phone alarm off. Only your band will wake you."
        }
    }

    private func run(_ controller: any WakeAlarmControlling, _ work: @escaping @MainActor () async throws -> String) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            do {
                message = try await work()
            } catch {
                message = BandActionCopy.readable(error)
            }
            await refresh()
            isBusy = false
        }
    }

    private func refresh() async {
        guard let controller else { return }
        snapshot = await controller.snapshot()
    }
}

/// The compact wake alarm card for Today and Sleep.
@MainActor
struct WakeAlarmCardFeatureRoot: View {
    let repositories: ProductRepositoryContainer?
    var suggestion: WakeAlarmSuggestion?
    let accessibilityIdentifier: String
    let open: () -> Void

    @State private var controller: (any WakeAlarmControlling)?
    @State private var didResolve = false
    @State private var snapshot: WakeAlarmSnapshot?

    var body: some View {
        Group {
            if didResolve, controller == nil {
                // No alarm store, so there is nothing to show or set.
                EmptyView()
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    WakeAlarmCard(
                        state: snapshot?.cardState(
                            suggestion: suggestion,
                            now: context.date,
                            formatter: WakeAlarmFormatter()
                        ) ?? .loading,
                        accessibilityIdentifier: accessibilityIdentifier,
                        action: open
                    )
                }
            }
        }
        // Runs on every appearance, so coming back from the alarm screen
        // shows what was just saved.
        .task {
            if !didResolve {
                controller = WakeAlarmControllerFactory.make(repositories: repositories)
                didResolve = true
            }
            guard let controller else { return }
            snapshot = await controller.snapshot()
        }
    }
}

extension WakeAlarmSuggestion {
    /// Sleep publishes its suggestion as a local clock label.
    init?(_ suggestion: SleepSuggestedAlarm?) {
        guard let suggestion else { return nil }
        self.init(localTime: suggestion.localTime, reason: suggestion.reason)
    }
}
