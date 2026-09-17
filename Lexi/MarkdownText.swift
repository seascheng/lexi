import SwiftUI

// ---------------------------------------------------------------------------
// MarkdownText — the native successor of the React MarkdownRenderer.
//
// Inline syntax (bold, italic, code, links) goes through
// AttributedString(markdown:). Block syntax that the inline parser cannot
// represent (headings, bullet/ordered lists, quotes, fenced code) is
// pre-scanned line by line into attributed runs. Light on purpose: the AI
// outputs here are prose + lists + emphasis, not documents.
// ---------------------------------------------------------------------------

struct MarkdownText: View {
    let content: String
    /// Compact = the vocabulary/review body size; normal = the notebook body.
    var compact = true
    /// Inline = single-line rendering (the collapsed row's translation).
    var inline = false

    private var bodyFontSize: CGFloat { compact ? 13 : 14 }

    var body: some View {
        if inline {
            Text(Self.attributedSingleLine(content, fontSize: bodyFontSize))
                .lineLimit(1)
        } else {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                ForEach(Array(Self.blocks(content, fontSize: bodyFontSize).enumerated()), id: \.offset) { _, block in
                    Text(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Block parsing

    private static func blocks(_ source: String, fontSize: CGFloat) -> [AttributedString] {
        var out: [AttributedString] = []
        var paragraph: [String] = []
        var inFence = false
        var fence: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(attributed(paragraph.joined(separator: "\n"), fontSize: fontSize))
            paragraph = []
        }

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inFence {
                    out.append(codeBlock(fence, fontSize: fontSize))
                    fence = []
                    inFence = false
                } else {
                    flushParagraph()
                    inFence = true
                }
                continue
            }
            if inFence {
                fence.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.hasPrefix("#") {
                flushParagraph()
                let hashes = trimmed.prefix { $0 == "#" }.count
                let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                var attr = attributed(text, fontSize: fontSize)
                let headingSize = fontSize + CGFloat(max(0, 4 - hashes))
                attr.font = .system(size: headingSize, weight: hashes <= 2 ? .semibold : .medium)
                out.append(attr)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                var attr = attributed(String(trimmed.dropFirst(2)), fontSize: fontSize)
                attr.foregroundColor = .primary
                out.append(bullet("•  ") + attr)
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                var attr = attributed(String(trimmed.dropFirst(2)), fontSize: fontSize)
                attr.foregroundColor = .secondary
                out.append(bullet("│  ") + attr)
            } else if trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                flushParagraph()
                let marker = trimmed.prefix { $0 != "." } + "."
                let body = trimmed.drop { $0 != "." }.dropFirst(2)
                out.append(bullet("\(marker)  ") + attributed(String(body), fontSize: fontSize))
            } else {
                paragraph.append(line)
            }
        }
        if inFence, !fence.isEmpty { out.append(codeBlock(fence, fontSize: fontSize)) }
        flushParagraph()
        return out
    }

    private static func bullet(_ marker: String) -> AttributedString {
        var attr = AttributedString(marker)
        attr.foregroundColor = .secondary
        return attr
    }

    private static func codeBlock(_ lines: [String], fontSize: CGFloat) -> AttributedString {
        var attr = AttributedString(lines.joined(separator: "\n"))
        attr.font = .system(size: fontSize - 1, weight: .regular, design: .monospaced)
        attr.foregroundColor = .secondary
        return attr
    }

    /// Inline markdown with GFM-ish intent; unparseable input renders verbatim.
    private static func attributed(_ text: String, fontSize: CGFloat) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
        attr.font = .system(size: fontSize)
        return attr
    }

    /// The collapsed row's single-line translation: inline syntax only,
    /// newlines collapse to spaces so the line truly stays one line.
    private static func attributedSingleLine(_ text: String, fontSize: CGFloat) -> AttributedString {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var attr = (try? AttributedString(
            markdown: flattened,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(flattened)
        attr.font = .system(size: fontSize - 1)
        attr.foregroundColor = .secondary
        return attr
    }
}
