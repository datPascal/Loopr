import Combine
import Foundation
import DesignSystem

/// Where the log reads and writes. The app implements it over its stores and Apple Health. Typed entries are the
/// only thing Loopr writes; Apple Health is read only.
public protocol BodyLogProviding: Sendable {
    /// The typed entries and the Apple Health samples, with how the Apple Health read went.
    func snapshot(now: Date) async -> BodyLogSnapshot
    /// Stores a typed entry and returns it as stored.
    func save(_ input: BodyLogInput, timeZoneIdentifier: String) async throws -> BodyLogTypedRecord
    func delete(id: UUID) async throws
    /// Puts a deleted entry back with its own id and time, for Undo.
    func restore(_ record: BodyLogTypedRecord) async throws
}

public enum BodyLogLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
}

@MainActor
public final class BodyLogViewModel: ObservableObject {
    @Published public private(set) var snapshot = BodyLogSnapshot.empty
    @Published public private(set) var entries: [BodyLogEntry] = []
    @Published public private(set) var loadState: BodyLogLoadState = .idle
    @Published public var toast: LooprToastContent?
    /// Set when a delete or an undo could not be saved. The sheet shows its own errors.
    @Published public var failure: String?

    private let provider: any BodyLogProviding
    private let now: @Sendable () -> Date
    public let timeZoneIdentifier: String
    private var lastDeleted: BodyLogTypedRecord?

    public init(provider: any BodyLogProviding, timeZoneIdentifier: String = TimeZone.current.identifier,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.timeZoneIdentifier = timeZoneIdentifier
        self.now = now
    }

    public var currentTime: Date { now() }

    public var summary: BodyLogSummary { BodyLogSummary.make(entries) }

    public func load() async {
        if loadState == .idle { loadState = .loading }
        let loaded = await provider.snapshot(now: now())
        guard !Task.isCancelled else { return }
        apply(loaded)
        loadState = .loaded
    }

    /// Saves a checked entry. False when it could not be stored, with `failure` set.
    @discardableResult
    public func save(_ input: BodyLogInput) async -> Bool {
        do {
            _ = try await provider.save(input, timeZoneIdentifier: timeZoneIdentifier)
            failure = nil
            await load()
            return true
        } catch {
            failure = "Loopr could not save this entry. Try again."
            return false
        }
    }

    /// Deletes a typed entry and offers Undo. Apple Health entries have no delete.
    public func delete(_ entry: BodyLogEntry) async {
        guard let id = entry.typedID, let record = snapshot.typed.first(where: { $0.id == id }) else { return }
        do {
            try await provider.delete(id: id)
            lastDeleted = record
            failure = nil
            toast = LooprToastContent("Entry deleted", symbol: "trash.circle.fill", accent: .strain, actionTitle: "Undo")
            await load()
        } catch {
            failure = "Loopr could not delete this entry. Try again."
        }
    }

    public func undoDelete() async {
        guard let record = lastDeleted else { return }
        do {
            try await provider.restore(record)
            lastDeleted = nil
            failure = nil
            await load()
        } catch {
            failure = "Loopr could not bring this entry back. Try again."
        }
    }

    private func apply(_ loaded: BodyLogSnapshot) {
        if snapshot != loaded { snapshot = loaded }
        let merged = BodyLogMerge.entries(typed: loaded.typed, health: loaded.health)
        if entries != merged { entries = merged }
    }
}
