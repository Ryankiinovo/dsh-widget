import SwiftUI
import Foundation
import AppKit

/// Basic Markdown rendering for chat bubbles.
///
/// The widget intentionally supports a small, predictable subset:
/// paragraphs, headings, bullet/numbered lists, block quotes, fenced code
/// blocks, horizontal rules, and inline emphasis/code/links. Unknown syntax
/// falls back to plain text instead of disappearing.
struct MarkdownMessageText: View {
    let text: String
    /// Assistant messages fill the available width; user bubbles should hug
    /// their text instead of stretching across the whole window.
    var fillWidth: Bool = true

    private var blocks: [MarkdownBlock] {
        MarkdownCache.blocks(for: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let value):
            InlineMarkdownText(text: value, size: 13)

        case .heading(let level, let value):
            InlineMarkdownText(text: value, size: headingSize(level), weight: .bold)
                .padding(.top, level <= 2 ? 2 : 0)

        case .listItem(let marker, let value, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text(marker)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                InlineMarkdownText(text: value, size: 13)
            }
            .padding(.leading, CGFloat(min(indent, 3)) * 10)

        case .code(let language, let value):
            CodeBlockView(language: language, code: value, fillWidth: fillWidth)

        case .quote(let value):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2)
                InlineMarkdownText(text: value, size: 12.5)
                    .foregroundStyle(.secondary)
            }

        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        InlineMarkdownText(text: cell, size: 12, weight: .semibold)
                    }
                }
                Divider()
                    .gridCellColumns(max(header.count, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<max(header.count, 1), id: \.self) { column in
                            InlineMarkdownText(
                                text: column < row.count ? row[column] : "",
                                size: 12
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: 560, alignment: .leading)

        case .rule:
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 15
        case 3: return 14
        default: return 13.5
        }
    }
}

private struct InlineMarkdownText: View {
    let text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        if let attributed = Self.attributed(text, size: size, weight: weight) {
            Text(attributed)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: size, weight: weight))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func attributed(_ text: String, size: CGFloat, weight: Font.Weight) -> AttributedString? {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var value = try? AttributedString(markdown: text, options: options) else {
            return nil
        }

        // AttributedString carries presentation intents but SwiftUI does not
        // always translate all of them. Apply the small set the widget needs.
        let runs = Array(value.runs)
        for run in runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = Font.system(size: size, weight: weight)
            if intent.contains(.stronglyEmphasized) {
                font = font.weight(.semibold)
            }
            if intent.contains(.emphasized) {
                font = font.italic()
            }
            if intent.contains(.code) {
                font = .system(size: max(size - 1, 9), design: .monospaced)
                value[run.range].backgroundColor = Color.primary.opacity(0.08)
            }
            value[run.range].font = font
        }
        return value
    }
}

/// Parsing is memoised. Every stream frame re-renders the transcript, so a
/// long session re-parsed the full Markdown of every finished bubble dozens of
/// times per second. Keyed by the whole string (not a hash) so a cache hit can
/// never show the wrong answer.
private enum MarkdownCache {
    private final class Entry {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private static let storage: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 400
        return cache
    }()

    static func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = storage.object(forKey: key) { return hit.blocks }
        let parsed = MarkdownBlock.parse(text)
        storage.setObject(Entry(parsed), forKey: key)
        return parsed
    }
}

private enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case listItem(marker: String, text: String, indent: Int)
    case code(String?, String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])

    private static let fence = String(repeating: "\u{60}", count: 3)

    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let value = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !value.isEmpty {
                blocks.append(.paragraph(value))
            }
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix(fence) {
                flushParagraph()
                let language = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language.isEmpty ? nil : language, code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading.0, heading.1))
                index += 1
                continue
            }

            if let header = tableCells(trimmed),
               index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, let cells = tableCells(candidate) else { break }
                    rows.append(cells)
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let item = listItem(trimmed, raw: raw) {
                flushParagraph()
                blocks.append(.listItem(marker: item.0, text: item.1, indent: item.2))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var value = String(candidate.dropFirst())
                    if value.hasPrefix(" ") { value.removeFirst() }
                    quote.append(value)
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            paragraph.append(raw)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    /// Split a pipe-table row into cells. Leading/trailing pipes are optional.
    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var body = trimmed
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    /// A separator row is made of dashes, optionally with alignment colons.
    private static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableCells(line), !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.replacingOccurrences(of: ":", with: "")
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact == "---" || compact == "***" || compact == "___"
    }

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let value = rest.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (level, value)
    }

    private static func listItem(_ line: String, raw: String) -> (String, String, Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
            return ("•", value, indent)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first, first.count >= 2 else { return nil }
        guard first.hasSuffix(".") || first.hasSuffix(")") else { return nil }
        let number = first.dropLast()
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber }) else { return nil }
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
        return (String(first), value, indent)
    }
}

/// Fenced code block with a language tag and a one-tap copy button.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    var fillWidth: Bool = true
    @StateObject private var feedback = CopyFeedback()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button {
                    feedback.copy(code)
                } label: {
                    Image(systemName: feedback.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("复制代码")
            }
            Text(code.isEmpty ? " " : code)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

