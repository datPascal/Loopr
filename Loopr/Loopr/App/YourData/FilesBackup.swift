import Foundation
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class FilesBackupPreferences {
    nonisolated static let bookmarkKey = "loopr.files-backup.folder.v1"
    nonisolated static let enabledKey = "loopr.files-backup.enabled.v1"
    nonisolated static let lastSuccessKey = "loopr.files-backup.last-success.v1"
    nonisolated static let folderNameKey = "loopr.files-backup.folder-name.v1"
    nonisolated static let allKeys = [bookmarkKey, enabledKey, lastSuccessKey, folderNameKey]
    private let defaults: UserDefaults?
    private(set) var bookmark: Data?
    private(set) var enabled: Bool
    private(set) var lastSuccess: Date?
    private(set) var folderName: String?
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        bookmark = defaults?.data(forKey: Self.bookmarkKey)
        enabled = defaults?.bool(forKey: Self.enabledKey) ?? false
        lastSuccess = defaults?.object(forKey: Self.lastSuccessKey) as? Date
        folderName = defaults?.string(forKey: Self.folderNameKey)
    }
    func clear() {
        enabled = false; bookmark = nil; lastSuccess = nil; folderName = nil
        for key in Self.allKeys { defaults?.removeObject(forKey: key) }
    }
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled && bookmark != nil
        defaults?.set(self.enabled, forKey: Self.enabledKey)
    }
    func select(bookmark: Data, name: String) {
        self.bookmark = bookmark; folderName = name
        defaults?.set(bookmark, forKey: Self.bookmarkKey)
        defaults?.set(name, forKey: Self.folderNameKey)
        lastSuccess = nil
        defaults?.removeObject(forKey: Self.lastSuccessKey)
        setEnabled(true)
    }
    func completed(at date: Date, renewedBookmark: Data?) {
        if let renewedBookmark {
            bookmark = renewedBookmark
            defaults?.set(renewedBookmark, forKey: Self.bookmarkKey)
        }
        lastSuccess = date
        defaults?.set(date, forKey: Self.lastSuccessKey)
    }
    func isDue(at date: Date) -> Bool {
        enabled && bookmark != nil && (lastSuccess.map { date.timeIntervalSince($0) >= 7 * 86_400 } ?? true)
    }
}

nonisolated enum FilesBackupWriter {
    static func bookmark(for folder: URL) throws -> Data {
        guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { folder.stopAccessingSecurityScopedResource() }
        return try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static func save(_ archive: URL, bookmark: Data) throws -> Data? {
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutImplicitStartAccessing], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileWriteNoPermission) }
        defer { folder.stopAccessingSecurityScopedResource() }
        let renewed = stale ? try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        // Unique names never replace a backup the user kept in Files.
        let destination = folder.appendingPathComponent(archive.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString + ".zip")
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
            result = Result { try FileManager.default.copyItem(at: archive, to: target) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        return renewed
    }
}

struct FilesBackupFolderPicker: UIViewControllerRepresentable {
    let selected: (URL) -> Void
    let cancelled: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected, cancelled: cancelled) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL) -> Void
        let cancelled: () -> Void
        init(selected: @escaping (URL) -> Void, cancelled: @escaping () -> Void) { self.selected = selected; self.cancelled = cancelled }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { selected(url) } else { cancelled() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancelled() }
    }
}
