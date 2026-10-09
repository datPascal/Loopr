import Foundation
import AnalyticsKit

func usage() -> String {
    """
    Usage:
      AnalyticsParityCLI run FIXTURE.json
      AnalyticsParityCLI compare DART.json SWIFT.json MANIFEST.json
      AnalyticsParityCLI --help
    """
}
func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("AnalyticsParityCLI: \(message)\n".utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
    print(usage())
    exit(0)
}

switch arguments[0] {
case "run":
    guard arguments.count == 2 else { fail(usage()) }
    let fixtureURL = URL(fileURLWithPath: arguments[1])
    do {
        let output = try AnalyticsParityRunner.run(inputData: Data(contentsOf: fixtureURL))
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail(error.localizedDescription, code: 65)
    }
case "compare":
    guard arguments.count == 4 else { fail(usage()) }
    do {
        let dart = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let swift = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let manifest = try ParityToleranceManifest.load(data: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let report = try AnalyticsParityComparator.compare(expected: dart, actual: swift, manifest: manifest)
        print(report.humanReadable)
        if !report.passed { exit(1) }
    } catch {
        fail(error.localizedDescription, code: 65)
    }
default:
    fail(usage())
}
