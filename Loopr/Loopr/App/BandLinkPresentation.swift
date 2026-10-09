import DesignSystem
import Foundation
import Observation

/// What every screen shows about the band, after the grace window.
///
/// The raw Bluetooth status changes six to ten times on a reconnect that takes
/// a second. Screens used to react to each step: Heart said "Band not
/// connected", Settings said "Not connected", the live stream restarted, and
/// only Today had its own grace window. This is the one debounced answer they
/// all read instead.
nonisolated enum BandLinkState: Equatable, Sendable {
    /// Linked and idle.
    case connected
    /// Linked and offloading history.
    case syncing
    /// Not linked yet, inside the grace window. Shown quietly: nothing on
    /// screen changes for a link that comes back within it.
    case reconnecting
    /// Still not linked once the grace window closed.
    case disconnected
    case bluetoothOff
    case notPaired
    /// Something the person has to fix. The message is user copy.
    case needsAttention(String)

    var indicatorLink: LooprBandIndicator.Link {
        switch self {
        case .connected: .connected
        case .syncing: .syncing
        case .reconnecting: .reconnecting
        case .disconnected: .disconnected
        case .bluetoothOff: .bluetoothOff
        case .notPaired: .notPaired
        case .needsAttention: .needsAttention
        }
    }

    /// Linked, or close enough that the surface should not say otherwise.
    var isConnectedOrQuiet: Bool {
        switch self {
        case .connected, .syncing, .reconnecting: true
        default: false
        }
    }

    var isLinked: Bool { self == .connected || self == .syncing }
}

/// The pure part: raw status in, debounced state out. Kept separate from the
/// observable class so the grace rules can be tested with explicit times.
nonisolated struct BandLinkHysteresis: Sendable {
    /// How long a known band may take to answer before it is reported as
    /// disconnected.
    let grace: TimeInterval
    /// When the current not-linked stretch began. Nil while linked or while
    /// the answer is already final (Bluetooth off, not paired).
    private(set) var downSince: Date?
    /// Whether the band has been linked since it was paired. Lets the live
    /// card and the Settings row tell a blip from a cold start.
    private(set) var hasBeenLinked = false

    init(grace: TimeInterval) {
        self.grace = grace
    }

    /// The raw status reduced to what the hysteresis needs.
    enum Signal: Equatable, Sendable {
        case linked(syncing: Bool)
        /// Coming up or dropped. Starts the grace clock.
        case down
        /// A transition the app itself is running, such as launch inspection
        /// or removing a pairing. Quiet, and it does not run the clock.
        case settling
        case bluetoothOff
        case notPaired
        case attention(String)
    }

    static func signal(for status: BluetoothApplicationStatus, isPaired: Bool, isSyncing: Bool) -> Signal {
        switch status {
        case .connected:
            return .linked(syncing: isSyncing)
        case .checkingProvisioning, .removing:
            return .settling
        case .needsPairing, .removed:
            return .notPaired
        case .explanationRequired, .pickerPresented, .cancelled:
            return isPaired ? .down : .notPaired
        case .preparing, .retrieving, .scanning, .connecting, .discovering, .subscribing:
            return .down
        case .disconnected(_, let reason):
            if reason == BluetoothApplicationModel.experimentalSupportOffReason {
                return .attention(reason)
            }
            return isPaired ? .down : .notPaired
        case .bluetoothOff:
            return .bluetoothOff
        case .failed(let reason):
            return isPaired ? .attention(reason) : .notPaired
        }
    }

    /// The state to show at `now`. A down link reads as reconnecting until
    /// the grace window has passed, then as disconnected. A link that comes
    /// back shows connected at once.
    mutating func resolve(_ signal: Signal, now: Date) -> BandLinkState {
        switch signal {
        case .linked(let syncing):
            downSince = nil
            hasBeenLinked = true
            return syncing ? .syncing : .connected
        case .down:
            let since = downSince ?? now
            downSince = since
            return now.timeIntervalSince(since) >= grace ? .disconnected : .reconnecting
        case .settling:
            return .reconnecting
        case .bluetoothOff:
            downSince = nil
            return .bluetoothOff
        case .notPaired:
            downSince = nil
            hasBeenLinked = false
            return .notPaired
        case .attention(let message):
            downSince = nil
            return .needsAttention(message)
        }
    }

    /// When the current grace window closes, if one is running.
    var graceDeadline: Date? {
        downSince.map { $0.addingTimeInterval(grace) }
    }
}

/// The observable answer the shell hands to every tab.
///
/// One value, one publish: the status, the grace window and the band details
/// change together, so a reconnect costs each observer one body pass instead
/// of three. Screens read it through `@Environment(BandLinkPresentation.self)`
/// in the app, and packages read `\.looprBandIndicator`.
@MainActor
@Observable
final class BandLinkPresentation {
    private(set) var state: BandLinkState = .reconnecting
    private(set) var indicator = LooprBandIndicator(link: .reconnecting)
    private(set) var isPaired = false
    private(set) var hasBeenLinked = false
    private(set) var canOfferPairing = false
    private(set) var bandModelName: String?
    private(set) var bandIsExperimental = false

    /// Called once each time the state enters `.disconnected`, which is after
    /// the grace window. Production posts the disconnect notification here.
    @ObservationIgnored var onDisconnected: (@MainActor () -> Void)?

    @ObservationIgnored private var hysteresis: BandLinkHysteresis
    @ObservationIgnored private var lastSignal: BandLinkHysteresis.Signal = .settling
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private let clock: @MainActor () -> Date

    init(grace: TimeInterval = BluetoothApplicationModel.bandLinkGraceSeconds,
         clock: @escaping @MainActor () -> Date = { Date() }) {
        self.hysteresis = BandLinkHysteresis(grace: grace)
        self.clock = clock
    }

    var graceSeconds: TimeInterval { hysteresis.grace }

    /// Feeds a new raw status. Safe to call with an unchanged value.
    func update(
        status: BluetoothApplicationStatus,
        isPaired: Bool,
        isSyncing: Bool,
        canOfferPairing: Bool,
        bandModelName: String?,
        bandIsExperimental: Bool
    ) {
        set(\.isPaired, isPaired)
        set(\.canOfferPairing, canOfferPairing)
        set(\.bandModelName, bandModelName)
        set(\.bandIsExperimental, bandIsExperimental)
        lastSignal = BandLinkHysteresis.signal(for: status, isPaired: isPaired, isSyncing: isSyncing)
        reevaluate()
    }

    /// Battery and sync time come from the runtime or the stored status.
    /// A missing reading keeps the last known one, so the ring never blinks.
    func updateDetails(batteryPercent: Int?, charging: Bool?, onWrist: Bool? = nil, lastSyncedAt: Date?) {
        var next = indicator
        if let batteryPercent { next.batteryPercent = batteryPercent }
        next.charging = charging
        next.onWrist = onWrist
        if let lastSyncedAt, lastSyncedAt > (next.lastSyncedAt ?? .distantPast) { next.lastSyncedAt = lastSyncedAt }
        if !isPaired {
            next.batteryPercent = nil
            next.charging = nil
            next.onWrist = nil
        }
        if next != indicator { indicator = next }
    }

    /// The short band line in Settings. A blip after the band was linked
    /// keeps saying "Connected"; a cold start says "Connecting".
    var settingsSummary: String {
        switch state {
        case .connected: indicator.onWrist == false ? "Off wrist" : indicator.charging == true ? "Charging" : "Connected"
        case .syncing: indicator.onWrist == false ? "Syncing · Off wrist" : indicator.charging == true ? "Syncing · Charging" : "Syncing"
        case .reconnecting: hasBeenLinked ? "Connected" : "Connecting"
        case .disconnected: "Not connected"
        case .bluetoothOff: "Bluetooth is off"
        case .notPaired: "Not paired"
        case .needsAttention: "Can't connect"
        }
    }

    /// The live heart stream keeps running through a blip. Stopping it there
    /// tore the stream down and rebuilt it for a link that came back a
    /// second later.
    var keepsLiveSession: Bool {
        state.isLinked || (state == .reconnecting && hasBeenLinked)
    }

    private func reevaluate() {
        let previous = state
        let next = hysteresis.resolve(lastSignal, now: clock())
        set(\.hasBeenLinked, hysteresis.hasBeenLinked)
        if next != state { state = next }
        var nextIndicator = indicator
        nextIndicator.link = next.indicatorLink
        if !isPaired {
            nextIndicator.batteryPercent = nil
            nextIndicator.charging = nil
            nextIndicator.onWrist = nil
        }
        if nextIndicator != indicator { indicator = nextIndicator }
        scheduleDeadline()
        if next == .disconnected, previous != .disconnected { onDisconnected?() }
    }

    /// Re-evaluates once the grace window closes, so a link that never came
    /// back is reported without waiting for another status change.
    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard state == .reconnecting, let deadline = hysteresis.graceDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(clock()))
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.deadlineTask = nil
            self.reevaluate()
        }
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<BandLinkPresentation, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

import SwiftUI

extension EnvironmentValues {
    /// The debounced band state. Reading a property tracks only that
    /// property, so a screen that shows the model name is not redrawn by a
    /// battery tick.
    @Entry var looprBandLink: BandLinkPresentation? = nil
    /// The Bluetooth model for actions only (pair, remove, sync). Reading it
    /// from here does not subscribe the view to every publish the model
    /// makes, unlike `@EnvironmentObject`.
    @Entry var looprBluetoothModel: BluetoothApplicationModel? = nil
}
