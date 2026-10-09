import Combine
import Foundation
import SwiftUI
import DesignSystem

/// The Heart tab observes the saved day separately from the live sample list.
/// A streamed sample changes this leaf without invalidating the overnight cards.
@MainActor
final class HeartDayPresentation: ObservableObject {
    @Published private(set) var loadState: HeartLoadState
    @Published private(set) var snapshot: HeartDaySnapshot?
    private var cancellables: Set<AnyCancellable> = []

    init(model: HeartViewModel) {
        loadState = model.loadState
        snapshot = model.snapshot
        model.$loadState.removeDuplicates().sink { [weak self] value in
            guard self?.loadState != value else { return }
            self?.loadState = value
        }.store(in: &cancellables)
        model.$snapshot.removeDuplicates().sink { [weak self] value in
            guard self?.snapshot != value else { return }
            self?.snapshot = value
        }.store(in: &cancellables)
    }
}

struct HeartLiveTabSection: View {
    @ObservedObject var model: HeartViewModel
    @Environment(\.looprBandIndicator) private var bandIndicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let zones: HeartZoneScale?
    let storedReading: HeartLastReading?
    let bandConnected: Bool
    let pinnedNow: Date?
    let open: () -> Void

    /// How long the last live card stays up, dimmed, while the band
    /// reconnects. The app reports a drop as disconnected after the same
    /// window, so the card hands over to the status row exactly then.
    static let reconnectHoldSeconds: TimeInterval = 10

    var body: some View {
        VStack(spacing: LooprSpacing.xs) {
            TimelineView(HeartLiveTickSchedule(fastUntil: tickCutoff)) { context in
                // A new sample redraws the section between ticks, so the
                // clock is read again rather than trusting the last entry.
                let now = max(context.date, Date())
                let slot = slot(at: now)
                ZStack {
                    switch slot {
                    case .card(let reading, let reconnecting):
                        HeartLiveCard(reading: reading, open: open, isReconnecting: reconnecting)
                            .transition(.opacity)
                    case .status:
                        HeartLiveStatusRow(
                            lastReading: newestReading,
                            bandConnected: bandConnected,
                            liveError: model.liveError,
                            now: pinnedNow ?? now,
                            open: open
                        )
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: LooprMotion.standard), value: slot.kind)
            }
            if zones == nil {
                ProfileAgePromptButton(identifier: "heart-profile-age-prompt")
            }
        }
    }

    private enum Slot {
        case card(HeartLiveReading, reconnecting: Bool)
        case status

        var kind: Int {
            switch self {
            case .card: 0
            case .status: 1
            }
        }
    }

    private var newestSampleDate: Date? { model.liveSamples.last?.receivedAt }

    /// The section only needs a once-a-second tick while a sample can still
    /// be on screen. After that it repaints once a minute, which is enough
    /// for "Last reading, 5 min ago".
    private var tickCutoff: Date? {
        newestSampleDate?.addingTimeInterval(HeartLiveReading.staleAfter + Self.reconnectHoldSeconds + 1)
    }

    private func slot(at now: Date) -> Slot {
        if let reading = HeartLiveReading.resolve(samples: model.liveSamples, now: now, zones: zones) {
            return .card(reading, reconnecting: false)
        }
        // A blip keeps the last card on screen, dimmed, instead of swapping
        // to the status row and back a second later.
        if bandIndicator?.link == .reconnecting,
           let newest = newestSampleDate,
           now.timeIntervalSince(newest) <= HeartLiveReading.staleAfter + Self.reconnectHoldSeconds,
           let held = HeartLiveReading.resolve(samples: model.liveSamples, now: newest, zones: zones) {
            return .card(held, reconnecting: true)
        }
        return .status
    }

    private var newestReading: HeartLastReading? {
        let streamed = model.liveSamples.last { ($0.heartRateBPM ?? 0) > 0 }
            .map { HeartLastReading(bpm: $0.heartRateBPM ?? 0, at: $0.receivedAt) }
        switch (storedReading, streamed) {
        case let (stored?, streamed?): return stored.at >= streamed.at ? stored : streamed
        case let (stored?, nil): return stored
        case let (nil, streamed?): return streamed
        default: return nil
        }
    }
}

/// One entry a second until `fastUntil`, then one a minute. Without a band
/// the Heart tab no longer resolves the live reading every second.
struct HeartLiveTickSchedule: TimelineSchedule {
    let fastUntil: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        let cutoff = mode == .lowFrequency ? Date.distantPast : (fastUntil ?? .distantPast)
        return sequence(first: startDate) { previous in
            previous < cutoff ? previous.addingTimeInterval(1) : previous.addingTimeInterval(60)
        }
    }
}
