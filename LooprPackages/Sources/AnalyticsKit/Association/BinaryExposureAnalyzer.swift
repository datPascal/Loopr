import Foundation

public struct BinaryExposureRow: Equatable, Sendable {
    public let dayOrdinal: Int
    public let outcome: Double
    public let exposure: Bool
    public let weekday: Int
    public let priorDayStrain: Double?
    public let nuisanceExposures: [Double]

    public init(
        dayOrdinal: Int,
        outcome: Double,
        exposure: Bool,
        weekday: Int,
        priorDayStrain: Double?,
        nuisanceExposures: [Double] = []
    ) {
        self.dayOrdinal = dayOrdinal
        self.outcome = outcome
        self.exposure = exposure
        self.weekday = weekday
        self.priorDayStrain = priorDayStrain
        self.nuisanceExposures = nuisanceExposures
    }
}

public struct BinaryExposureBaselineValue: Equatable, Sendable {
    public let dayOrdinal: Int
    public let value: Double
    public init(dayOrdinal: Int, value: Double) { self.dayOrdinal = dayOrdinal; self.value = value }
}

public struct BinaryExposurePolicy: Equatable, Sendable {
    public let baselineWindowDays: Int
    public let minimumBaselineValues: Int
    public let ridgeLambda: Double
    public let bootstrapReplicates: Int
    public let blockLength: Int

    public init(
        baselineWindowDays: Int,
        minimumBaselineValues: Int,
        ridgeLambda: Double,
        bootstrapReplicates: Int,
        blockLength: Int
    ) {
        self.baselineWindowDays = baselineWindowDays
        self.minimumBaselineValues = minimumBaselineValues
        self.ridgeLambda = ridgeLambda
        self.bootstrapReplicates = bootstrapReplicates
        self.blockLength = blockLength
    }
}

public struct BinaryExposureResult: Equatable, Sendable {
    public let yesMean: Double
    public let noMean: Double
    public let rawDifference: Double
    public let adjustedDifference: Double?
    public let intervalLower: Double?
    public let intervalUpper: Double?
    public let twoSidedPValue: Double?
    public let adjustedRowCount: Int

    public init(
        yesMean: Double,
        noMean: Double,
        rawDifference: Double,
        adjustedDifference: Double?,
        intervalLower: Double?,
        intervalUpper: Double?,
        twoSidedPValue: Double?,
        adjustedRowCount: Int
    ) {
        self.yesMean = yesMean
        self.noMean = noMean
        self.rawDifference = rawDifference
        self.adjustedDifference = adjustedDifference
        self.intervalLower = intervalLower
        self.intervalUpper = intervalUpper
        self.twoSidedPValue = twoSidedPValue
        self.adjustedRowCount = adjustedRowCount
    }
}

public enum BinaryExposureError: Error, Equatable, Sendable {
    case emptyInput
    case nonFiniteValue
    case missingExposureClass
    case inconsistentNuisanceColumns
    case singularModel
    case cancelled
}

public enum BinaryExposureAnalyzer {
    public static func analyze(
        rows: [BinaryExposureRow],
        baselineValues: [BinaryExposureBaselineValue],
        policy: BinaryExposurePolicy,
        seed: UInt64,
        cancellationCheck: @Sendable () throws -> Void = {}
    ) throws -> BinaryExposureResult {
        guard !rows.isEmpty else { throw BinaryExposureError.emptyInput }
        guard rows.allSatisfy({ $0.outcome.isFinite && ($0.priorDayStrain?.isFinite ?? true) }) else {
            throw BinaryExposureError.nonFiniteValue
        }
        let nuisanceCount = rows.first?.nuisanceExposures.count ?? 0
        guard rows.allSatisfy({ $0.nuisanceExposures.count == nuisanceCount && $0.nuisanceExposures.allSatisfy(\.isFinite) }) else {
            throw BinaryExposureError.inconsistentNuisanceColumns
        }
        let yes = rows.filter(\.exposure).map(\.outcome)
        let no = rows.filter { !$0.exposure }.map(\.outcome)
        guard !yes.isEmpty, !no.isEmpty else { throw BinaryExposureError.missingExposureClass }
        let yesMean = mean(yes)
        let noMean = mean(no)

        let adjustedRows = residualizedRows(
            rows: rows,
            baselineValues: baselineValues,
            window: policy.baselineWindowDays,
            minimum: policy.minimumBaselineValues
        )
        guard let effect = try fitTargetEffect(rows: adjustedRows, lambda: policy.ridgeLambda) else {
            return BinaryExposureResult(
                yesMean: yesMean,
                noMean: noMean,
                rawDifference: yesMean - noMean,
                adjustedDifference: nil,
                intervalLower: nil,
                intervalUpper: nil,
                twoSidedPValue: nil,
                adjustedRowCount: adjustedRows.count
            )
        }

        let replicates = max(0, policy.bootstrapReplicates)
        var bootstrapEffects: [Double] = []
        bootstrapEffects.reserveCapacity(replicates)
        var generator = SplitMix64(seed: seed)
        if adjustedRows.count >= 2, replicates > 0 {
            for replicate in 0..<replicates {
                if replicate.isMultiple(of: 32) { try cancellationCheck() }
                let sample = movingBlockSample(
                    adjustedRows,
                    blockLength: max(1, policy.blockLength),
                    generator: &generator
                )
                if let value = try fitTargetEffect(rows: sample, lambda: policy.ridgeLambda), value.isFinite {
                    bootstrapEffects.append(value)
                }
            }
        }
        bootstrapEffects.sort()
        let lower = percentile(bootstrapEffects, probability: 0.025)
        let upper = percentile(bootstrapEffects, probability: 0.975)
        let pValue: Double? = bootstrapEffects.isEmpty ? nil : {
            let atOrBelowZero = Double(bootstrapEffects.filter { $0 <= 0 }.count) / Double(bootstrapEffects.count)
            let atOrAboveZero = Double(bootstrapEffects.filter { $0 >= 0 }.count) / Double(bootstrapEffects.count)
            return min(1, 2 * min(atOrBelowZero, atOrAboveZero))
        }()
        return BinaryExposureResult(
            yesMean: yesMean,
            noMean: noMean,
            rawDifference: yesMean - noMean,
            adjustedDifference: effect,
            intervalLower: lower,
            intervalUpper: upper,
            twoSidedPValue: pValue,
            adjustedRowCount: adjustedRows.count
        )
    }

    public static func phiAndDiscordance(
        target: [Bool],
        other: [Bool]
    ) -> (phi: Double?, targetYesOtherNo: Int, targetNoOtherYes: Int) {
        guard target.count == other.count, !target.isEmpty else { return (nil, 0, 0) }
        var bothYes = 0, targetOnly = 0, otherOnly = 0, bothNo = 0
        for (lhs, rhs) in zip(target, other) {
            switch (lhs, rhs) {
            case (true, true): bothYes += 1
            case (true, false): targetOnly += 1
            case (false, true): otherOnly += 1
            case (false, false): bothNo += 1
            }
        }
        let denominator = sqrt(
            Double((bothYes + targetOnly) * (otherOnly + bothNo) * (bothYes + otherOnly) * (targetOnly + bothNo))
        )
        let phi = denominator == 0 ? nil : Double(bothYes * bothNo - targetOnly * otherOnly) / denominator
        return (phi, targetOnly, otherOnly)
    }

    public static func holmAdjusted(_ pValues: [Double?]) -> [Double?] {
        let valid = pValues.enumerated().compactMap { index, value -> (Int, Double)? in
            guard let value, value.isFinite else { return nil }
            return (index, min(1, max(0, value)))
        }.sorted { $0.1 < $1.1 }
        var output = Array<Double?>(repeating: nil, count: pValues.count)
        var running = 0.0
        for (rank, pair) in valid.enumerated() {
            let adjusted = min(1, pair.1 * Double(valid.count - rank))
            running = max(running, adjusted)
            output[pair.0] = running
        }
        return output
    }

    public static func deterministicSeed(_ components: [String]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in components.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private struct AdjustedRow: Equatable, Sendable {
        let residual: Double
        let exposure: Bool
        let weekday: Int
        let priorDayStrain: Double?
        let nuisanceExposures: [Double]
    }

    private static func residualizedRows(
        rows: [BinaryExposureRow],
        baselineValues: [BinaryExposureBaselineValue],
        window: Int,
        minimum: Int
    ) -> [AdjustedRow] {
        let sortedBaseline = baselineValues
            .filter { $0.value.isFinite }
            .sorted { $0.dayOrdinal < $1.dayOrdinal }
        return rows.sorted { $0.dayOrdinal < $1.dayOrdinal }.compactMap { row in
            let prior = sortedBaseline
                .filter { $0.dayOrdinal < row.dayOrdinal && $0.dayOrdinal >= row.dayOrdinal - window }
                .map(\.value)
            guard prior.count >= minimum else { return nil }
            return AdjustedRow(
                residual: row.outcome - mean(prior),
                exposure: row.exposure,
                weekday: row.weekday,
                priorDayStrain: row.priorDayStrain,
                nuisanceExposures: row.nuisanceExposures
            )
        }
    }

    private static func fitTargetEffect(rows: [AdjustedRow], lambda: Double) throws -> Double? {
        guard rows.count >= 2,
              rows.contains(where: \.exposure),
              rows.contains(where: { !$0.exposure })
        else { return nil }
        let strains = rows.compactMap(\.priorDayStrain)
        let medianStrain = median(strains) ?? 0
        let filledStrains = rows.map { $0.priorDayStrain ?? medianStrain }
        let strainMean = mean(filledStrains)
        let strainSD = sqrt(mean(filledStrains.map { ($0 - strainMean) * ($0 - strainMean) }))
        let nuisanceCount = rows.first?.nuisanceExposures.count ?? 0
        let columnCount = 1 + 1 + 6 + 2 + nuisanceCount
        var x: [[Double]] = []
        x.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            var vector = [1.0, row.exposure ? 1.0 : 0.0]
            vector.append(contentsOf: (1...6).map { row.weekday == $0 ? 1.0 : 0.0 })
            vector.append(strainSD > 0 ? (filledStrains[index] - strainMean) / strainSD : 0)
            vector.append(row.priorDayStrain == nil ? 1 : 0)
            vector.append(contentsOf: row.nuisanceExposures)
            x.append(vector)
        }
        var normal = Array(repeating: Array(repeating: 0.0, count: columnCount), count: columnCount)
        var rhs = Array(repeating: 0.0, count: columnCount)
        for (vector, row) in zip(x, rows) {
            for i in 0..<columnCount {
                rhs[i] += vector[i] * row.residual
                for j in 0..<columnCount { normal[i][j] += vector[i] * vector[j] }
            }
        }
        if columnCount > 2 {
            for column in 2..<columnCount { normal[column][column] += lambda }
        }
        guard let coefficients = solve(normal, rhs: rhs) else { return nil }
        return coefficients[1]
    }

    private static func solve(_ matrix: [[Double]], rhs: [Double]) -> [Double]? {
        let count = rhs.count
        guard matrix.count == count, matrix.allSatisfy({ $0.count == count }) else { return nil }
        var augmented = zip(matrix, rhs).map { $0 + [$1] }
        for pivot in 0..<count {
            guard let row = (pivot..<count).max(by: { abs(augmented[$0][pivot]) < abs(augmented[$1][pivot]) }),
                  abs(augmented[row][pivot]) > 1e-12 else { return nil }
            if row != pivot { augmented.swapAt(row, pivot) }
            let divisor = augmented[pivot][pivot]
            for column in pivot...count { augmented[pivot][column] /= divisor }
            for rowIndex in 0..<count where rowIndex != pivot {
                let factor = augmented[rowIndex][pivot]
                guard factor != 0 else { continue }
                for column in pivot...count {
                    augmented[rowIndex][column] -= factor * augmented[pivot][column]
                }
            }
        }
        return augmented.map { $0[count] }
    }

    private static func movingBlockSample(
        _ rows: [AdjustedRow],
        blockLength: Int,
        generator: inout SplitMix64
    ) -> [AdjustedRow] {
        var output: [AdjustedRow] = []
        output.reserveCapacity(rows.count)
        while output.count < rows.count {
            let start = Int(generator.next() % UInt64(rows.count))
            for offset in 0..<blockLength where output.count < rows.count {
                output.append(rows[(start + offset) % rows.count])
            }
        }
        return output
    }

    private static func percentile(_ values: [Double], probability: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let position = probability * Double(values.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return values[lower] }
        let fraction = position - Double(lower)
        return values[lower] * (1 - fraction) + values[upper] * fraction
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
