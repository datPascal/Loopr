import Foundation
import RoutineKit
import Testing
import UniformTypeIdentifiers
@testable import Loopr

@MainActor struct RoutineFileHandlerTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineFileHandler-\(UUID().uuidString)")

    private func write(_ data: Data, as name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func validData() throws -> Data { try ProtocolTemplate.sleepFirst.data() }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test func infoPlistDeclaresTheProtocolTypeAndTheDocumentType() throws {
        let exported = try #require(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let declaration = try #require(exported.first { $0["UTTypeIdentifier"] as? String == "com.loopr.protocol" })
        #expect(declaration["UTTypeConformsTo"] as? [String] == ["public.json"])
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["looprprotocol"])
        #expect(exported.contains { $0["UTTypeIdentifier"] as? String == "com.loopr.gpx" }, "the route type is still declared")

        let documents = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let own = try #require(documents.first { ($0["LSItemContentTypes"] as? [String])?.contains("com.loopr.protocol") == true })
        #expect(own["LSHandlerRank"] as? String == "Owner")
        #expect(documents.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.json") == true && $0["LSHandlerRank"] as? String == "Alternate" })

        #expect(ProtocolFile.typeIdentifier == "com.loopr.protocol")
        #expect(RoutineFileHandler.protocolType.identifier == "com.loopr.protocol" && RoutineFileHandler.protocolType.conforms(to: .json))
    }

    @Test func aProtocolFileOpensToAPreview() throws {
        defer { cleanUp() }
        let url = try write(validData(), as: "sleep-first.looprprotocol")
        guard case .preview(let preview) = RoutineFileHandler.open(url) else { Issue.record("expected a preview"); return }
        #expect(preview.file.name == "Sleep first" && preview.file.rules.count == 6 && preview.ignoredFields.isEmpty)
        #expect(RoutineFileHandler.canOpen(url))
    }

    @Test func aPlainJSONFileThatValidatesOpensToo() throws {
        defer { cleanUp() }
        let url = try write(validData(), as: "someone.JSON")
        guard case .preview(let preview) = RoutineFileHandler.open(url) else { Issue.record("expected a preview"); return }
        #expect(preview.file.name == "Sleep first")
    }

    @Test func aFileThatDoesNotValidateIsRejectedWithItsReason() throws {
        defer { cleanUp() }
        let broken = try write(Data("not json".utf8), as: "broken.looprprotocol")
        #expect(RoutineFileHandler.open(broken) == .rejected(.invalid(.notJSON)))

        var text = try #require(String(data: validData(), encoding: .utf8))
        text = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
            .replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        let newer = try write(Data(text.utf8), as: "newer.looprprotocol")
        guard case .rejected(let rejection) = RoutineFileHandler.open(newer) else { Issue.record("expected a rejection"); return }
        #expect(rejection == .invalid(.newerSchema(2)))
        #expect(rejection.message == "This file needs a newer version of Loopr.")
    }

    @Test func aFileOverTheLimitIsRefusedBeforeItIsRead() throws {
        defer { cleanUp() }
        let url = try write(Data(repeating: 0x20, count: ProtocolFile.maximumBytes + 10), as: "huge.looprprotocol")
        #expect(RoutineFileHandler.open(url) == .rejected(.invalid(.tooLarge(bytes: ProtocolFile.maximumBytes + 10))))
    }

    @Test func otherFilesAndLinksAreNotRoutedHere() throws {
        defer { cleanUp() }
        let text = try write(Data("x".utf8), as: "notes.txt")
        let route = try write(Data("<gpx/>".utf8), as: "route.gpx")
        for url in [text, route, URL(string: "https://example.org/sleep.looprprotocol")!, URL(string: "loopr://today")!] {
            #expect(!RoutineFileHandler.canOpen(url), "\(url)")
            #expect(RoutineFileHandler.open(url) == .rejected(.notAProtocolFile))
        }
        #expect(RoutineFileHandler.open(folder.appendingPathComponent("missing.looprprotocol")) == .rejected(.unreadable))
        #expect(RoutineFileRejection.notAProtocolFile.message == "Loopr opens protocol files that end in .looprprotocol or .json.")
    }

    @Test func theInboxHoldsTheResultUntilTheImportScreenClearsIt() throws {
        defer { cleanUp() }
        let inbox = RoutineFileInbox()
        #expect(inbox.pending == nil)
        #expect(inbox.receive(try write(Data("x".utf8), as: "notes.txt")) == false && inbox.pending == nil)
        #expect(inbox.receive(try write(Data("nope".utf8), as: "bad.looprprotocol")))
        #expect(inbox.pending == .rejected(.invalid(.notJSON)))
        #expect(inbox.receive(try write(validData(), as: "good.looprprotocol")))
        guard case .preview? = inbox.pending else { Issue.record("expected a preview"); return }
        inbox.clear()
        #expect(inbox.pending == nil)
    }

    @Test func everyBundledTemplateOpensThroughTheHandler() throws {
        for template in ProtocolTemplate.allCases {
            guard case .preview(let preview) = RoutineFileHandler.open(data: try template.data()) else { Issue.record("\(template)"); return }
            #expect(preview.file.name == template.title)
        }
    }
}
