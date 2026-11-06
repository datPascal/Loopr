import FoodKit
import Foundation

enum Stack {
    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)
    static let day = "2026-10-21"

    static func supplement(_ name: String, amount: Double = 1_000, unit: DoseUnit = .mg, schedule: StackSchedule = .morning,
                           form: SupplementForm = .capsule, active: Bool = true, startDay: String = "2026-01-01",
                           sort: Int = 0, brand: String? = nil, colors: CapsuleColors? = nil, key: String? = nil) throws -> SupplementItem {
        try SupplementItem(key: key, name: name, dose: DoseAmount(amount: amount, unit: unit), form: form, brand: brand, colors: colors,
                           schedule: schedule, isActive: active, startDay: startDay, sortOrder: sort, createdAt: stamp.addingTimeInterval(Double(sort)))
    }

    static func medicine(_ name: String, amount: Double = 10, unit: DoseUnit = .mg, schedule: StackSchedule = .morning,
                         prescriber: String? = "Dr. Weber", notes: String? = nil, active: Bool = true,
                         startDay: String = "2026-01-01", sort: Int = 0) throws -> MedicationItem {
        try MedicationItem(name: name, dose: DoseAmount(amount: amount, unit: unit), prescriber: prescriber, schedule: schedule,
                           notes: notes, isActive: active, startDay: startDay, sortOrder: sort, createdAt: stamp.addingTimeInterval(Double(sort)))
    }

    /// The seven capsules of the Food mockup, morning except Magnesium and Glycine in the evening.
    static func contractStack() throws -> [SupplementItem] {
        let rows: [(String, Double, DoseUnit, StackSchedule, String, String)] = [
            ("D3", 2_000, .iu, .morning, "#E8B84A", "#F4E3A8"), ("Omega-3", 1_000, .mg, .morning, "#D98E3F", "#F2C48B"),
            ("Creatine", 5, .g, .morning, "#EDEDED", "#C9C9C9"), ("B12", 500, .mcg, .morning, "#C8657A", "#F0B3C0"),
            ("Fibre", 5, .g, .morning, "#9CB96B", "#D8E6B5"), ("Glycine", 3, .g, .evening, "#7FB3C8", "#CBE4EE"),
            ("Mg", 300, .mg, .evening, "#8F86C9", "#CFC9EC"),
        ]
        return try rows.enumerated().map { index, row in
            try supplement(row.0, amount: row.1, unit: row.2, schedule: row.3, sort: index, colors: CapsuleColors(first: row.4, second: row.5))
        }
    }
}
