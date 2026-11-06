import Combine
import Foundation
import JournalKit
import RoutineKit
import UniformTypeIdentifiers

/// Opens a protocol file from a URL and hands the result to the import preview. It reads and validates only. Saving a
/// protocol is the import screen's job, after the person confirms, so nothing here touches the store.
nonisolated enum RoutineFileRejection: Equatable, Sendable {
    /// Not a `.looprprotocol` or `.json` file on disk.
    case notAProtocolFile
    case unreadable
    case invalid(ProtocolFileError)

    var message: String {
        switch self {
        case .notAProtocolFile: "Loopr opens protocol files that end in .looprprotocol or .json."
        case .unreadable: "Loopr could not read this file."
        case .invalid(let error): error.errorDescription ?? "This file is not a Loopr protocol."
        }
    }
}

nonisolated enum RoutineFileOpenResult: Equatable, Sendable {
    case preview(ProtocolImportPreview)
    case rejected(RoutineFileRejection)

    /// The result as the Protocol tab's Rules segment reads it.
    var incoming: ProtocolFileIncoming {
        switch self {
        case .preview(let preview): .preview(preview)
        case .rejected(let rejection): .rejected(rejection.message)
        }
    }
}

nonisolated enum RoutineFileHandler {
    /// The type declared in Info.plist: `com.loopr.protocol`, a kind of JSON, with the extension `looprprotocol`.
    static var protocolType: UTType { UTType(exportedAs: ProtocolFile.typeIdentifier, conformingTo: .json) }

    /// A file URL for a protocol file or a plain JSON file. The app routes only these to `open`.
    static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == ProtocolFile.fileExtension || ext == "json"
    }

    static func open(_ url: URL) -> RoutineFileOpenResult {
        guard canOpen(url) else { return .rejected(.notAProtocolFile) }
        // Files opened from another app or from Files sit outside the sandbox until access is granted.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > ProtocolFile.maximumBytes {
            return .rejected(.invalid(.tooLarge(bytes: size)))
        }
        // Read one byte past the limit, so a file that grew or lied about its size is still refused without loading it all.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .rejected(.unreadable) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ProtocolFile.maximumBytes + 1) else { return .rejected(.unreadable) }
        return open(data: data)
    }

    static func open(data: Data) -> RoutineFileOpenResult {
        do {
            return .preview(try ProtocolFileCodec.validate(data))
        } catch let error as ProtocolFileError {
            return .rejected(.invalid(error))
        } catch {
            return .rejected(.unreadable)
        }
    }
}

/// Holds the file the person just opened until the import screen takes it. The import screen reads `pending`, shows the
/// preview and calls `clear` when the person confirms or cancels.
///
/// `shared` is the app's one inbox: `.onOpenURL` (a file from the share sheet or Files) and the Rules segment's importer
/// both put files here, and the Protocol tab takes them through `incoming` (LV-07.4).
@MainActor
final class RoutineFileInbox: ObservableObject {
    static let shared = RoutineFileInbox()

    @Published private(set) var pending: RoutineFileOpenResult?

    /// Each file once: the Protocol tab reads it and the inbox clears, so a later subscriber does not see it again.
    var incoming: AnyPublisher<ProtocolFileIncoming, Never> {
        $pending.compactMap { $0 }
            .handleEvents(receiveOutput: { [weak self] _ in
                Task { @MainActor in self?.clear() }
            })
            .map(\.incoming)
            .eraseToAnyPublisher()
    }

    /// Returns true when the URL was a protocol or JSON file and has been read, whether or not it validated.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard RoutineFileHandler.canOpen(url) else { return false }
        pending = RoutineFileHandler.open(url)
        return true
    }

    func clear() { pending = nil }
}
