import Foundation
import ProtocolKit

/// The descriptor data used by AccessorySetupKit.  Keeping the value type
/// available on every platform lets provisioning flow tests run on macOS while
/// the UIKit/AccessorySetupKit adapter remains iOS-only.
public struct AccessoryDiscoveryDescriptor: Equatable, Sendable {
    public let bluetoothServiceUUID: UUID
    public let bluetoothNameSubstring: String?
    /// The name the iOS pairing sheet shows. Onboarding tells the person to
    /// pick this name, so the two must match.
    public let displayName: String
    /// Product pictures for the sheet, best first, looked up in the app
    /// bundle. A drawn band stands in until one ships.
    public let productImageNames: [String]

    public init(
        bluetoothServiceUUID: UUID = HarvardBluetoothProfile.service,
        bluetoothNameSubstring: String? = "WHOOP",
        displayName: String = "WHOOP 4.0",
        productImageNames: [String] = ["band-product-pairing", "band-product"]
    ) {
        self.bluetoothServiceUUID = bluetoothServiceUUID
        self.bluetoothNameSubstring = bluetoothNameSubstring
        self.displayName = displayName
        self.productImageNames = productImageNames
    }
}

public extension AccessoryDiscoveryDescriptor {
    static let harvardWHOOP4 = Self()
    // OpenStrap edge feat/multiband-whoop5,
    // ios/Runner/AccessorySetup.swift:143-168 matches FD4B by service only.
    static let whoop5 = Self(
        bluetoothServiceUUID: GATTProfile.gen5.service,
        bluetoothNameSubstring: nil,
        displayName: "WHOOP 5.0"
    )
    static let whoopMG = Self(
        bluetoothServiceUUID: GATTProfile.gen5.service,
        bluetoothNameSubstring: nil,
        displayName: "WHOOP MG"
    )
}

/// What the flow can prove about an AccessorySetupKit accessory.  The native
/// object is never persisted; only this UUID crosses the store boundary.
public struct ProvisionedAccessory: Equatable, Sendable {
    public let bluetoothIdentifier: UUID
    public let displayName: String
    public let bluetoothServiceUUID: UUID?

    public init(bluetoothIdentifier: UUID, displayName: String = "WHOOP 4.0", bluetoothServiceUUID: UUID? = nil) {
        self.bluetoothIdentifier = bluetoothIdentifier
        self.displayName = displayName
        self.bluetoothServiceUUID = bluetoothServiceUUID
    }
}

public enum AccessorySetupError: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case noResult
    case pickerAlreadyPresented
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Accessory picker cancelled."
        case .noResult: "Accessory picker returned no accessory."
        case .pickerAlreadyPresented: "Accessory picker is already presented."
        case .unavailable: "Accessory setup is unavailable."
        case .failed(let reason): "Accessory setup failed: \(reason)"
        }
    }
}

/// AccessorySetupKit has an asynchronous activation lifecycle.  The native
/// client exposes this small state so callers can prove that an ASK session is
/// ready before reading accessories or presenting the picker.
public enum AccessorySetupActivationState: Equatable, Sendable {
    case activating
    case ready
    case invalidated
}

/// The only persistence contract provisioning needs.  A dedicated store keeps
/// the identifier out of scattered UserDefaults reads and makes relaunch and
/// removal behavior deterministic in tests.
public protocol AccessoryProvisioningStore: Sendable {
    func loadBluetoothIdentifier() async -> UUID?
    func saveBluetoothIdentifier(_ identifier: UUID) async throws
    func removeBluetoothIdentifier() async throws
}

public actor InMemoryAccessoryProvisioningStore: AccessoryProvisioningStore {
    private var identifier: UUID?

    public init(identifier: UUID? = nil) { self.identifier = identifier }

    public func loadBluetoothIdentifier() -> UUID? { identifier }

    public func saveBluetoothIdentifier(_ identifier: UUID) async throws {
        self.identifier = identifier
    }

    public func removeBluetoothIdentifier() async throws { identifier = nil }
}

/// The production store uses one namespaced key owned by this type.  Callers
/// never receive the underlying defaults object and cannot accidentally create
/// a second identifier key.
public final class UserDefaultsAccessoryProvisioningStore: AccessoryProvisioningStore, @unchecked Sendable {
    public static let key = "com.loopr.bluetooth.provisionedAccessory.bluetoothIdentifier"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func loadBluetoothIdentifier() async -> UUID? {
        guard let string = defaults.string(forKey: Self.key) else { return nil }
        return UUID(uuidString: string)
    }

    public func saveBluetoothIdentifier(_ identifier: UUID) async throws {
        defaults.set(identifier.uuidString, forKey: Self.key)
    }

    public func removeBluetoothIdentifier() async throws {
        defaults.removeObject(forKey: Self.key)
    }
}

/// The transport-neutral AccessorySetupKit operations needed by the flow.
/// There is intentionally no BLETransport here: provisioning never opens a
/// GATT connection or writes a packet.
public protocol AccessorySetupClient: Sendable {
    func provisionedAccessories() async -> [ProvisionedAccessory]
    func showPicker(for descriptor: AccessoryDiscoveryDescriptor) async throws -> ProvisionedAccessory?
    func showPicker(for descriptors: [AccessoryDiscoveryDescriptor]) async throws -> ProvisionedAccessory?
    func removeAccessory(_ accessory: ProvisionedAccessory) async throws
}

public extension AccessorySetupClient {
    func showPicker(for descriptors: [AccessoryDiscoveryDescriptor]) async throws -> ProvisionedAccessory? {
        guard let first = descriptors.first else { return nil }
        return try await showPicker(for: first)
    }
}

public enum AccessoryProvisioningState: Equatable, Sendable {
    case idle
    case provisioned(UUID)
    case explanationRequired
    case pickerPresented
    case cancelled
    case noResult
    case removed
    case failed(String)
}

public enum AccessoryProvisioningOutcome: Equatable, Sendable {
    case alreadyProvisioned(UUID)
    case explanationRequired
    case pickerPresented
    case provisioned(UUID)
    case cancelled
    case noResult
    case pickerAlreadyPresented
    case removed
    case failed(String)
}

/// Coordinates first-use provisioning.  `inspectExisting()` is safe to call
/// at launch and never presents UI.  The picker is reachable only through the
/// explicit `userTappedPair()` then `continueAfterExplanation()` actions.
public actor AccessoryProvisioningController {
    /// The pairing guidance for screens outside onboarding. The WHOOP app
    /// reconnects in the background, so its Bluetooth access goes off first;
    /// the two-finger tap is WHOOP's method for a band that was paired
    /// before, and the battery pack only wakes a band that never was.
    public static let ownershipExplanation = """
        Your band has to be in pairing mode, with the side light pulsing blue.

        1. Turn off the WHOOP app's Bluetooth access in Settings, under Privacy & Security, then Bluetooth. Then swipe the WHOOP app away.
        2. Take the band off. When the green lights underneath go out, hold it by the sides and tap the top with two fingers until the side light pulses blue. A band that was never paired also wakes when you slide on a charged battery pack.
        3. Keep the band next to your iPhone and connect within about 3 minutes.
        """

    /// The same guidance for an alert, which centers its message and clips a
    /// long one. Numbered steps belong on the roomier pairing screens.
    public static let ownershipExplanationShort =
        "Take the band off and tap the top with two fingers until the side light is pulsing blue. "
        + "Turn off the WHOOP app's Bluetooth access first, in Settings under Privacy & Security, then Bluetooth."

    private let client: any AccessorySetupClient
    private let store: any AccessoryProvisioningStore
    private let descriptor: AccessoryDiscoveryDescriptor
    private let experimentalSupportEnabled: @Sendable () async -> Bool
    private var currentAccessory: ProvisionedAccessory?

    public private(set) var state: AccessoryProvisioningState = .idle

    public func provisionedDisplayName() -> String? { currentAccessory?.displayName }
    public func provisionedServiceUUID() -> UUID? { currentAccessory?.bluetoothServiceUUID }

    public init(
        client: any AccessorySetupClient,
        store: any AccessoryProvisioningStore,
        descriptor: AccessoryDiscoveryDescriptor = .harvardWHOOP4,
        experimentalSupportEnabled: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.client = client
        self.store = store
        self.descriptor = descriptor
        self.experimentalSupportEnabled = experimentalSupportEnabled
    }

    /// Reconciles the durable UUID with AccessorySetupKit's authoritative list
    /// before any picker UI can be shown.
    @discardableResult
    public func inspectExisting() async -> AccessoryProvisioningOutcome {
        let persisted = await store.loadBluetoothIdentifier()
        let accessories = await client.provisionedAccessories()
        guard let accessory = accessories.first(where: {
            persisted == nil || $0.bluetoothIdentifier == persisted
        }) else {
            if persisted != nil {
                try? await store.removeBluetoothIdentifier()
            }
            currentAccessory = nil
            state = .idle
            return .noResult
        }

        currentAccessory = accessory
        try? await store.saveBluetoothIdentifier(accessory.bluetoothIdentifier)
        state = .provisioned(accessory.bluetoothIdentifier)
        return .alreadyProvisioned(accessory.bluetoothIdentifier)
    }

    /// Explicit UI action: this only presents the in-app explanation.  It does
    /// not invoke the system picker.
    public func userTappedPair() -> AccessoryProvisioningOutcome {
        guard state != .pickerPresented else { return .pickerAlreadyPresented }
        if case .provisioned(let identifier) = state {
            return .alreadyProvisioned(identifier)
        }
        state = .explanationRequired
        return .explanationRequired
    }

    /// Explicit UI action after the explanation is visible.  Only this method
    /// can call the client's picker API.
    @discardableResult
    public func continueAfterExplanation() async -> AccessoryProvisioningOutcome {
        guard state == .explanationRequired else {
            return state == .pickerPresented ? .pickerAlreadyPresented : .failed("pairing explanation was not presented")
        }

        state = .pickerPresented
        do {
            let descriptors = await experimentalSupportEnabled()
                ? [descriptor, .whoop5, .whoopMG] : [descriptor]
            guard let accessory = try await client.showPicker(for: descriptors) else {
                state = .noResult
                return .noResult
            }
            currentAccessory = accessory
            try await store.saveBluetoothIdentifier(accessory.bluetoothIdentifier)
            state = .provisioned(accessory.bluetoothIdentifier)
            return .provisioned(accessory.bluetoothIdentifier)
        } catch let error as AccessorySetupError {
            switch error {
            case .cancelled:
                state = .cancelled
                return .cancelled
            case .noResult:
                state = .noResult
                return .noResult
            case .pickerAlreadyPresented:
                state = .pickerPresented
                return .pickerAlreadyPresented
            case .unavailable, .failed:
                state = .failed(error.localizedDescription)
                return .failed(error.localizedDescription)
            }
        } catch {
            state = .failed(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    /// Removes the currently authorized accessory and clears the dedicated
    /// UUID store.  A subsequent pair can happen in this same controller.
    @discardableResult
    public func removeProvisionedAccessory() async -> AccessoryProvisioningOutcome {
        guard let accessory = currentAccessory else {
            try? await store.removeBluetoothIdentifier()
            state = .removed
            return .removed
        }

        do {
            try await client.removeAccessory(accessory)
            try await store.removeBluetoothIdentifier()
            currentAccessory = nil
            state = .removed
            return .removed
        } catch {
            state = .failed(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    public func currentBluetoothIdentifier() async -> UUID? {
        if case .provisioned(let identifier) = state { return identifier }
        return await store.loadBluetoothIdentifier()
    }
}

#if canImport(AccessorySetupKit) && os(iOS)
import AccessorySetupKit
import CoreBluetooth
import UIKit

/// The one place where Loopr constructs AccessorySetupKit's native discovery
/// descriptor/display item.  It performs discovery only; it never owns a
/// `CBCentralManager` and never starts a GATT operation.
public enum AccessorySetupKitDescriptorFactory {
    public static func makeDiscoveryDescriptor(
        descriptor: AccessoryDiscoveryDescriptor = .harvardWHOOP4
    ) -> ASDiscoveryDescriptor {
        let native = ASDiscoveryDescriptor()
        native.bluetoothServiceUUID = CBUUID(string: descriptor.bluetoothServiceUUID.uuidString)
        if let name = descriptor.bluetoothNameSubstring { native.bluetoothNameSubstring = name }
        // No .bluetoothPairingLE, matching Edge, which connects to the same
        // band. The band bonds on its first write with response. With the
        // option set, connects on a real WHOOP 4 failed with
        // CBError.peerRemovedPairingInformation; the link is unproven.
        return native
    }

    public static func makePickerDisplayItem(
        descriptor: AccessoryDiscoveryDescriptor = .harvardWHOOP4,
        bundle: Bundle = .main
    ) -> ASPickerDisplayItem {
        ASPickerDisplayItem(
            name: descriptor.displayName,
            productImage: productImage(for: descriptor, bundle: bundle),
            descriptor: makeDiscoveryDescriptor(descriptor: descriptor)
        )
    }

    /// The first bundled product picture, or a drawn band when none ships.
    public static func productImage(
        for descriptor: AccessoryDiscoveryDescriptor = .harvardWHOOP4,
        bundle: Bundle = .main
    ) -> UIImage {
        for name in descriptor.productImageNames {
            if let image = UIImage(named: name, in: bundle, with: nil) { return image }
        }
        return drawnBand()
    }

    /// A black band seen from the side with its side light glowing blue, on
    /// a clear background as the sheet expects.
    static func drawnBand() -> UIImage {
        let size = CGSize(width: 360, height: 240)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let strap = UIBezierPath(
                roundedRect: CGRect(x: 20, y: 96, width: 320, height: 48),
                cornerRadius: 24
            )
            UIColor(white: 0.12, alpha: 1).setFill()
            strap.fill()
            UIColor(white: 1, alpha: 0.08).setStroke()
            strap.lineWidth = 2
            strap.stroke()

            let pod = UIBezierPath(
                roundedRect: CGRect(x: 110, y: 72, width: 140, height: 96),
                cornerRadius: 28
            )
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: UIColor(white: 0, alpha: 0.35).cgColor)
            UIColor(white: 0.07, alpha: 1).setFill()
            pod.fill()
            cg.restoreGState()
            UIColor(white: 1, alpha: 0.12).setStroke()
            pod.lineWidth = 2
            pod.stroke()

            let blue = UIColor(red: 0.35, green: 0.55, blue: 1, alpha: 1)
            let glow = CGRect(x: 226, y: 96, width: 48, height: 48)
            let colors = [blue.withAlphaComponent(0.7).cgColor, blue.withAlphaComponent(0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: glow.midX, y: glow.midY), startRadius: 0,
                    endCenter: CGPoint(x: glow.midX, y: glow.midY), endRadius: 24,
                    options: []
                )
            }
            blue.setFill()
            UIBezierPath(roundedRect: CGRect(x: 246, y: 110, width: 8, height: 20), cornerRadius: 4).fill()
        }
    }
}

/// Thin AccessorySetupKit adapter.  The flow above remains testable without
/// UIKit and this adapter contains no connection or protocol policy.
public final class AccessorySetupKitClient: NSObject, AccessorySetupClient, @unchecked Sendable {
    private let session: ASAccessorySession
    private let queue: DispatchQueue
    private var activationStateStorage: AccessorySetupActivationState = .activating
    private var activationWaiters: [CheckedContinuation<Bool, Never>] = []
    private var pickerContinuation: CheckedContinuation<ProvisionedAccessory?, Error>?
    private var pickerInFlight = false
    private var pickerDismissed = false

    public var activationState: AccessorySetupActivationState {
        queue.sync { activationStateStorage }
    }

    public init(
        session: ASAccessorySession = ASAccessorySession(),
        queue: DispatchQueue = DispatchQueue(label: "com.loopr.accessory-setup")
    ) {
        self.session = session
        self.queue = queue
        super.init()
        session.activate(on: queue) { [weak self] event in
            self?.handle(event)
        }
    }

    public func provisionedAccessories() async -> [ProvisionedAccessory] {
        guard await waitUntilActivated() else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                #if DEBUG
                if let accessories = self?.session.accessories {
                    let states = accessories.map { $0.state.rawValue }
                    fputs("[Loopr BLE] \(Date().formatted(date: .omitted, time: .standard)) accessory authorization states=\(states)\n", stderr)
                }
                #endif
                continuation.resume(returning: self?.session.accessories.compactMap(Self.map) ?? [])
            }
        }
    }

    public func showPicker(for descriptor: AccessoryDiscoveryDescriptor) async throws -> ProvisionedAccessory? {
        try await showPicker(for: [descriptor])
    }

    public func showPicker(for descriptors: [AccessoryDiscoveryDescriptor]) async throws -> ProvisionedAccessory? {
        guard await waitUntilActivated() else { throw AccessorySetupError.unavailable }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProvisionedAccessory?, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: AccessorySetupError.unavailable)
                    return
                }
                guard !self.pickerInFlight else {
                    continuation.resume(throwing: AccessorySetupError.pickerAlreadyPresented)
                    return
                }
                self.pickerInFlight = true
                self.pickerDismissed = false
                self.pickerContinuation = continuation
                self.session.showPicker(for: descriptors.map {
                    AccessorySetupKitDescriptorFactory.makePickerDisplayItem(descriptor: $0)
                }) { [weak self] error in
                    self?.handlePickerCompletion(error)
                }
            }
        }
    }

    public func removeAccessory(_ accessory: ProvisionedAccessory) async throws {
        guard await waitUntilActivated() else { throw AccessorySetupError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self,
                      let native = self.session.accessories.first(where: {
                          $0.bluetoothIdentifier == accessory.bluetoothIdentifier
                      }) else {
                    continuation.resume(returning: ())
                    return
                }
                self.session.removeAccessory(native) { error in
                    if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    private func waitUntilActivated() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                switch self.activationStateStorage {
                case .ready:
                    continuation.resume(returning: true)
                case .invalidated:
                    continuation.resume(returning: false)
                case .activating:
                    self.activationWaiters.append(continuation)
                }
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            switch event.eventType {
            case .activated:
                self.activationStateStorage = .ready
                let waiters = self.activationWaiters
                self.activationWaiters.removeAll(keepingCapacity: false)
                waiters.forEach { $0.resume(returning: true) }
            case .invalidated:
                self.activationStateStorage = .invalidated
                let waiters = self.activationWaiters
                self.activationWaiters.removeAll(keepingCapacity: false)
                waiters.forEach { $0.resume(returning: false) }
                self.finishPicker(throwing: .unavailable)
            case .pickerDidDismiss:
                // ASK can dismiss without invoking the picker completion
                // handler.  Treat this native lifecycle event as cancellation
                // after the same short accessory-list settling window used by
                // the Edge implementation.  A newly-added accessory wins;
                // otherwise the controller receives a typed cancellation.
                self.pickerDismissed = true
                self.finishPickerAfterDismissal()
            default:
                break
            }
        }
    }

    private func handlePickerCompletion(_ error: Error?) {
        queue.async { [weak self] in
            guard let self, self.pickerInFlight else { return }
            if let error {
                self.finishPicker(throwing: Self.map(error))
                return
            }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                self?.finishPickerAfterSettling()
            }
        }
    }

    private func finishPickerAfterDismissal() {
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self, self.pickerInFlight else { return }
            if self.session.accessories.compactMap(Self.map).first != nil {
                self.finishPickerAfterSettling()
            } else {
                self.finishPicker(throwing: .cancelled)
            }
        }
    }

    private func finishPickerAfterSettling() {
        guard pickerInFlight else { return }
        let accessory = session.accessories.compactMap(Self.map).first
        pickerInFlight = false
        pickerDismissed = false
        let continuation = pickerContinuation
        pickerContinuation = nil
        continuation?.resume(returning: accessory)
    }

    private func finishPicker(throwing error: AccessorySetupError) {
        guard pickerInFlight else { return }
        pickerInFlight = false
        pickerDismissed = false
        let continuation = pickerContinuation
        pickerContinuation = nil
        continuation?.resume(throwing: error)
    }

    private static func map(_ accessory: ASAccessory) -> ProvisionedAccessory? {
        guard let identifier = accessory.bluetoothIdentifier else { return nil }
        return ProvisionedAccessory(
            bluetoothIdentifier: identifier,
            displayName: accessory.displayName,
            bluetoothServiceUUID: accessory.descriptor.bluetoothServiceUUID.flatMap { UUID(uuidString: $0.uuidString) }
        )
    }

    private static func map(_ error: Error) -> AccessorySetupError {
        let nsError = error as NSError
        guard nsError.domain == ASErrorDomain else {
            return .failed(nsError.localizedDescription)
        }
        switch nsError.code {
        case 500:
            return .pickerAlreadyPresented
        case 700:
            return .cancelled
        case 400:
            return .unavailable
        default:
            return .failed(nsError.localizedDescription)
        }
    }
}
#endif
