import Foundation

/// The Markdown in Claude's plans, split into blocks for display: headings, list items, code and paragraphs.
/// Inline styling (bold, code spans, links) is left to `AttributedString(markdown:)`.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case item(marker: String, indent: Int, text: String)
    case code(String)
    case paragraph(String)
    case rule
}

extension MarkdownBlock {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush()
                blocks.append(.heading(level: hashes, text: String(line.dropFirst(hashes + 1))))
            } else if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                flush()
                blocks.append(.rule)
            } else if let item = listItem(raw) {
                flush()
                blocks.append(item)
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) } // unclosed fence
        flush()
        return blocks
    }

    /// "- x", "* x", "+ x", "1. x" or "1) x", indented by two spaces per level.
    private static func listItem(_ raw: String) -> MarkdownBlock? {
        let indent = raw.prefix { $0 == " " }.count / 2
        let line = raw.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            var text = String(line.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text.removeFirst(4) }
            return .item(marker: marker, indent: indent, text: text)
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .item(marker: digits + ".", indent: indent, text: String(rest.dropFirst(2)))
    }
}
