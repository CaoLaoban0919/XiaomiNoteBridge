import SwiftUI
import Charts

/// 图表数据。AI 用 ```chart 代码块输出这个结构的 JSON。
///
/// 不用 mermaid：渲染它要引 mermaid.js + WebView，为一个饼图挂浏览器内核不划算。
/// JSON + Swift Charts 是原生绘制，跟随深浅色、能进 SwiftUI 布局，也不增包体积。
struct ChatChartPayload: Decodable {
    var type: String          // pie | bar
    var title: String?
    var unit: String?
    var data: [Item]

    struct Item: Decodable {
        var label: String
        var value: Double
    }
}

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
        case chart(ChatChartPayload)

        var id: String {
            switch self {
            case .heading(let l, let c): return "h\(l)-\(String(c.characters))"
            case .paragraph(let c): return "p-\(String(c.characters))"
            case .listItem(_, let m, let i, let c): return "li-\(i)-\(m)-\(String(c.characters))"
            case .code(let s): return "code-\(s.prefix(40))"
            case .rule: return "rule"
            case .table(let h, let r): return "table-\(h.joined())-\(r.count)"
            case .chart(let c): return "chart-\(c.type)-\(c.data.count)"
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage = ""
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

            var header = parsed[0]
            var rows = Array(parsed.dropFirst())
            if let first = rows.first,
               first.allSatisfy({ cell in

                   cell.allSatisfy { $0 == "-" || $0 == ":" }
               }) {
                rows.removeFirst()
            }

            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            header += Array(repeating: "", count: max(0, columns - header.count))
            rows = rows.map { $0 + Array(repeating: "", count: max(0, columns - $0.count)) }
            result.append(.table(header: header, rows: rows))
        }

        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushTable()
                if inCode {
                    let body = codeLines.joined(separator: "\n")
                    // ```chart 的内容按 JSON 解析成图表；
                    // 解析失败就退回代码块——宁可显示原文，也不能吞掉内容。
                    if codeLanguage.lowercased() == "chart",
                       let raw = body.data(using: .utf8),
                       let payload = try? JSONDecoder().decode(ChatChartPayload.self, from: raw),
                       !payload.data.isEmpty {
                        result.append(.chart(payload))
                    } else {
                        result.append(.code(body))
                    }
                    codeLines = []
                    codeLanguage = ""
                    inCode = false
                } else {
                    codeLanguage = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(raw); continue }

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

            if let heading = Self.headingLevel(trimmed) {
                flushParagraph()
                let content = trimmed.dropFirst(heading + 1).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: heading, content: inline(content)))
                continue
            }

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

        let leading = line.prefix { $0 == " " }.count
        let indent = min(leading / 2, 3)
        let body = line.dropFirst(leading)

        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return (false, "•", indent, String(body.dropFirst(2)))
        }

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

                case .chart(let payload):
                    chartView(payload)
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

    @ViewBuilder
    private func chartView(_ payload: ChatChartPayload) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let title = payload.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: bodySize, weight: .semibold))
            }

            Chart(payload.data, id: \.label) { item in
                if payload.type.lowercased() == "bar" {
                    BarMark(
                        x: .value("类别", item.label),
                        y: .value("数值", item.value)
                    )
                    .foregroundStyle(by: .value("类别", item.label))
                } else {
                    SectorMark(
                        angle: .value("数值", item.value),
                        innerRadius: .ratio(0.45),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("类别", item.label))
                    .annotation(position: .overlay) {
                        // 太小的扇区标数字会挤成一团，只给占比 > 8% 的加标注
                        if item.value / totalOf(payload) > 0.08 {
                            Text("\(Int(item.value.rounded()))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 200)
        }
        .padding(DS.Optical.control)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: DS.Radius.s))
    }

    private func totalOf(_ payload: ChatChartPayload) -> Double {
        max(payload.data.reduce(0) { $0 + $1.value }, 0.001)
    }
}
