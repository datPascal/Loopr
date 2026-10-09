import Foundation

/// Whether another app on this iPhone seemed to hold a link to the band
/// before Loopr opened its own.
///
/// iOS shares one radio link per peripheral between the apps on a phone, and
/// `retrieveConnectedPeripherals(withServices:)` lists peripherals "that other
/// apps have connected". It does not say which app. The answer only means
/// something before Loopr's first connection in this process: after that the
/// link may be Loopr's own, and a restored peripheral is Loopr's by
/// definition. Even then it is a hint, never proof: it cannot name the WHOOP
/// app, and a clean result does not mean the band is free.
public enum SharedLinkHint {
    public static func otherAppHoldsLink(
        systemConnected: [PeripheralID],
        provisioned: PeripheralID,
        restored: Set<PeripheralID>,
        hasConnectedLocally: Bool
    ) -> Bool {
        guard !hasConnectedLocally, !restored.contains(provisioned) else { return false }
        return systemConnected.contains(provisioned)
    }
}
