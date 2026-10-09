import Foundation
import ProtocolKit
import StorageKit

public enum Gen5CanonicalMapping {
    /// OpenStrap edge@82b094c3:lib/ble/ble_engine.dart:87-113 maps only
    /// v18 into its one-second sample. All absent fields remain nil.
    public static func record(
        from sample: Gen5V18Sample,
        raw: Data,
        calendar: Calendar = .current
    ) -> StoredHistoricalRecord {
        let date = Date(timeIntervalSince1970: TimeInterval(sample.timestampSeconds))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        return StoredHistoricalRecord(
            physiologicalTimestamp: Int64(sample.timestampSeconds),
            bandCounter: sample.recordIndex,
            localDay: day,
            version: 18,
            heartRate: sample.heartRate,
            gravityX: sample.gravityG.count == 3 ? Double(sample.gravityG[0]) : nil,
            gravityY: sample.gravityG.count == 3 ? Double(sample.gravityG[1]) : nil,
            gravityZ: sample.gravityG.count == 3 ? Double(sample.gravityG[2]) : nil,
            rrBeats: sample.rrIntervalsMilliseconds.enumerated().map { index, interval in
                RRBeat(
                    index: index,
                    intervalMilliseconds: Int(interval),
                    timestampMilliseconds: Int64(sample.timestampSeconds) * 1_000
                )
            },
            rawPayload: raw
        )
    }
}
