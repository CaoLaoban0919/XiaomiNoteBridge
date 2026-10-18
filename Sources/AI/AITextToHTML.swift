import Foundation

/// 把 AI 回复的纯文本转成可插入笔记正文的 HTML。
///
/// 识别 chart 代码块，生成内联 SVG 分类图、函数曲线和三维曲面。
/// 正文是 WebView，不认识 Markdown——不转换的话用户只会看到一堆 JSON。
enum AITextToHTML {

    static func render(_ text: String) -> String {
        MarkdownHTML.render(text) { json in
            guard let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ChatChartPayload.self, from: data) else { return nil }
            return svg(payload)
        }
    }

    // MARK: - SVG

    /// 低饱和、同一明度带的配色：彼此不抢，缩到 80pt 也不糊成一团。
    /// 刻意避开纯红/纯绿——那种配色在小尺寸下像报警灯。
    private static let palette = [
        "#5B8FF9", "#61DDAA", "#65789B", "#F6BD16",
        "#7262FD", "#78D3F8", "#9661BC", "#F6903D",
    ]

    private static func svg(_ payload: ChatChartPayload) -> String? {
        switch payload.type.lowercased() {
        case "surface", "surface3d", "3d": return SurfaceChart.svg(payload)
        case "line", "curve", "function", "area", "scatter": return CartesianChart.svg(payload, palette: palette)
        case "radar", "histogram": return StatisticalChart.svg(payload, palette: palette)
        case "pie", "bar": break
        default: return nil
        }
        guard !payload.data.isEmpty, payload.data.count <= 1000, payload.data.allSatisfy({ $0.defined && $0.value.isFinite }) else { return nil }
        if payload.type.lowercased() == "bar" { return barSVG(payload) }
        let total = payload.data.reduce(0) { $0 + $1.value }
        guard total.isFinite, total > 0, payload.data.allSatisfy({ $0.value >= 0 }) else { return nil }

        let width = 640.0
        let height = 200.0
        let center = height / 2
        let outer = 76.0
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

    private static func barSVG(_ payload: ChatChartPayload) -> String {
        let minimum = min(0, payload.data.map(\.value).min() ?? 0)
        let maximum = max(0, payload.data.map(\.value).max() ?? 0)
        let span = max(maximum - minimum, 1)
        let zero = 210 + (0 - minimum) / span * 330
        let height = max(100, payload.data.count * 34 + 28)
        var parts = ["<figure class=\"mn-chart\" style=\"margin:14px 0\"><figcaption>\(escape(payload.title ?? ""))</figcaption><svg width=\"640\" height=\"\(height)\" viewBox=\"0 0 640 \(height)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"max-width:100%;height:auto\">"]
        for (index, item) in payload.data.enumerated() {
            let y = 14 + index * 34
            let x = 210 + (item.value - minimum) / span * 330
            parts.append("<text x=\"8\" y=\"\(y+16)\" font-size=\"13\" fill=\"currentColor\">\(escape(item.label))</text><rect x=\"\(f(min(zero,x)))\" y=\"\(y)\" width=\"\(f(abs(x-zero)))\" height=\"22\" rx=\"4\" fill=\"\(palette[index % palette.count])\"/><text x=\"628\" y=\"\(y+16)\" text-anchor=\"end\" font-size=\"13\" fill=\"currentColor\">\(f(item.value))\(escape(payload.unit ?? ""))</text>")
        }
        return parts.joined() + "</svg></figure>"
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

    /// 保留两位小数，避免 SVG 里出现超长浮点
    private static func f(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
