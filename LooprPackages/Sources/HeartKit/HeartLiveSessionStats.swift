import Foundation
import DomainKit

/// Small, incremental session summary. The chart keeps only recent samples;
/// these totals keep the whole foreground stream without a growing array.
public struct HeartLiveSessionStats: Equatable, Sendable {
    public static let sessionGapSeconds: TimeInterval = 30 * 60
    public private(set) var startedAt: Date?
    public private(set) var count = 0
    public private(set) var totalBPM = 0.0
    public private(set) var maximumBPM: Double?
    private var last: (date: Date, bpm: Double)?
    private var secondsByBPM = [Int: TimeInterval]()

    public init() {}

    public var averageBPM: Double? { count > 0 ? totalBPM / Double(count) : nil }

    public func elapsed(at now: Date) -> TimeInterval {
        startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    public func seconds(in zone: Int, zones: HeartRateZones) -> TimeInterval {
        secondsByBPM.reduce(0) { total, entry in
            total + (zones.number(for: Double(entry.key)) == zone ? entry.value : 0)
        }
    }

    public mutating func append(_ sample: HeartLiveSample) {
        guard let reading = HeartLiveReading.rate(of: sample) else { return }
        let bpm = reading.bpm
        guard let previous = last, sample.receivedAt > previous.date else {
            if last == nil {
                startedAt = sample.receivedAt
                count = 1
                totalBPM = bpm
                maximumBPM = bpm
                last = (sample.receivedAt, bpm)
            }
            return
        }
        let gap = sample.receivedAt.timeIntervalSince(previous.date)
        if gap > Self.sessionGapSeconds {
            self = Self()
            append(sample)
            return
        }
        if gap <= 3 { secondsByBPM[Int(previous.bpm.rounded()), default: 0] += min(gap, 2) }
        count += 1
        totalBPM += bpm
        maximumBPM = max(maximumBPM ?? bpm, bpm)
        last = (sample.receivedAt, bpm)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.startedAt == rhs.startedAt && lhs.count == rhs.count && lhs.totalBPM == rhs.totalBPM
            && lhs.maximumBPM == rhs.maximumBPM && lhs.last?.date == rhs.last?.date
            && lhs.last?.bpm == rhs.last?.bpm && lhs.secondsByBPM == rhs.secondsByBPM
    }
}
