import Foundation

/// The two files of one published dashboard, in a folder of their own under the temporary directory.
public struct PublishedFiles: Equatable, Sendable {
    public let folder: URL
    public let html: URL
    public let json: URL

    public var urls: [URL] { [html, json] }
}

/// Writes the two dashboard files for the share sheet and removes them afterwards. Nothing here goes on a network.
public enum PublishFileWriter {
    /// Every folder this writer makes starts with this, so a sweep removes only its own.
    public static let folderPrefix = "loopr-publish-"

    public static func write(html: String, json: Data, in base: URL = FileManager.default.temporaryDirectory) throws -> PublishedFiles {
        let folder = base.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = PublishedFiles(folder: folder,
                                   html: folder.appendingPathComponent(PublishHTMLRenderer.fileName),
                                   json: folder.appendingPathComponent(PublishJSONRenderer.fileName))
        do {
            try Data(html.utf8).write(to: files.html, options: .atomic)
            try json.write(to: files.json, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return files
    }

    public static func remove(_ files: PublishedFiles) {
        try? FileManager.default.removeItem(at: files.folder)
    }

    /// Removes publish folders an earlier visit left behind, for example after the app stopped mid-share.
    public static func removeStale(in base: URL = FileManager.default.temporaryDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name, isDirectory: true))
        }
    }
}
