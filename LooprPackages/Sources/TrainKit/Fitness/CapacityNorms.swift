import AnalyticsKit
import Foundation

/// Where a capacity result sits among people of the same age and sex in a published study (R2-VET-06, R1-VET-05,
/// R2-NEW-19). Every number is copied from the paper named in `source`; `docs/research/2026-11-03-capacity-test-norms.md`
/// holds the tables and their limits. A band describes the people a study tested. It is not a target or a diagnosis,
/// and the line says which study, so it never reads as Loopr's own judgement.
public struct CapacityNorm: Equatable, Sendable {
    /// "Men aged 45: median 49 kg, middle half 42 to 56 kg. Yours is above the median."
    public let line: String
    /// "Dodds 2014, 12 British studies. A population band, not a target." Nil when there is no comparison.
    public let source: String?

    public static let noNorm = "No published norm for adults your age."
    public static let needsAge = "Add your birth year in Profile to compare with people your age."
    public static let needsSex = "Add your sex in Profile to compare. The published tables are split by sex."
    static let caveat = "A population band, not a target."

    /// Nil for heart rate recovery, which has its own reading on the workout.
    public static func make(kind: CapacityTestKind, best: Double?, age: Int?, group: FriendReferenceGroup?) -> CapacityNorm? {
        switch kind {
        case .heartRateRecovery: return nil
        case .deadHang: return CapacityNorm(line: noNorm, source: "No peer-reviewed adult norms by age were found for a dead hang.")
        case .grip, .sitToStand, .oneLegBalance: break
        }
        guard let age else { return CapacityNorm(line: needsAge, source: nil) }
        switch kind {
        case .grip: return grip(best: best, age: age, group: group)
        case .sitToStand: return sitToStand(best: best, age: age, group: group)
        case .oneLegBalance: return balance(best: best, age: age)
        case .deadHang, .heartRateRecovery: return nil
        }
    }

    static func groupWord(_ group: FriendReferenceGroup) -> String { group == .male ? "Men" : "Women" }

    // MARK: Grip, Dodds 2014

    /// P25, P50 and P75 in kg at ages 20, 25 ... 90 (Dodds 2014, Table 2).
    static let gripMen: [(age: Int, p25: Double, p50: Double, p75: Double)] = [
        (20, 35, 40, 46), (25, 41, 48, 55), (30, 44, 51, 58), (35, 45, 51, 58), (40, 44, 50, 57), (45, 42, 49, 56),
        (50, 41, 48, 54), (55, 40, 47, 53), (60, 39, 45, 51), (65, 37, 43, 48), (70, 34, 39, 44), (75, 31, 35, 41),
        (80, 27, 32, 37), (85, 24, 29, 33), (90, 20, 25, 29)
    ]
    static let gripWomen: [(age: Int, p25: Double, p50: Double, p75: Double)] = [
        (20, 24, 28, 32), (25, 26, 30, 35), (30, 27, 31, 35), (35, 27, 31, 35), (40, 27, 31, 35), (45, 26, 30, 34),
        (50, 25, 29, 33), (55, 23, 28, 32), (60, 22, 27, 31), (65, 21, 25, 29), (70, 20, 24, 27), (75, 18, 21, 25),
        (80, 16, 19, 23), (85, 14, 17, 20), (90, 11, 14, 17)
    ]

    static func grip(best: Double?, age: Int, group: FriendReferenceGroup?) -> CapacityNorm {
        guard let group else { return CapacityNorm(line: needsSex, source: nil) }
        guard (18...92).contains(age) else { return CapacityNorm(line: noNorm, source: nil) }
        let rows = group == .male ? gripMen : gripWomen
        // The paper prints exact ages five years apart; the nearest row stands for the ages around it.
        guard let row = rows.min(by: { abs($0.age - age) < abs($1.age - age) }) else { return CapacityNorm(line: noNorm, source: nil) }
        func kg(_ value: Double) -> String { String(Int(value)) }
        // The paper prints one row every five years, so the line names the row it used when that is not your age.
        let ageNote = row.age == age ? "" : " in the table (you are \(age))"
        var line = "\(groupWord(group)) aged \(row.age)\(ageNote): median \(kg(row.p50)) kg, middle half \(kg(row.p25)) to \(kg(row.p75)) kg."
        if let best {
            let place = best >= row.p75 ? "in the top quarter" : best >= row.p50 ? "above the median"
                : best >= row.p25 ? "below the median, in the middle half" : "in the bottom quarter"
            line += " Yours is \(place)."
        }
        return CapacityNorm(line: line, source: "Dodds 2014, 12 British studies, best hand. \(caveat)")
    }

    // MARK: Sitting-rising test, Araújo 2020

    /// For each age band, the lowest score in the second, third and top quarter (Araújo 2020, Figure 1). Nil where the
    /// chart has no such band: no top quarter up to 45, no second quarter for men 51 to 55. A first value of 0 means
    /// the chart has no bottom quarter for that band.
    static let sitToStandMen: [(ages: ClosedRange<Int>, q2: Double?, q3: Double, q4: Double?)] = [
        (16...20, 8.5, 10, nil), (21...25, 9, 10, nil), (26...30, 9, 9.5, nil), (31...35, 8.5, 9, nil),
        (36...40, 8.5, 9, nil), (41...45, 8, 8.5, nil), (46...50, 8, 8.5, 10), (51...55, nil, 8, 9.5),
        (56...60, 7.5, 8, 9), (61...65, 6.5, 8, 8.5), (66...70, 5, 7.5, 8.5), (71...75, 3, 6, 8),
        (76...80, 1, 4, 6.5), (81...85, 0, 3, 5.5), (86...120, 0, 0.5, 4)
    ]
    static let sitToStandWomen: [(ages: ClosedRange<Int>, q2: Double?, q3: Double, q4: Double?)] = [
        (16...20, 9, 10, nil), (21...25, 9.5, 10, nil), (26...30, 9.5, 10, nil), (31...35, 9, 10, nil),
        (36...40, 9, 10, nil), (41...45, 8.5, 9.5, nil), (46...50, 8, 9, 10), (51...55, 7.5, 8.5, 10),
        (56...60, 7, 8, 9.5), (61...65, 5.5, 7, 8.5), (66...70, 3, 6, 8.5), (71...75, 1.5, 3.5, 6.5),
        (76...80, 0, 1.5, 3.5), (81...85, 0, 1, 2.5), (86...120, 0, 0.5, 1.5)
    ]

    static func sitToStand(best: Double?, age: Int, group: FriendReferenceGroup?) -> CapacityNorm {
        guard let group else { return CapacityNorm(line: needsSex, source: nil) }
        let rows = group == .male ? sitToStandMen : sitToStandWomen
        guard let row = rows.first(where: { $0.ages.contains(age) }) else { return CapacityNorm(line: noNorm, source: nil) }
        let ages = row.ages.upperBound > 100 ? "over 85" : "aged \(row.ages.lowerBound) to \(row.ages.upperBound)"
        let median = row.q3.formatted(.number.precision(.fractionLength(0...1)).locale(FitnessOverview.numberLocale))
        var line = "\(groupWord(group)) \(ages): \(median) or more is at or above the median."
        if let best {
            let place: String
            if let q4 = row.q4, best >= q4 { place = "in the top quarter" }
            else if best >= row.q3 { place = "at or above the median" }
            else if let q2 = row.q2, best >= q2 || q2 == 0 { place = "in the second quarter, below the median" }
            else { place = "in the bottom quarter" }
            line += " Yours is \(place)."
        }
        return CapacityNorm(line: line, source: "Araújo 2020, 6,141 adults at one clinic in Rio de Janeiro. \(caveat)")
    }

    // MARK: One-leg balance, Springer 2007

    /// The mean and spread of the best of three eyes-closed trials, both sexes (Springer 2007, Table 1). The paper gives
    /// no centiles, so the line names the group average and how wide the spread is, nothing finer.
    static let balanceEyesClosed: [(ages: ClosedRange<Int>, mean: Double, spread: Double)] = [
        (18...39, 15.2, 13.3), (40...49, 12.7, 12.9), (50...59, 8.3, 8.4), (60...69, 4.4, 5.1), (70...79, 3.1, 4.5),
        (80...99, 1.9, 1.0)
    ]

    static func balance(best: Double?, age: Int) -> CapacityNorm {
        guard let row = balanceEyesClosed.first(where: { $0.ages.contains(age) }) else { return CapacityNorm(line: noNorm, source: nil) }
        func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(FitnessOverview.numberLocale)) }
        var line = "Ages \(row.ages.lowerBound) to \(row.ages.upperBound), eyes closed: average \(seconds(row.mean)) s, "
            + "spread about \(seconds(row.spread)) s either way."
        if let best {
            line += best >= row.mean + row.spread ? " Yours is well above the average."
                : best >= row.mean ? " Yours is above the average." : " Yours is below the average."
        }
        return CapacityNorm(line: line, source: "Springer 2007, 549 adults, arms crossed, 45 s cap. \(caveat)")
    }
}
