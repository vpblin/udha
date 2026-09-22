import SwiftUI

/// Renders the Markdown the write-up model produces — `##` headings, `-`
/// bullets, numbered lists, paragraphs, and `**bold**` / `*italic*` / `` `code` ``
/// inline — in the house style. SwiftUI's `Text` only understands the inline
/// half (block intents are flattened, which is how `## Purpose` and `- item`
/// ended up on screen verbatim), so the blocks are split here and each line's
/// inline marks are handed to `AttributedString(markdown:)`.
struct UdhaMarkdown: View {
    let text: String
    var size: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: Blocks

    enum Block: Equatable {
        case heading(level: Int, String)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
        case rule
    }

    static func blocks(of text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { flush(); out.append(.heading(level: min(level, 3), rest)); continue }
            }
            if line == "---" || line == "***" { flush(); out.append(.rule); continue }
            if let m = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flush(); out.append(.bullet(String(line[m.upperBound...]))); continue
            }
            if let m = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression),
               let n = Int(line[..<m.upperBound].filter(\.isNumber)) {
                flush(); out.append(.numbered(n, String(line[m.upperBound...]))); continue
            }
            paragraph.append(line)
        }
        flush()
        return out
    }

    // MARK: Rendering

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s, font: UdhaTheme.text(level == 1 ? size + 4 : size + 1, .extraBold))
                .padding(.top, level == 1 ? 18 : 14)
                .padding(.bottom, 6)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("–").font(UdhaTheme.mono(size - 1)).foregroundStyle(UdhaTheme.muted)
                inline(s, font: UdhaTheme.text(size, .regular))
            }
            .padding(.leading, 6)
            .padding(.bottom, 5)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n).").font(UdhaTheme.mono(size - 1)).foregroundStyle(UdhaTheme.muted)
                inline(s, font: UdhaTheme.text(size, .regular))
            }
            .padding(.leading, 6)
            .padding(.bottom, 5)
        case .paragraph(let s):
            inline(s, font: UdhaTheme.text(size, .regular))
                .padding(.bottom, 10)
        case .rule:
            HRule(color: UdhaTheme.rule).padding(.vertical, 10)
        }
    }

    private func inline(_ s: String, font: Font) -> some View {
        let attributed = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        return Text(attributed)
            .font(font)
            .lineSpacing(5)
            .foregroundStyle(UdhaTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
