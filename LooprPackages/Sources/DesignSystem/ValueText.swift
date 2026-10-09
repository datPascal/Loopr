import SwiftUI

/// A metric value with its unit words set smaller, so `7 h 42 m` reads as
/// two numbers with small `h` and `m` instead of four equal mono tokens.
///
/// Numbers take `valueStyle` in `color`; words (`h`, `m`, `min`, and the
/// trailing `unit`) take `unitStyle` in secondary ink.
///
/// ```swift
/// LooprValueText("7 h 42 m")                 // durations from LooprUnitFormatter
/// LooprValueText("58", unit: "ms")
/// LooprValueText("8.6", unit: "/21", valueStyle: .metricCompact)
/// ```
public struct LooprValueText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let value: String
    private let unit: String?
    private let valueStyle: LooprTextStyle
    private let unitStyle: LooprTextStyle
    private let color: LooprColorToken

    public init(
        _ value: String,
        unit: String? = nil,
        valueStyle: LooprTextStyle = .metricValue,
        unitStyle: LooprTextStyle = .metricUnit,
        color: LooprColorToken = .ink
    ) {
        self.value = value
        self.unit = unit
        self.valueStyle = valueStyle
        self.unitStyle = unitStyle
        self.color = color
    }

    /// The pieces in order, each flagged as number (true) or word (false).
    /// Exposed for tests.
    static func pieces(_ value: String, unit: String?) -> [(String, Bool)] {
        var result = value.split(separator: " ").map { token in
            (String(token), token.contains { $0.isNumber })
        }
        if let unit, !unit.isEmpty { result.append((unit, false)) }
        return result
    }

    public var body: some View {
        let pieces = Self.pieces(value, unit: unit)
        var text = Text(verbatim: "")
        for (index, piece) in pieces.enumerated() {
            let isNumber = piece.1
            if index > 0 {
                // A thin gap before a unit word, a full gap before the next number.
                let gap = isNumber ? " " : "\u{2009}"
                text = Text("\(text)\(styled(gap, number: false))")
            }
            text = Text("\(text)\(styled(piece.0, number: isNumber))")
        }
        return text
            .lineLimit(1)
            .monospacedDigit()
            // A new reading rolls its digits instead of swapping them.
            .contentTransition(.numericText())
            .animation(LooprMotion.reducesMotion(reduceMotion) ? nil : .smooth(duration: LooprMotion.standard), value: value)
    }

    private func styled(_ string: String, number: Bool) -> Text {
        let style = number ? valueStyle : unitStyle
        return Text(verbatim: string)
            .font(style.font)
            .tracking(style.tracking)
            .foregroundStyle(Color.loopr(number ? color : .inkSecondary))
    }
}
