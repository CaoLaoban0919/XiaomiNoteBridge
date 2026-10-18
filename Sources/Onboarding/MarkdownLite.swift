import SwiftUI

struct MarkdownLite: View {
    let text: String
    var bodySize: CGFloat = 13

    private enum Block {
        case paragraph(AttributedString)
        case rule
        case code(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
            paragraph = []
            if let attr = try? AttributedString(
                markdown: joined,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                result.append(.paragraph(attr))
            } else {
                result.append(.paragraph(AttributedString(joined)))
            }
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(raw); continue }

            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line == "---" {
                flushParagraph()
                result.append(.rule)
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        if !codeLines.isEmpty { result.append(.code(codeLines.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let attr):
                    Text(attr)
                        .font(.system(size: bodySize))
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .rule:
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .padding(.vertical, DS.Space.xs)

                case .code(let code):
                    Text(code)
                        .font(.system(size: bodySize - 1, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(DS.Optical.control)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
