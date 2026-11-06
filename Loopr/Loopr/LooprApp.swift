//
//  LooprApp.swift
//  Loopr
//
//  Created by Pascal Lindenau on 06.08.26.
//

import DesignSystem
import NotificationKit
import SwiftUI

@main
struct LooprApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(LooprApplicationDelegate.self)
    private var applicationDelegate

    private let environment = AppEnvironment.make()
    @StateObject private var bluetoothModel: BluetoothApplicationModel

    init() {
        // The model is built here rather than lazily inside the StateObject
        // autoclosure so the application delegate can find it during a
        // background relaunch for the band, when no scene is ever connected.
        LooprNavigationAppearance.apply()
        // The appearance Settings stored, before the first frame, so a dark choice never opens on a light frame.
        LooprLaunchAppearance.applyRemembered(composition: environment.composition)
        let model = BluetoothApplicationModel.production()
        LooprLaunchBootstrap.shared.register(model)
        if environment.composition == .production {
            // Only a link that is still down after the grace window counts.
            // A reconnect that takes a second used to post "Strap update".
            model.bandLink.onDisconnected = { [weak model] in
                let targetID = model?.provisionedIdentifier?.uuidString ?? "paired-strap"
                Task {
                    await LooprNotificationRuntime.shared.deviceStateChanged(family: .disconnect, targetID: targetID)
                }
            }
        }
        _bluetoothModel = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if LooprNativeSurfaceCandidateMode.isEnabled {
                    LooprNativeSurfaceCandidateRoot()
                } else {
                    productRoot
                }
                #else
                productRoot
                #endif
            }
            #if DEBUG
            .hidingStatusBarForVisualCapture()
            #endif
            .onChange(of: scenePhase, initial: true) { _, phase in
                applicationDelegate.scenePhaseChanged(phase)
            }
        }
    }

    private var productRoot: some View {
            RootGate(environment: environment, bluetoothModel: bluetoothModel)
                .onOpenURL { url in
                    // A protocol file from the share sheet or Files goes to the file inbox and opens the Protocol tab.
                    if RoutineFileInbox.shared.receive(url), let protocolTab = URL(string: "loopr://protocol") {
                        LooprQuickActions.shared.receive(url: protocolTab)
                    } else {
                        LooprQuickActions.shared.receive(url: url)
                    }
                }
                .environmentObject(bluetoothModel)
                .environment(\.looprBluetoothModel, bluetoothModel)
                .environment(\.looprBandLink, bluetoothModel.bandLink)
                .environment(\.metricHistoryProvider, LooprMetricHistory.shared)
                .task {
                    applicationDelegate.configure(model: bluetoothModel)
                    LooprWatchSnapshotBridge.shared.activateIfNeeded()
                    await bluetoothModel.inspectProvisioningOnLaunch()
                    #if DEBUG
                    await LooprNativeSurfaceProbe.startIfRequested()
                    #endif
                }
    }
}

#if DEBUG
private extension View {
    /// Only captures force the status bar off. An unconditional
    /// `statusBarHidden(false)` here would override screens that hide it
    /// themselves, such as the band intro.
    @ViewBuilder
    func hidingStatusBarForVisualCapture() -> some View {
        if ProcessInfo.processInfo.arguments.contains("--loopr-visual-capture") {
            statusBarHidden(true)
        } else {
            self
        }
    }
}
#endif
