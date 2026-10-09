import Combine
import Foundation
import DomainKit
import DesignSystem

public enum BodyLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
public final class BodyViewModel: ObservableObject {
    @Published public private(set) var loadState: BodyLoadState = .idle
    @Published public private(set) var snapshot: BodyDaySnapshot?
    /// The daily history behind the week, the load and "vs usual", anchored
    /// on the day on screen. Nil until it has loaded, or without a provider.
    @Published public private(set) var history: BodyHistory?
    /// The day the newest `load(day:)` asked for.
    private var requestedDay: DayIdentity?
    /// The snapshot the current history was read for. History is read once
    /// per day and again only when the day's numbers change.
    private var historySource: BodyDaySnapshot?

    private let repository: any BodyRepository
    /// Where the history comes from. The app sets it before loading.
    public var historyProvider: (any BodyHistoryProviding)?

    public init(repository: any BodyRepository, historyProvider: (any BodyHistoryProviding)? = nil) {
        self.repository = repository
        self.historyProvider = historyProvider
    }

    public func load(day: DayIdentity) async {
        requestedDay = day
        if let shown = snapshot, shown.day != day {
            // Another day's numbers must never sit under this day's label.
            snapshot = nil
        }
        if let history, history.anchor != day {
            self.history = nil
            historySource = nil
        }
        if snapshot == nil { loadState = .loading }
        let provider = historyProvider
        let needsHistory = history == nil
        do {
            // The day and its history are read together and published in the
            // same update, so the week and load sections never pop in late.
            async let freshHistory: BodyHistory? = needsHistory ? provider?.bodyHistory(anchor: day) : nil
            // An identical reload must not republish the day. While history
            // offloads, this screen reloads every few seconds.
            let loaded = try await repository.readBodyDay(for: day)
            var readHistory = await freshHistory
            // A day whose numbers changed (a sync landed) reads its history
            // again; an identical reload does not.
            if readHistory == nil, let provider, let loaded, loaded != historySource, history != nil {
                readHistory = await provider.bodyHistory(anchor: day)
            }
            // A slower read for a day the person already left must not land
            // on top of the day they moved to.
            guard requestedDay == day else { return }
            if let readHistory {
                historySource = loaded
                if history != readHistory { history = readHistory }
            }
            if snapshot != loaded { snapshot = loaded }
            if loadState != .loaded { loadState = .loaded }
        } catch is CancellationError {
            guard requestedDay == day else { return }
            loadState = .idle
        } catch {
            guard requestedDay == day else { return }
            snapshot = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    public func deleteAllData() {
        history = nil
        historySource = nil
        snapshot = nil
        loadState = .idle
    }
}
