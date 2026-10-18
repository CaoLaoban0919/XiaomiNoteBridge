import Foundation

/// 把 AI 回复的纯文本转成可插入笔记正文的 HTML。
///
/// 关键职责：识别 ```` ```chart {JSON} ```` 代码块，生成内联 SVG 饼图/柱状图。
/// 正文是 WebView，不认识 Markdown——不转换的话用户只会看到一堆 JSON。
enum AITextToHTML {

    static func render(_ text: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var chartLines: [String] = []
        var inChart = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !joined.isEmpty else { return }
            // 段内换行保留为 <br/>，空行才分段
            let body = escape(joined).replacingOccurrences(of: "\n", with: "<br/>")
            out.append("<p>\(body)</p>")
        }

        func flushChart() {
            guard !chartLines.isEmpty else { return }
            let json = chartLines.joined(separator: "\n")
            chartLines = []
            if let data = json.data(using: .utf8),
               let payload = try? JSONDecoder().decode(ChatChartPayload.self, from: data),
               !payload.data.isEmpty {
                out.append(svg(payload))
            } else {
                // 解析失败就原样保留，别吞内容
                out.append("<pre>\(escape(json))</pre>")
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inChart {
                    flushChart()
                    inChart = false
                } else {
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    if language.lowercased() == "chart" {
                        flushParagraph()
                        inChart = true
                    } else {
                        // 普通代码块：当普通段落处理（保留围栏）
                        paragraph.append(raw)
                    }
                }
                continue
            }

            if inChart {
                chartLines.append(raw)
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(raw)
            }
        }

        flushParagraph()
        if inChart { flushChart() }
        return out.joined()
    }

    // MARK: - SVG

    private static let palette = [
        "#4A90D9", "#E8724C", "#5BB98C", "#B07CD9",
        "#E0B44A", "#7A8FA6", "#D96B8A", "#67B7C9",
    ]

    private static func svg(_ payload: ChatChartPayload) -> String {
        let total = payload.data.reduce(0) { $0 + $1.value }
        guard total > 0 else { return "" }

        let width = 560.0
        let height = 240.0
        let center = height / 2
        let radius = 92.0
        let title = escape(payload.title ?? "")

        var parts: [String] = []
        parts.append("<div style=\"margin:10px 0;\">")
        if !title.isEmpty {
            parts.append("<div style=\"font-weight:600;font-size:14px;margin-bottom:6px;\">\(title)</div>")
        }
        parts.append("<svg width=\"\(Int(width))\" height=\"\(Int(height))\" viewBox=\"0 0 \(Int(width)) \(Int(height))\" xmlns=\"http://www.w3.org/2000/svg\">")

        var angle = -90.0
        for (index, item) in payload.data.enumerated() {
            let sweep = item.value / total * 360
            guard sweep > 0 else { continue }
            let start = angle
            let end = angle + sweep
            parts.append("<path d=\"\(slice(center: center, radius: radius, start: start, end: end))\" fill=\"\(palette[index % palette.count])\" stroke=\"white\" stroke-width=\"1\"/>")
            angle = end
        }

        // 环形镂空 + 中心总量
        parts.append("<circle cx=\"\(center)\" cy=\"\(center)\" r=\"\(radius * 0.55)\" fill=\"white\"/>")
        parts.append("<text x=\"\(center)\" y=\"\(center + 5)\" text-anchor=\"middle\" font-size=\"14\" font-weight=\"600\" fill=\"#333\">\(Int(total.rounded()))</text>")

        // 右侧图例
        var legendY = 46.0
        for (index, item) in payload.data.enumerated() {
            let color = palette[index % palette.count]
            let percent = item.value / total * 100
            parts.append("<rect x=\"300\" y=\"\(legendY - 9)\" width=\"10\" height=\"10\" rx=\"2\" fill=\"\(color)\"/>")
            parts.append("<text x=\"318\" y=\"\(legendY)\" font-size=\"12\" fill=\"#333\">\(escape(item.label))</text>")
            parts.append("<text x=\"470\" y=\"\(legendY)\" font-size=\"12\" fill=\"#888\" text-anchor=\"end\">\(Int(percent.rounded()))%</text>")
            legendY += 22
        }

        parts.append("</svg></div>")
        return parts.joined()
    }

    private static func slice(center: Double, radius: Double, start: Double, end: Double) -> String {
        let s = start * .pi / 180
        let e = end * .pi / 180
        let x1 = center + radius * cos(s)
        let y1 = center + radius * sin(s)
        let x2 = center + radius * cos(e)
        let y2 = center + radius * sin(e)
        let large = (end - start) > 180 ? 1 : 0
        return "M \(f(center)) \(f(center)) L \(f(x1)) \(f(y1)) A \(f(radius)) \(f(radius)) 0 \(large) 1 \(f(x2)) \(f(y2)) Z"
    }

    /// 保留两位小数，避免 SVG 里出现超长浮点
    private static func f(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
