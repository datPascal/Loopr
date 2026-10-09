import Combine
import Foundation
import DomainKit
import DesignSystem

/// What the Sleep tab reads beside the night's snapshot: the overnight heart
/// rate and the person's saved sleep need. Without a saved value the source
/// returns the eight-hour default.
public protocol SleepNightDetailSource: Sendable {
    /// Per-minute heart rate between `start` and `end`, oldest first.
    func overnightHeartRate(from start: Date, to end: Date) async -> [SleepHeartRateMinute]
    /// The saved sleep need in minutes, or the eight-hour default.
    func sleepGoalMinutes() async -> Double?
}

public enum SleepLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
public final class SleepViewModel: ObservableObject {
    @Published public private(set) var loadState: SleepLoadState = .idle
    @Published public private(set) var snapshot: SleepDaySnapshot?
    /// The day the newest `load(day:)` asked for.
    private var requestedDay: DayIdentity?
    @Published public private(set) var corrections: [SleepCorrection] = []
    /// Ranges, ledger, timing and rows for the loaded night, worked out once
    /// per night rather than on every redraw.
    @Published public private(set) var insights: SleepNightInsights?
    /// The loaded night's heart rate, when the band recorded enough of it.
    @Published public private(set) var heartRate: SleepOvernightHeartRate?

    private let repository: any SleepRepository
    private let correctionRepository: (any SleepCorrectionRepository)?
    private let detailSource: (any SleepNightDetailSource)?
    private var goalMinutes: Double?
    private var heartRateWindow: DateInterval?

    public init(repository: any SleepRepository, correctionRepository: (any SleepCorrectionRepository)? = nil,
                detailSource: (any SleepNightDetailSource)? = nil) {
        self.repository = repository
        self.correctionRepository = correctionRepository
        self.detailSource = detailSource
    }

    public func load(day: DayIdentity) async {
        requestedDay = day
        if let shown = snapshot, shown.day != day {
            // Another day's numbers must never sit under this day's label.
            snapshot = nil
            insights = nil
            heartRate = nil
            heartRateWindow = nil
        }
        if snapshot == nil { loadState = .loading }
        do {
            // An identical reload must not republish the night. While history
            // offloads, this screen reloads every few seconds.
            let loaded = try await repository.readSleepDay(for: day)
            // A slower read for a day the person already left must not land
            // on top of the day they moved to.
            guard requestedDay == day else { return }
            let goal = await detailSource?.sleepGoalMinutes()
            guard requestedDay == day else { return }
            if snapshot != loaded || goal != goalMinutes || (loaded != nil && insights == nil) {
                goalMinutes = goal
                insights = loaded.map { SleepNightInsights(snapshot: $0, goalMinutes: goal) }
                snapshot = loaded
            }
            await loadHeartRate(for: loaded, day: day)
            guard requestedDay == day else { return }
            let history = correctionRepository == nil ? [] : try await correctionRepository!.history(for: day)
            guard requestedDay == day else { return }
            if corrections != history { corrections = history }
            if loadState != .loaded { loadState = .loaded }
        } catch is CancellationError {
            guard requestedDay == day else { return }
            loadState = .idle
        } catch {
            guard requestedDay == day else { return }
            snapshot = nil
            insights = nil
            heartRate = nil
            heartRateWindow = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Reads the night's heart rate once per main sleep window.
    private func loadHeartRate(for snapshot: SleepDaySnapshot?, day: DayIdentity) async {
        guard let main = snapshot?.mainSleep, main.end > main.start, let detailSource else {
            if heartRate != nil { heartRate = nil }
            heartRateWindow = nil
            return
        }
        let window = DateInterval(start: main.start, end: main.end)
        guard window != heartRateWindow else { return }
        let samples = await detailSource.overnightHeartRate(from: main.start, to: main.end)
        guard requestedDay == day else { return }
        heartRateWindow = window
        heartRate = SleepOvernightHeartRate.make(samples: samples, start: main.start, end: main.end)
    }

    public func recordCorrection(
        day: DayIdentity,
        target: String,
        before: String?,
        after: String?,
        reason: String,
        algorithmVersion: String?,
        createdAt: Date
    ) async {
        guard let correctionRepository else {
            loadState = .failed("Corrections are unavailable.")
            return
        }
        let correction = SleepCorrection(day: day, target: target, before: before, after: after, reason: reason, algorithmVersion: algorithmVersion, createdAt: createdAt)
        do {
            try await correctionRepository.append(correction)
            corrections = try await correctionRepository.history(for: day)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    public func deleteAllData() async {
        do {
            try await correctionRepository?.deleteAll()
            snapshot = nil
            insights = nil
            heartRate = nil
            heartRateWindow = nil
            corrections = []
            loadState = .idle
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}
