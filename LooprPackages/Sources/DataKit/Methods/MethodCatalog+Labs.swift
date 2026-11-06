import Foundation

extension MethodCatalog {
    /// Where the range beside a blood value comes from (ICP R2-LAB-20). Loopr sets no range of its own.
    static let labRanges = MethodEntry(
        id: .labRanges, group: .labs, title: "Ranges on your blood tests",
        version: nil,
        summary: "Where the range beside each blood value comes from, and what Loopr does with it.",
        rule: [
            "The range next to a value is the one your lab printed on that report. You type it in, or the scan reads it. Loopr does not set ranges and adds none of its own.",
            "Labs set their ranges from their own methods and the people they measured, so two labs can print different ranges for the same marker. Each report keeps its own range.",
            "When the lab printed both ends and the value is a plain number, Loopr says whether the value sits inside or outside that range. A value printed as a limit, like <0.3, gets no such line.",
            "The lab's flag, like H or L, shows as printed. Loopr never adds a flag."
        ],
        inputs: [
            MethodInput("Range low and high, or the range as printed", from: .labReport, .typed),
            MethodInput("The lab's flag", from: .labReport, .typed)
        ],
        sources: [
            MethodSourceFile("LooprPackages/Sources/DataKit/Labs/LabsDisplay.swift", lines: 45...48, symbol: "LabsDisplay.rangePosition",
                             anchor: "guard value.comparator == nil, let low = value.referenceRange.low, let high = value.referenceRange.high, low <= high else { return nil }"),
            MethodSourceFile("LooprPackages/Sources/DataKit/Labs/LabsDisplay.swift", lines: 99...108, symbol: "LabsDisplay.rangeText",
                             anchor: "if let text = range.text, !text.isEmpty { return text }"),
            MethodSourceFile(MethodPaths.analytics + "Labs/LabModels.swift", lines: 100...104, symbol: "LabReferenceRange",
                             anchor: "public struct LabReferenceRange: Sendable, Hashable {")
        ],
        testSuites: [
            MethodTestSuite("LabsListModelTests", in: "LooprPackages/Tests/DataKitTests/Labs/LabsListModelTests.swift")
        ],
        limits: [
            "A lab range describes the people that lab measured. It is not a target, and a value inside it can still be worth asking your doctor about.",
            "Loopr has no range of its own for any marker. If it ever adds one, this page will say who set it and where it comes from.",
            "A range typed in wrong reads wrong. Check it against the report."
        ],
        showsMedicalLine: true)
}
