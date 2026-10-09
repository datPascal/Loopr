#if PROTOCOL_DIAGNOSTICS
import Foundation

/// Hex formatting is intentionally available only in explicit diagnostics
/// builds.  It must never become part of a release decode or encode path.
public enum ProtocolDiagnostics {
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public extension Data {
    /// Convenience spelling for diagnostic call sites.
    var protocolDiagnosticHex: String { ProtocolDiagnostics.hex(self) }
}
#endif
