import Foundation

/// The native scan filter and advertisement gate share this policy.
struct BluetoothDiscoveryPolicy: Sendable {
    var isForeground: Bool
    var service: ServiceID = HarvardBluetoothProfile.service

    // Ordinary background discovery requires an explicit service filter.
    var serviceUUIDs: [ServiceID]? {
        isForeground ? nil : [service]
    }

    func accepts(name: String?, services: [ServiceID]) -> Bool {
        services.contains(service)
            || name?.range(of: "WHOOP", options: .caseInsensitive) != nil
    }
}
