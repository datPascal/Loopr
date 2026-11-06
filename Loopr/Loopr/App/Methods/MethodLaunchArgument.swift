#if DEBUG
import DataKit
import Foundation

/// DEBUG launch arguments that open Data on a method page, for UI tests and captures.
///
/// - `--loopr-method=<id>` opens that method page, for example `--loopr-method=phenoage`.
/// - `--loopr-method=list` opens "How the numbers work".
/// - `--loopr-method-fixture` adds the fixture values (PhenoAge and recovery) so the page draws its waterfall.
enum MethodLaunchArgument {
    static let prefix = "--loopr-method="
    static let fixture = "--loopr-method-fixture"

    /// Data's stack for the argument, or nil when there is none or it names no method.
    static func healthPath(_ arguments: [String]) -> [AppHealthRoute]? {
        guard let raw = arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) else { return nil }
        if raw == "list" { return [.methods] }
        return MethodID(rawValue: String(raw)).map { [.methods, .method($0)] }
    }

    static func usesFixtureValues(_ arguments: [String]) -> Bool {
        arguments.contains(fixture)
    }
}
#endif
