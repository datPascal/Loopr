import Foundation
import SwiftUI

/// What the shell tells every tab about the band. The app target builds it from the
/// Bluetooth model; packages only read it. `link` is already debounced by the app, so a
/// view can render it directly without its own grace window.
public struct LooprBandIndicator: Equatable, Sendable {
    public enum Link: Equatable, Sendable {
        case connected
        case syncing
        case reconnecting
        case disconnected
        case bluetoothOff
        case notPaired
        case needsAttention
    }

    public var link: Link
    public var batteryPercent: Int?
    public var onWrist: Bool?
    public var charging: Bool?
    public var lastSyncedAt: Date?

    public init(link: Link, batteryPercent: Int? = nil, charging: Bool? = nil, onWrist: Bool? = nil, lastSyncedAt: Date? = nil) {
        self.link = link
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.onWrist = onWrist
        self.lastSyncedAt = lastSyncedAt
    }
}

public struct LooprShellAction: Sendable {
    public let run: @MainActor @Sendable () -> Void

    public init(run: @escaping @MainActor @Sendable () -> Void) { self.run = run }
}

public struct LooprRefreshAction: Sendable {
    public let run: @MainActor @Sendable () async -> Void

    public init(run: @escaping @MainActor @Sendable () async -> Void) { self.run = run }
}

extension EnvironmentValues {
    @Entry public var looprBandIndicator: LooprBandIndicator? = nil
    @Entry public var looprOpenSettings: LooprShellAction? = nil
    @Entry public var looprRefresh: LooprRefreshAction? = nil
}

/// A fresh token makes repeated home links scroll the existing tab again.
public struct LooprTabScrollRequest: Equatable, Sendable {
    public let id: UUID
    public init() { id = UUID() }
}

extension EnvironmentValues {
    @Entry public var looprTabScrollRequest: LooprTabScrollRequest? = nil
}
