import Foundation

public enum StoragePerformanceBudget {
    public static let maximumBacklogWindowRecords = 1_024
    public static let maximumCompatibleTransactionRecords = 512
}

public struct BacklogProcessingReport: Equatable, Sendable {
    public let processedRecords: Int
    public let peakWindowRecords: Int
}

public enum BoundedBacklogProcessor {
    public static func process<C: Collection>(
        _ records: C,
        windowSize: Int = StoragePerformanceBudget.maximumBacklogWindowRecords,
        consume: (ArraySlice<C.Element>) throws -> Void
    ) rethrows -> BacklogProcessingReport {
        let size = max(1, windowSize)
        var offset = records.startIndex
        var processed = 0
        var peak = 0
        while offset != records.endIndex {
            let end = records.index(offset, offsetBy: size, limitedBy: records.endIndex) ?? records.endIndex
            let window = Array(records[offset..<end])[...]
            try consume(window)
            peak = max(peak, window.count)
            processed += window.count
            offset = end
        }
        return BacklogProcessingReport(processedRecords: processed, peakWindowRecords: peak)
    }
}

public struct AtomicTransactionBatch: Equatable, Sendable {
    public let boundaryID: String
    public let recordCount: Int

    public init(boundaryID: String, recordCount: Int) {
        self.boundaryID = boundaryID
        self.recordCount = max(0, recordCount)
    }
}

public enum StorageBatchPlanner {
    /// Packs complete token/boundary batches into transactions without ever splitting one.
    /// A single oversized atomic boundary remains one window and is reported truthfully.
    public static func plan(
        _ batches: [AtomicTransactionBatch],
        maximumCompatibleRecords: Int = StoragePerformanceBudget.maximumCompatibleTransactionRecords
    ) -> [[AtomicTransactionBatch]] {
        let limit = max(1, maximumCompatibleRecords)
        var result: [[AtomicTransactionBatch]] = []
        var window: [AtomicTransactionBatch] = []
        var count = 0
        for batch in batches {
            if !window.isEmpty && count + batch.recordCount > limit {
                result.append(window)
                window = []
                count = 0
            }
            window.append(batch)
            count += batch.recordCount
        }
        if !window.isEmpty { result.append(window) }
        return result
    }
}
