import SwiftUI

/// One piece of a typeset formula. The kind sets its colour and how VoiceOver reads it.
public struct LooprFormulaToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A named quantity, such as `M` or `HRV`.
        case variable
        /// A constant from the code or the paper, such as `141.50`.
        case number
        /// `=`, `+`, `−`, `·`, `/`, brackets.
        case `operator`
        /// A function name, such as `ln` or `median`.
        case function
        /// Plain words inside a formula, such as "of the 9 markers".
        case text
    }

    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public static func variable(_ text: String) -> Self { .init(.variable, text) }
    public static func number(_ text: String) -> Self { .init(.number, text) }
    public static func op(_ text: String) -> Self { .init(.operator, text) }
    public static func function(_ text: String) -> Self { .init(.function, text) }
    public static func text(_ text: String) -> Self { .init(.text, text) }

    /// What VoiceOver says for this token. Symbols become words; brackets are silent.
    public var spoken: String {
        if kind == .function {
            switch text {
            case "ln": return "natural log of"
            case "exp": return "e to the power of"
            case "Σ": return "sum of"
            case "√": return "square root of"
            case "median", "mean", "min", "max", "MAD", "p75": return text + " of"
            default: return text
            }
        }
        guard kind == .operator else { return text }
        switch text {
        case "=": return "equals"
        case "+": return "plus"
        case "−", "-": return "minus"
        case "·", "×", "*": return "times"
        case "/", "÷": return "divided by"
        case "≥": return "at least"
        case "≤": return "at most"
        case "<": return "less than"
        case ">": return "more than"
        case "(", ")", "[", "]", ",": return ""
        case ")²": return "squared"
        case "√": return "square root of"
        case "^": return "to the power of"
        case "Σ": return "sum of"
        default: return text
        }
    }
}

/// One line of a formula: a left side, an equals sign and the expression, as tokens.
public struct LooprFormulaLine: Hashable, Sendable {
    public let tokens: [LooprFormulaToken]

    public init(_ tokens: [LooprFormulaToken]) {
        self.tokens = tokens
    }

    /// The line as it is set, with the spacing the formula view uses: a thin gap around operators,
    /// none inside brackets.
    public var plainText: String {
        var result = ""
        for (index, token) in tokens.enumerated() {
            if Self.spaced(tokens, at: index) { result += " " }
            result += token.text
        }
        return result
    }

    /// The line read aloud, operators as words.
    public var spokenText: String {
        tokens.map(\.spoken).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether a space goes before the token at `index`.
    static func spaced(_ tokens: [LooprFormulaToken], at index: Int) -> Bool {
        guard index > 0 else { return false }
        let token = tokens[index], previous = tokens[index - 1]
        if token.text.hasPrefix(")") || token.text == "," || previous.text == "(" { return false }
        // A sign straight after an opening bracket or at the start is unary: "(−0.00553".
        if previous.kind == .operator, ["−", "-"].contains(previous.text),
           index == 1 || tokens[index - 2].text == "(" { return false }
        if token.text == "(" { return previous.kind == .operator || previous.kind == .text }
        return true
    }
}

/// A formula typeset in the app's own type, one line per row, inside a card.
///
/// Numbers are set in the accent, operators in secondary ink and words in ink, so a reader can
/// tell the constants from the inputs. The caption under it says what each symbol means.
///
/// ```swift
/// LooprFormula(lines: [LooprFormulaLine([.variable("PhenoAge"), .op("="), .number("141.50"), .op("+"),
///                                         .function("ln"), .op("("), .variable("M"), .op(")")])],
///              caption: "M is a mortality score.", identifier: "method-formula")
/// ```
///
/// - Lines wrap at accessibility text sizes rather than clip.
/// - VoiceOver reads each line with operators as words, then the caption.
public struct LooprFormula: View {
    private let lines: [LooprFormulaLine]
    private let caption: String?
    private let accent: LooprColorToken
    private let identifier: String

    public init(lines: [LooprFormulaLine], caption: String? = nil, accent: LooprColorToken = .brand,
                identifier: String) {
        self.lines = lines
        self.caption = caption
        self.accent = accent
        self.identifier = identifier
    }

    public var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(attributed(line))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(line.spokenText)
                }
                if let caption {
                    LooprText(caption, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func attributed(_ line: LooprFormulaLine) -> AttributedString {
        var result = AttributedString()
        for (index, token) in line.tokens.enumerated() {
            if LooprFormulaLine.spaced(line.tokens, at: index) {
                result += AttributedString(" ")
            }
            var run = AttributedString(token.text)
            run.font = LooprTextStyle.metricValue.font
            run.foregroundColor = Color.loopr(color(for: token.kind))
            result += run
        }
        return result
    }

    private func color(for kind: LooprFormulaToken.Kind) -> LooprColorToken {
        switch kind {
        case .variable, .function: .ink
        case .number: accent.textInk
        case .operator: .inkSecondary
        case .text: .inkSecondary
        }
    }
}
