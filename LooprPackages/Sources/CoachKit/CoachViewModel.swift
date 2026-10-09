import Combine
import Foundation
import DomainKit
import DesignSystem

public enum CoachLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
public final class CoachViewModel: ObservableObject {
    @Published public private(set) var loadState: CoachLoadState = .idle
    @Published public private(set) var decision: CoachDecision?
    @Published public private(set) var history: [CoachDecision] = []

    private let service: CoachService
    /// The day the screen actually asked for, so "Try again" retries that day
    /// rather than whichever day the retry button happens to name.
    private var lastRequestedDay: DayIdentity?

    public init(service: CoachService) { self.service = service }

    /// Retries the last requested day. Does nothing before a first load.
    public func reload() async {
        guard let lastRequestedDay else { return }
        await load(day: lastRequestedDay)
    }

    public func load(day: DayIdentity) async {
        lastRequestedDay = day
        loadState = .loading
        do {
            decision = try await service.evaluate(for: day)
            history = try await service.recentHistory()
            loadState = .loaded
        } catch is CancellationError {
            loadState = .idle
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    public func deleteAllData() async {
        do {
            try await service.deleteAllData()
            decision = nil
            history = []
            loadState = .idle
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}
