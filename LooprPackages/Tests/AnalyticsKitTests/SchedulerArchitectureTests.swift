import Foundation
import XCTest

/// ANA-08.5 is a structural invariant: calculators accept immutable values and
/// return payloads; only DerivationScheduler owns a DerivationStore write. The
/// test keeps the code-review grep executable in CI without depending on a
/// database implementation or a runtime write side effect.
final class SchedulerArchitectureTests: XCTestCase {
    func testOnlySchedulerReferencesDerivationStoreAndItsPersistWrite() throws {
        let analyticsKitRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AnalyticsKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // LooprPackages
            .appendingPathComponent("Sources/AnalyticsKit", isDirectory: true)
        let sourceFiles = try XCTUnwrap(FileManager.default.enumerator(
            at: analyticsKitRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let schedulerFiles = sourceFiles.filter { $0.path.contains("/Scheduler/") }
        let nonSchedulerFiles = sourceFiles.filter { !$0.path.contains("/Scheduler/") }

        let directStoreReferences = try nonSchedulerFiles.flatMap { file -> [String] in
            let source = try String(contentsOf: file, encoding: .utf8)
            return source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { offset, line in
                line.contains("DerivationStore") ? "\(file.lastPathComponent):\(offset + 1): \(line)" : nil
            }
        }
        let directPersistCalls = try nonSchedulerFiles.flatMap { file -> [String] in
            let source = try String(contentsOf: file, encoding: .utf8)
            return source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { offset, line in
                let text = String(line)
                guard text.contains(".persist(") || text.contains(".persist (") else { return nil }
                return "\(file.lastPathComponent):\(offset + 1): \(text)"
            }
        }

        XCTAssertTrue(schedulerFiles.contains { $0.lastPathComponent == "DerivationScheduler.swift" })
        XCTAssertTrue(directStoreReferences.isEmpty, directStoreReferences.joined(separator: "\n"))
        XCTAssertTrue(directPersistCalls.isEmpty, directPersistCalls.joined(separator: "\n"))

        let schedulerSourceURL = try XCTUnwrap(schedulerFiles.first { $0.lastPathComponent == "DerivationScheduler.swift" })
        let schedulerSource = try String(contentsOf: schedulerSourceURL, encoding: .utf8)
        XCTAssertTrue(schedulerSource.contains("try await store.persist(generation)"))
    }
}
