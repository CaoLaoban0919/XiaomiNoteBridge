import SwiftUI

/// 聊天回复用的 Markdown 渲染器。
///
/// 为什么不用 `MarkdownLite`：那个是给引导页的协议文本写的，只认段落/代码块/分隔线，
/// 而模型回复里最常见的恰恰是**标题、列表、表格**——尤其做数据对比时，表格是主体。
///
/// 为什么不用 WKWebView 渲染 HTML：聊天记录是**只读**的，每条消息一个 WebView
/// 意味着十几份页面进程、滚动不同步、深色还要再维护一套 CSS。
/// 笔记正文上 WebView 是因为要 contenteditable 编辑，这里没有这个必要。
struct ChatMarkdown: View {

    let text: String
    var bodySize: CGFloat = 13

    private enum Block: Identifiable {
        case heading(level: Int, content: AttributedString)
        case paragraph(AttributedString)
        case listItem(ordered: Bool, marker: String, indent: Int, content: AttributedString)
        case code(String)
        case rule
        case table(header: [String], rows: [[String]])

        var id: String {
            switch self {
            case .heading(let l, let c): return "h\(l)-\(String(c.characters))"
            case .paragraph(let c): return "p-\(String(c.characters))"
            case .listItem(_, let m, let i, let c): return "li-\(i)-\(m)-\(String(c.characters))"
            case .code(let s): return "code-\(s.prefix(40))"
            case .rule: return "rule"
            case .table(let h, let r): return "table-\(h.joined())-\(r.count)"
            }
        }
    }

    // MARK: 解析

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var tableRows: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
            paragraph = []
            result.append(.paragraph(inline(joined)))
        }

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            let parsed = tableRows.map(Self.splitRow)
            tableRows = []
            guard !parsed.isEmpty else { return }

            // 第二行是 `|---|---|` 这种分隔行，不能当数据
            var header = parsed[0]
            var rows = Array(parsed.dropFirst())
            if let first = rows.first,
               first.allSatisfy({ cell in
                   // 分隔行每个单元格只由 - 和 : 组成；`cell` 是 String，
                   // 空单元格的 allSatisfy 天然为 true，不需要单独判空
                   cell.allSatisfy { $0 == "-" || $0 == ":" }
               }) {
                rows.removeFirst()
            }
            // 补齐列数，避免 Grid 里列数不一致
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            header += Array(repeating: "", count: max(0, columns - header.count))
            rows = rows.map { $0 + Array(repeating: "", count: max(0, columns - $0.count)) }
            result.append(.table(header: header, rows: rows))
        }

        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // 代码块优先：里面的 `#`、`|` 都不该被当成语法
            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushTable()
                if inCode {
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(raw); continue }

            // 表格行：以 | 开头且至少两个 |
            if trimmed.hasPrefix("|"), trimmed.filter({ $0 == "|" }).count >= 2 {
                flushParagraph()
                tableRows.append(trimmed)
                continue
            } else if !tableRows.isEmpty {
                flushTable()
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                result.append(.rule)
                continue
            }

            // 标题
            if let heading = Self.headingLevel(trimmed) {
                flushParagraph()
                let content = trimmed.dropFirst(heading + 1).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: heading, content: inline(content)))
                continue
            }

            // 列表
            if let item = Self.listItem(trimmed) {
                flushParagraph()
                result.append(.listItem(ordered: item.ordered,
                                        marker: item.marker,
                                        indent: item.indent,
                                        content: inline(item.content)))
                continue
            }

            paragraph.append(trimmed)
        }

        flushTable()
        flushParagraph()
        if !codeLines.isEmpty { result.append(.code(codeLines.joined(separator: "\n"))) }
        return result
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (ordered: Bool, marker: String, indent: Int, content: String)? {
        // 前导空格算层级：每两个空格一级，封顶 3 级
        let leading = line.prefix { $0 == " " }.count
        let indent = min(leading / 2, 3)
        let body = line.dropFirst(leading)

        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return (false, "•", indent, String(body.dropFirst(2)))
        }
        // 有序列表：`1. ` `12) `
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (true, "\(digits).", indent, String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: 渲染

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let content):
                    Text(content)
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, level <= 2 ? DS.Space.xs : 0)

                case .paragraph(let content):
                    Text(content)
                        .font(.system(size: bodySize))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .listItem(_, let marker, let indent, let content):
                    HStack(alignment: .firstTextBaseline, spacing: DS.Optical.compact) {
                        Text(marker)
                            .font(.system(size: bodySize))
                            .foregroundStyle(.secondary)
                        Text(content)
                            .font(.system(size: bodySize))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(indent) * 14)

                case .code(let code):
                    Text(code)
                        .font(.system(size: bodySize - 1, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(DS.Optical.control)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: DS.Radius.s))

                case .rule:
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .padding(.vertical, DS.Optical.snug)

                case .table(let header, let rows):
                    table(header: header, rows: rows)
                }
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return bodySize + 6
        case 2: return bodySize + 4
        case 3: return bodySize + 2
        default: return bodySize + 1
        }
    }

    /// 表格用 `Grid`：它会自动对齐列宽，比手搭 HStack 稳。
    private func table(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: DS.Optical.snug) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .font(.system(size: bodySize - 1, weight: .semibold))
                        .textSelection(.enabled)
                }
            }

            Divider()

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.system(size: bodySize - 1))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(DS.Optical.control)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: DS.Radius.s))
    }
}
