import DesignSystem
import SwiftUI
import UIKit

struct CoachMarkdownBlock: Equatable, Identifiable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case bullet(depth: Int)
        case ordered(number: Int, depth: Int)
        case quote
        case rule
        case code(language: String?)
        case table
    }
    let id: Int
    let kind: Kind
    let text: String
}

/// Turns a model reply into blocks. It handles the Markdown models actually write:
/// headings, nested bullets, numbered lists, quotes, rules, fenced code and pipe tables.
/// Inline styles (bold, italic, code, links) are left to `AttributedString`.
enum CoachMarkdownParser {
    static func parse(_ text: String, streaming: Bool = false) -> [CoachMarkdownBlock] {
        var result: [CoachMarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false
        var listIndents: [Int] = []
        var lastWasList = false

        func append(_ kind: CoachMarkdownBlock.Kind, _ value: String, allowEmpty: Bool = false) {
            guard allowEmpty || !value.isEmpty else { return }
            result.append(.init(id: result.count, kind: kind, text: value))
        }
        func flushParagraph() { append(.paragraph, paragraph.joined(separator: "\n")); paragraph.removeAll() }
        func flushQuote() { append(.quote, quote.joined(separator: "\n")); quote.removeAll() }
        func flushTable() { append(.table, table.joined(separator: "\n")); table.removeAll() }
        func flushText() { flushParagraph(); flushQuote(); flushTable() }
        func depth(for indent: Int) -> Int {
            while let last = listIndents.last, indent < last { listIndents.removeLast() }
            if listIndents.last != indent { listIndents.append(indent) }
            return min(listIndents.count - 1, 3)
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushText(); lastWasList = false; listIndents.removeAll()
                if inCode {
                    append(.code(language: language), code.joined(separator: "\n"), allowEmpty: true)
                    code.removeAll(); language = nil
                } else {
                    let name = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = name.isEmpty ? nil : name
                }
                inCode.toggle(); continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flushText(); continue }

            let indent = line.prefix(while: { $0 == " " }).count
            if isRule(trimmed) {
                flushText(); lastWasList = false; listIndents.removeAll(); append(.rule, "---"); continue
            }
            if trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: " "),
               trimmed[..<separator].allSatisfy({ $0 == "#" }), trimmed[..<separator].count <= 6 {
                flushText(); lastWasList = false; listIndents.removeAll()
                append(.heading(trimmed[..<separator].count), String(trimmed[trimmed.index(after: separator)...])); continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushTable(); lastWasList = false
                quote.append(String(trimmed.dropFirst().drop(while: { $0 == " " }))); continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph(); flushQuote(); lastWasList = false
                if !isTableSeparator(trimmed) { table.append(trimmed) }
                continue
            }
            if let item = bullet(in: trimmed) {
                flushText(); lastWasList = true
                append(.bullet(depth: depth(for: indent)), item); continue
            }
            if let (number, item) = ordered(in: trimmed) {
                flushText(); lastWasList = true
                append(.ordered(number: number, depth: depth(for: indent)), item); continue
            }
            if lastWasList, indent > 0, paragraph.isEmpty, let last = result.last, last.kind.isListItem {
                // A wrapped list line belongs to the item above it.
                result[result.count - 1] = .init(id: last.id, kind: last.kind, text: last.text + " " + trimmed); continue
            }
            flushQuote(); flushTable(); lastWasList = false; listIndents.removeAll()
            paragraph.append(line)
        }
        flushText()
        if inCode { append(.code(language: language), code.joined(separator: "\n"), allowEmpty: !code.isEmpty) }
        if streaming, let last = result.last, last.kind.closesInlineMarkers {
            result[result.count - 1] = .init(id: last.id, kind: last.kind, text: closeInlineMarkers(last.text))
        }
        return result
    }

    private final class ParsedBlocks {
        let blocks: [CoachMarkdownBlock]
        init(_ blocks: [CoachMarkdownBlock]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, ParsedBlocks> = {
        let cache = NSCache<NSString, ParsedBlocks>()
        cache.countLimit = 12
        return cache
    }()

    /// `parse`, remembered by text. A row evaluates its body more than once per update, and the
    /// view and the accessibility value both need the blocks, so the text is parsed once.
    static func cachedParse(_ text: String, streaming: Bool = false) -> [CoachMarkdownBlock] {
        let key = ((streaming ? "s" : "c") + text) as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parse(text, streaming: streaming)
        cache.setObject(ParsedBlocks(blocks), forKey: key)
        return blocks
    }

    /// While a reply streams, an opening `**` has no partner yet. Closing it for display keeps
    /// literal asterisks from showing and then snapping into bold.
    static func closeInlineMarkers(_ value: String) -> String {
        var text = value
        if text.components(separatedBy: "**").count % 2 == 0 { text += "**" }
        let withoutStrong = text.replacingOccurrences(of: "**", with: "")
        if withoutStrong.filter({ $0 == "*" }).count % 2 == 1 { text += "*" }
        if text.filter({ $0 == "`" }).count % 2 == 1 { text += "`" }
        return text
    }

    /// The reply as plain words, for VoiceOver and for the Copy action's sibling label.
    static func plainText(_ blocks: [CoachMarkdownBlock]) -> String {
        blocks.map { block in
            switch block.kind {
            case .rule: ""
            case .ordered(let number, _): "\(number). " + strip(block.text)
            case .code, .table: block.text
            default: strip(block.text)
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func strip(_ value: String) -> String {
        guard var attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return value }
        attributed.link = nil
        return String(attributed.characters)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }
    private static func isTableSeparator(_ trimmed: String) -> Bool {
        trimmed.allSatisfy { "|-: ".contains($0) } && trimmed.contains("-")
    }
    private static func bullet(in trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        return nil
    }
    private static func ordered(in trimmed: String) -> (Int, String)? {
        let digits = trimmed.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}

private extension CoachMarkdownBlock.Kind {
    var isListItem: Bool {
        switch self { case .bullet, .ordered: true; default: false }
    }
    var closesInlineMarkers: Bool {
        switch self { case .code, .rule, .table: false; default: true }
    }
}

/// Renders a reply. The blocks are parsed once per text, and the row that holds this view only
/// re-evaluates when the text changes, so a streaming reply re-parses one bubble and no others.
struct CoachMarkdownView: View {
    private let blocks: [CoachMarkdownBlock]
    @State private var copiedCode: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(text: String, streaming: Bool = false) {
        blocks = CoachMarkdownParser.cachedParse(text, streaming: streaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level):
                    Text(inline(block.text))
                        .looprTypography(level <= 2 ? .cardTitle : .rowTitle)
                        .foregroundStyle(Color.loopr(.ink))
                        .padding(.top, LooprSpacing.xxs)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let depth):
                    listRow(marker: depth == 0 ? "\u{2022}" : "\u{25E6}", depth: depth, text: block.text)
                case .ordered(let number, let depth):
                    listRow(marker: "\(number).", depth: depth, text: block.text)
                case .quote:
                    HStack(alignment: .top, spacing: LooprSpacing.sm) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.loopr(.brand).opacity(0.6))
                            .frame(width: 3)
                        Text(inline(block.text))
                            .looprTypography(.settingsRow)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .rule:
                    LooprHairline().padding(.vertical, LooprSpacing.xxs)
                case .code(let language):
                    codeBlock(block, language: language)
                case .table:
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(block.text).looprTypography(.metricUnit).foregroundStyle(Color.loopr(.ink))
                    }
                    .padding(LooprSpacing.compactCardVertical)
                    .looprCardBackground(.sunk, density: .flush)
                case .paragraph:
                    Text(inline(block.text))
                        .looprTypography(.settingsRow)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(marker: String, depth: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            Text(marker)
                .looprTypography(.settingsRow)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .monospacedDigit()
                .frame(minWidth: LooprSpacing.sm, alignment: .trailing)
                .accessibilityHidden(true)
            Text(inline(text))
                .looprTypography(.settingsRow)
                .foregroundStyle(Color.loopr(.ink))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * LooprSpacing.md)
    }

    private func codeBlock(_ block: CoachMarkdownBlock, language: String?) -> some View {
        let copied = copiedCode == block.id
        let copyButton = Button {
            UIPasteboard.general.string = block.text
            copiedCode = block.id
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(.brandInk))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Code copied" : "Copy code")
        @ViewBuilder var label: some View {
            if let language { Text(language).looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary)) }
        }
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Large text wraps instead of scrolling, and Copy gets its own row.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: LooprSpacing.xs) {
                        label
                        Spacer(minLength: 0)
                        copyButton
                    }
                    Text(block.text)
                        .looprTypography(.metricUnit)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, LooprSpacing.compactCardVertical)
                }
                .padding(.horizontal, LooprSpacing.compactCardHorizontal)
            } else {
                HStack(alignment: .top, spacing: LooprSpacing.xs) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        label
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(block.text)
                                .looprTypography(.metricUnit)
                                .foregroundStyle(Color.loopr(.ink))
                        }
                    }
                    .padding(.vertical, LooprSpacing.compactCardVertical)
                    copyButton
                }
                .padding(.leading, LooprSpacing.compactCardHorizontal)
            }
        }
        .looprCardBackground(.sunk, density: .flush)
        .task(id: copiedCode) {
            guard copiedCode != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copiedCode = nil
        }
    }

    /// Links in a reply are untrusted text. They render as plain words and are not tappable.
    private func inline(_ value: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(value)
        attributed.link = nil
        return attributed
    }
}
