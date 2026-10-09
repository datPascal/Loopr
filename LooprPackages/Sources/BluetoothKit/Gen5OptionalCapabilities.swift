import Foundation

public enum Gen5OptionalCapability: String, CaseIterable, Codable, Sendable {
    case liveHeartRateAndRR
    case findMyStrapHaptic
    case alarm
    case gestures
    case renameAndConfiguration
    case v20Archive
    case v21Archive
    case v26Archive
}

public actor Gen5OptionalCapabilitySwitches {
    private var enabled: Set<Gen5OptionalCapability>

    public init(enabled: Set<Gen5OptionalCapability> = []) { self.enabled = enabled }

    public func isEnabled(_ capability: Gen5OptionalCapability) -> Bool {
        enabled.contains(capability)
    }

    public func setEnabled(_ value: Bool, for capability: Gen5OptionalCapability) {
        if value { enabled.insert(capability) } else { enabled.remove(capability) }
    }
}
