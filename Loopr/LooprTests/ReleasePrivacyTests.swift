import AIKit
import Foundation
import Security
import Testing

@testable import Loopr

struct LogRedactionTests {
    @Test
    func sensitiveDomainValuesNeverReachFormattedLogs() {
        let secretValues = ["72.4", "13.7563", "private note", "deadbeef"]
        let outputs = [
            ReleaseLogFormatter.format(.healthMetrics(sampleCount: 1)),
            ReleaseLogFormatter.format(.route(pointCount: 2)),
            ReleaseLogFormatter.format(.journal(entryCount: 3)),
            ReleaseLogFormatter.format(.bluetoothFrame(byteCount: 4))
        ]
        for output in outputs {
            #expect(output.contains("[REDACTED]"))
            #expect(!secretValues.contains(where: output.contains))
        }
    }
}

struct DiagnosticsExportTests {
    @Test
    func identifierAndRawPayloadsAreRedactedAndExportRequiresConfirmation() throws {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let input = SupportDiagnosticsInput(
            peripheralIdentifier: identifier,
            eventCount: 7,
            storageRowCount: 12,
            rawHealthPayload: Data("heart=99".utf8),
            rawProtocolFrames: [Data([0xde, 0xad, 0xbe, 0xef])]
        )
        let preview = SupportDiagnosticsExporter.preview(input)
        #expect(preview.peripheral == "[REDACTED]")
        #expect(!preview.rawPayloadsIncluded)
        #expect(throws: SupportDiagnosticsError.confirmationRequired) {
            try SupportDiagnosticsExporter.export(input, userConfirmed: false)
        }
        let export = try SupportDiagnosticsExporter.export(input, userConfirmed: true)
        let text = String(decoding: export, as: UTF8.self)
        #expect(!text.contains(identifier.uuidString))
        #expect(!text.contains("heart=99"))
        #expect(!text.lowercased().contains("deadbeef"))
    }
}

struct PrivacyManifestTests {
    @Test
    func appManifestDeclaresActualRequiredReasonsAndNoTracking() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        let manifest = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect(manifest["NSPrivacyTrackingDomains"] == nil)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, Set<String>)? in
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                  let codes = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return nil }
            return (category, Set(codes))
        })
        #expect(reasons == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]
        ])
    }
}

struct KeychainStorageTests {
    @Test
    func credentialRoundTripsOnlyThroughKeychain() async throws {
        let bundleID = "com.loopr.tests.release.\(UUID().uuidString)"
        let store = KeychainCredentialStore(bundleIdentifier: bundleID)
        let secret = Data("sk-release-keychain-only".utf8)
        let descriptor = KeychainCredentialStore.descriptor(bundleIdentifier: bundleID)
        #expect(descriptor.service == bundleID + ".ai-provider")
        #expect(descriptor.account == "openai-compatible-api-key")
        #expect(descriptor.accessibility == .whenUnlockedThisDeviceOnly)

        do {
            try await store.remove()
            try await store.write(secret)
            let storedSecret = try await store.read()
            #expect(storedSecret == secret)
            try await store.remove()
            let removedSecret = try await store.read()
            #expect(removedSecret == nil)
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(errSecMissingEntitlement) {
            // Canonical lanes intentionally disable code signing. Security rejects
            // their test host before storage with errSecMissingEntitlement; there is
            // no fallback store, and signed archive/install validation exercises the
            // real entitlement boundary.
        }
        #expect(!UserDefaults.standard.dictionaryRepresentation().description.contains(String(decoding: secret, as: UTF8.self)))
    }
}
