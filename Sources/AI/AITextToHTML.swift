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
            var body = escape(joined).replacingOccurrences(of: "\n", with: "<br/>")
            body = typesetMath(body)
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

    /// 低饱和、同一明度带的配色：彼此不抢，缩到 80pt 也不糊成一团。
    /// 刻意避开纯红/纯绿——那种配色在小尺寸下像报警灯。
    private static let palette = [
        "#5B8FF9", "#61DDAA", "#65789B", "#F6BD16",
        "#7262FD", "#78D3F8", "#9661BC", "#F6903D",
    ]

    private static func svg(_ payload: ChatChartPayload) -> String {
        let total = payload.data.reduce(0) { $0 + $1.value }
        guard total > 0 else { return "" }

        let width = 640.0
        let height = 260.0
        let center = height / 2
        let outer = 96.0
        let inner = outer * 0.62          // 环宽 = 38% 半径，比 45% 更轻
        let gap = 0.9                     // 扇区间隙（度），代替白色描边
        let title = escape(payload.title ?? "")

        var parts: [String] = []
        parts.append("<div style=\"margin:14px 0;\">")
        if !title.isEmpty {
            parts.append("<div style=\"font-weight:600;font-size:15px;letter-spacing:.2px;margin-bottom:8px;color:currentColor;\">\(title)</div>")
        }
        parts.append("<svg width=\"\(Int(width))\" height=\"\(Int(height))\" viewBox=\"0 0 \(Int(width)) \(Int(height))\" xmlns=\"http://www.w3.org/2000/svg\" style=\"overflow:visible\">")

        // 扇环：一条 path 同时描外弧+内弧（fill-rule=evenodd），不再用白色圆挖洞——
        // 白圆在深色背景下就是一块突兀的白斑。
        var angle = -90.0
        for (index, item) in payload.data.enumerated() {
            let sweep = item.value / total * 360
            guard sweep > 0 else { continue }
            let start = angle + gap / 2
            let end = angle + sweep - gap / 2
            guard end > start else { continue }
            let d = ring(center: center, outer: outer, inner: inner, start: start, end: end)
            parts.append("<path d=\"\(d)\" fill=\"\(palette[index % palette.count])\" fill-rule=\"evenodd\" stroke=\"none\"/>")
            angle += sweep
        }

        // 中心：总量 + 单位
        parts.append("<text x=\"\(center)\" y=\"\(center - 2)\" text-anchor=\"middle\" font-size=\"22\" font-weight=\"600\" fill=\"currentColor\" style=\"font-variant-numeric:tabular-nums\">\(Int(total.rounded()))</text>")
        if let unit = payload.unit, !unit.isEmpty {
            parts.append("<text x=\"\(center)\" y=\"\(center + 16)\" text-anchor=\"middle\" font-size=\"10\" fill=\"currentColor\" opacity=\"0.45\">\(escape(unit))</text>")
        }

        // 右侧图例：圆点 + 名称 + 右对齐百分比（等宽数字，避免抖动）
        var legendY = 56.0
        for (index, item) in payload.data.enumerated() {
            let color = palette[index % palette.count]
            let percent = item.value / total * 100
            parts.append("<circle cx=\"318\" cy=\"\(legendY - 4)\" r=\"4\" fill=\"\(color)\"/>")
            parts.append("<text x=\"332\" y=\"\(legendY)\" font-size=\"12.5\" fill=\"currentColor\">\(escape(item.label))</text>")
            parts.append("<text x=\"566\" y=\"\(legendY)\" font-size=\"12.5\" fill=\"currentColor\" opacity=\"0.55\" text-anchor=\"end\" style=\"font-variant-numeric:tabular-nums\">\(percentText(percent))</text>")
            legendY += 24
        }

        parts.append("</svg></div>")
        return parts.joined()
    }

    /// 扇环路径：外弧顺时针 + 内弧逆时针，配 fill-rule=evenodd 就是真正的环。
    private static func ring(center: Double, outer: Double, inner: Double,
                             start: Double, end: Double) -> String {
        let s = start * .pi / 180
        let e = end * .pi / 180
        let large = (end - start) > 180 ? 1 : 0

        let ox1 = center + outer * cos(s)
        let oy1 = center + outer * sin(s)
        let ox2 = center + outer * cos(e)
        let oy2 = center + outer * sin(e)
        let ix2 = center + inner * cos(e)
        let iy2 = center + inner * sin(e)
        let ix1 = center + inner * cos(s)
        let iy1 = center + inner * sin(s)

        return "M \(f(ox1)) \(f(oy1)) "
            + "A \(f(outer)) \(f(outer)) 0 \(large) 1 \(f(ox2)) \(f(oy2)) "
            + "L \(f(ix2)) \(f(iy2)) "
            + "A \(f(inner)) \(f(inner)) 0 \(large) 0 \(f(ix1)) \(f(iy1)) Z"
    }

    /// 一位小数只在必要时出现：12% 比 12.0% 干净，6.7% 又比 7% 诚实。
    private static func percentText(_ value: Double) -> String {
        if value >= 10 || value.rounded() == value {
            return "\(Int(value.rounded()))%"
        }
        return String(format: "%.1f%%", value)
    }

    /// 轻量公式排版：把 LaTeX 的下标/上标/粗体转成 HTML 标签。
    ///
    /// 不引 KaTeX：那要打包 300KB+ 的 JS/CSS/字体，而且正文是可编辑的——
    /// 公式区块一旦被 execCommand 改写就会被破坏。
    /// 这里只处理最常见的写法，覆盖 `∬_D`、`∫_α^β`、`r_{i}`、`**r**` 这类，
    /// 视觉上足够，且不影响编辑。
    private static func typesetMath(_ text: String) -> String {
        var result = text

        // r_{i+1} / x_{max}：先处理带花括号的，否则会被单字符规则拆坏
        result = replacing(#"_\{([^}]+)\}"#, with: "<sub>$1</sub>", in: result)
        result = replacing(#"\^\{([^}]+)\}"#, with: "<sup>$1</sup>", in: result)

        // ∫_α^β：下标和上标紧跟在积分号/字母后面
        result = replacing(#"_([A-Za-z0-9α-ωΑ-Ω]+)"#, with: "<sub>$1</sub>", in: result)
        result = replacing(#"\^([A-Za-z0-9α-ωΑ-Ω]+)"#, with: "<sup>$1</sup>", in: result)

        // **r** → 粗体（Markdown 粗体在正文里原本也不渲染）
        result = replacing(#"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", in: result)

        return result
    }

    private static func replacing(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
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
