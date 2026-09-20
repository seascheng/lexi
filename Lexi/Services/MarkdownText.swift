import SwiftUI

// ---------------------------------------------------------------------------
// MarkdownText — the app's single markdown engine.
//
// Inline syntax (bold, italic, code, links) goes through the BUILT-IN
// AttributedString(markdown:) parser. Block syntax that the inline parser
// cannot represent (headings, bullet/ordered lists, quotes, fenced code) is
// pre-scanned line by line into typed blocks. Two thin renderers share that
// one scanner: the SwiftUI body (study panes) and the AppKit adapter
// `nsAttributedString` (the result card's streamed text and the review
// answer). Light on purpose: the AI outputs here are prose + lists +
// emphasis, not documents.
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
                    Text(Self.text(block, fontSize: bodyFontSize))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One parsed block. `code` keeps the raw lines (each renderer styles it
    /// its own way); every other case carries a finished inline-parsed
    /// AttributedString with marker prefixes already applied. The heading
    /// keeps its level — the AppKit adapter derives the font size from it.
    enum Block {
        case paragraph(AttributedString)
        case heading(level: Int, AttributedString)
        case list(AttributedString)
        case quote(AttributedString)
        case code([String])
    }

    /// The block payload for the SwiftUI renderer.
    private static func text(_ block: Block, fontSize: CGFloat) -> AttributedString {
        switch block {
        case .paragraph(let attr), .heading(_, let attr),
             .list(let attr), .quote(let attr):
            return attr
        case .code(let lines):
            return codeBlock(lines, fontSize: fontSize)
        }
    }

    // MARK: - AppKit adapter

    /// The same block pipeline as the SwiftUI body, as ONE NSAttributedString
    /// for NSTextView/NSTextField surfaces — the result card's streamed run
    /// text and the review answer. One engine, one look: paragraph spacing,
    /// list head-indent, mono code on a wash.
    static func nsAttributedString(
        _ content: String,
        fontSize: CGFloat,
        baseColor: NSColor,
        secondaryColor: NSColor,
        codeBackground: NSColor
    ) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: fontSize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 4
        bodyStyle.paragraphSpacing = 8
        let listStyle = NSMutableParagraphStyle()
        listStyle.lineSpacing = 3
        listStyle.headIndent = 18

        let out = NSMutableAttributedString()
        for (index, block) in blocks(content, fontSize: fontSize).enumerated() {
            if index > 0 {
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont, .foregroundColor: baseColor,
                ]))
            }
            let start = out.length
            switch block {
            case .paragraph(let source), .heading(_, let source),
                 .list(let source), .quote(let source):
                let headingLevel = if case .heading(let level, _) = block { level } else { 0 }
                let converted = NSMutableAttributedString(tinted(source, base: Color(baseColor)))
                let full = NSRange(location: 0, length: converted.length)
                // Base font for the whole block (heading scale from the
                // level), then real bold/italic/mono over the inline runs:
                // the parser records those as presentation intents, which
                // neither the NSAttributedString conversion nor a SwiftUI
                // Font would render on AppKit surfaces.
                let baseFont = headingLevel > 0
                    ? NSFont.systemFont(
                        ofSize: fontSize + CGFloat(max(0, 4 - headingLevel)),
                        weight: headingLevel <= 2 ? .semibold : .medium)
                    : bodyFont
                converted.addAttribute(.font, value: baseFont, range: full)
                let intentFonts: [(NSRange, NSFont, Bool)] = source.runs.compactMap { run -> (NSRange, NSFont, Bool)? in
                    let intent = run.inlinePresentationIntent ?? []
                    guard !intent.isEmpty else { return nil }
                    var font = baseFont
                    if intent.contains(.stronglyEmphasized) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    }
                    if intent.contains(.emphasized) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    let isCode = intent.contains(.code)
                    if isCode { font = monoFont }
                    let range = NSRange(run.range, in: source)
                    return (range, font, isCode)
                }
                for (range, font, isCode) in intentFonts {
                    converted.addAttribute(.font, value: font, range: range)
                    if isCode {
                        converted.addAttribute(.backgroundColor, value: codeBackground, range: range)
                    }
                }
                out.append(converted)
            case .code(let lines):
                out.append(NSAttributedString(
                    string: lines.joined(separator: "\n"),
                    attributes: [
                        .font: monoFont,
                        .foregroundColor: secondaryColor,
                        .backgroundColor: codeBackground,
                    ]
                ))
            }
            let style: NSParagraphStyle
            switch block {
            case .list, .quote: style = listStyle
            default: style = bodyStyle
            }
            out.addAttribute(
                .paragraphStyle, value: style,
                range: NSRange(location: start, length: out.length - start))
        }
        return out
    }

    /// Plain body runs take the caller's base color; runs the scanner already
    /// tinted (bullet/quote markers) keep theirs.
    private static func tinted(_ attr: AttributedString, base: Color) -> AttributedString {
        var colored = attr
        for run in colored.runs where run.foregroundColor == nil {
            colored[run.range].foregroundColor = base
        }
        return colored
    }

    // MARK: - Block parsing

    private static func blocks(_ source: String, fontSize: CGFloat) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var inFence = false
        var fence: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(attributed(paragraph.joined(separator: "\n"), fontSize: fontSize)))
            paragraph = []
        }

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inFence {
                    out.append(.code(fence))
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
                out.append(.heading(level: hashes, attr))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                var attr = attributed(String(trimmed.dropFirst(2)), fontSize: fontSize)
                attr.foregroundColor = .primary
                out.append(.list(bullet("•  ") + attr))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                var attr = attributed(String(trimmed.dropFirst(2)), fontSize: fontSize)
                attr.foregroundColor = .secondary
                out.append(.quote(bullet("▎  ") + attr))
            } else if trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                flushParagraph()
                let marker = trimmed.prefix { $0 != "." } + "."
                let body = trimmed.drop { $0 != "." }.dropFirst(2)
                out.append(.list(bullet("\(marker)  ") + attributed(String(body), fontSize: fontSize)))
            } else {
                paragraph.append(line)
            }
        }
        if inFence, !fence.isEmpty { out.append(.code(fence)) }
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
