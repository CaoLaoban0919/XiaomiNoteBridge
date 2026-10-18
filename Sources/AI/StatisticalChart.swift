import Foundation

/// 本地统计图：直方图从原始观测值计数，雷达图的所有系列共用同一尺度。
enum StatisticalChart {
    static func svg(_ payload: ChatChartPayload, palette: [String]) -> String? {
        guard !palette.isEmpty else { return nil }
        switch payload.type.lowercased() {
        case "radar": return radar(payload, palette: palette)
        case "histogram": return histogram(payload, color: palette[0])
        default: return nil
        }
    }

    private static func radar(_ payload: ChatChartPayload, palette: [String]) -> String? {
        guard payload.expression == nil, payload.samples.isEmpty, payload.series.count <= 8,
              payload.yMin == nil || payload.yMin == 0 else { return nil }
        var series: [(String, [ChatChartPayload.Item])] = []
        if !payload.data.isEmpty { series.append(("系列 1", payload.data)) }
        for item in payload.series {
            guard item.expression == nil, let data = item.data else { return nil }
            series.append((item.label ?? "系列 \(series.count + 1)", data))
        }
        guard !series.isEmpty, series.count <= 8, let first = series.first?.1,
              (3...12).contains(first.count) else { return nil }
        let labels = first.map(\.label)
        guard labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(labels).count == labels.count else { return nil }
        guard series.allSatisfy({ _, data in
            data.map(\.label) == labels && data.allSatisfy { $0.defined && $0.x == nil && $0.value.isFinite && $0.value >= 0 }
        }) else { return nil }
        let maximum = series.flatMap { $0.1 }.map(\.value).max() ?? 0
        let limit = payload.yMax ?? max(maximum, 1)
        guard limit.isFinite, limit > 0, limit >= maximum else { return nil }
        let cx = 320.0, cy = 176.0, radius = 128.0
        func point(_ index: Int, _ fraction: Double) -> (Double, Double) {
            let angle = Double(index) * 2 * .pi / Double(labels.count) - .pi / 2
            return (cx + cos(angle) * radius * fraction, cy + sin(angle) * radius * fraction)
        }
        func polygon(_ fractions: [Double]) -> String {
            fractions.enumerated().map { index, fraction in
                let (x, y) = point(index, fraction)
                return "\(f(x)),\(f(y))"
            }.joined(separator: " ")
        }
        let height = 364 + ((series.count + 1) / 2) * 25
        var out = [open(payload, kind: "radar", height: height)]
        for ring in 1...5 {
            let fraction = Double(ring) / 5
            out.append("<polygon class=\"mn-radar-grid\" points=\"\(polygon(Array(repeating: fraction, count: labels.count)))\" fill=\"none\" stroke=\"currentColor\" stroke-opacity=\"0.15\"/>")
            out.append(text(tick(limit * fraction), cx + 6, cy - radius * fraction + 12, size: 10))
        }
        for (index, label) in labels.enumerated() {
            let (x, y) = point(index, 1)
            let (lx, ly) = point(index, 1.17)
            out.append("<path d=\"M\(f(cx)),\(f(cy)) L\(f(x)),\(f(y))\" stroke=\"currentColor\" stroke-opacity=\"0.2\"/>")
            let anchor = lx < cx - 10 ? "end" : (lx > cx + 10 ? "start" : "middle")
            out.append(text(String(label.prefix(12)), lx, ly + 4, anchor: anchor))
        }
        for (index, item) in series.enumerated() {
            let color = palette[index % palette.count]
            out.append("<polygon class=\"mn-radar-series\" data-series=\"\(index)\" points=\"\(polygon(item.1.map { $0.value / limit }))\" fill=\"\(color)\" fill-opacity=\"0.16\" stroke=\"\(color)\" stroke-width=\"2\" stroke-linejoin=\"round\"><title>\(escape(item.0))</title></polygon>")
            for (i, value) in item.1.enumerated() {
                let (x, y) = point(i, value.value / limit)
                out.append("<circle cx=\"\(f(x))\" cy=\"\(f(y))\" r=\"3\" fill=\"\(color)\"><title>\(escape(value.label)): \(tick(value.value))\(escape(payload.unit ?? ""))</title></circle>")
            }
            let x = 74.0 + Double(index % 2) * 266, y = 356.0 + Double(index / 2) * 25
            out.append("<path d=\"M\(f(x)),\(f(y - 4)) h18\" stroke=\"\(color)\" stroke-width=\"3\"/>")
            out.append(text(String(item.0.prefix(28)), x + 25, y))
        }
        return out.joined() + "</svg></figure>"
    }

    private static func histogram(_ payload: ChatChartPayload, color: String) -> String? {
        let samples = payload.samples
        guard !samples.isEmpty, samples.count <= 10000, samples.allSatisfy(\.isFinite),
              payload.data.isEmpty, payload.series.isEmpty, payload.expression == nil,
              payload.yMin == nil || payload.yMin == 0 else { return nil }
        let bins = payload.bins ?? min(50, max(1, Int(ceil(sqrt(Double(samples.count))))))
        guard (1...50).contains(bins), let minimum = samples.min(), let maximum = samples.max() else { return nil }
        var lower = payload.xMin ?? minimum, upper = payload.xMax ?? maximum
        if lower == upper, payload.xMin == nil, payload.xMax == nil {
            let padding = max(abs(lower) * 0.1, 0.5)
            lower -= padding; upper += padding
        }
        guard lower.isFinite, upper.isFinite, lower < upper, (upper - lower).isFinite,
              lower <= minimum, upper >= maximum else { return nil }
        var counts = Array(repeating: 0, count: bins)
        for sample in samples {
            let index = min(bins - 1, Int((sample - lower) / (upper - lower) * Double(bins)))
            counts[index] += 1
        }
        let largest = counts.max() ?? 1
        let steps = min(5, largest)
        let automaticLimit = ceil(Double(largest) / Double(steps)) * Double(steps)
        let limit = payload.yMax ?? automaticLimit
        guard limit.isFinite, limit >= Double(largest), limit > 0 else { return nil }
        let left = 74.0, top = 24.0, width = 532.0, height = 280.0
        let binWidth = width / Double(bins), gap = min(3, binWidth * 0.08)
        var out = [open(payload, kind: "histogram", height: 390)]
        for index in 0...steps {
            let fraction = Double(index) / Double(steps), y = top + height * (1 - fraction)
            out.append("<path d=\"M\(f(left)),\(f(y)) h\(f(width))\" stroke=\"currentColor\" stroke-opacity=\"0.12\"/>")
            out.append(text(tick(limit * fraction), left - 9, y + 4, anchor: "end"))
        }
        for (index, count) in counts.enumerated() {
            let low = lower + (upper - lower) * (Double(index) / Double(bins))
            let high = lower + (upper - lower) * (Double(index + 1) / Double(bins))
            let barHeight = Double(count) / limit * height
            let interval = "[\(tick(low)), \(tick(high))\(index == bins - 1 ? "]" : ")")"
            out.append("<rect class=\"mn-histogram-bin\" data-count=\"\(count)\" x=\"\(f(left + Double(index) * binWidth + gap / 2))\" y=\"\(f(top + height - barHeight))\" width=\"\(f(binWidth - gap))\" height=\"\(f(barHeight))\" fill=\"\(color)\"><title>\(escape(interval)): \(count)</title></rect>")
        }
        for index in 0...5 {
            let fraction = Double(index) / 5
            out.append(text(tick(lower + (upper - lower) * fraction), left + width * fraction, top + height + 22, anchor: "middle"))
        }
        out.append("<path d=\"M\(f(left)),\(f(top)) V\(f(top + height)) H\(f(left + width))\" fill=\"none\" stroke=\"currentColor\" stroke-opacity=\"0.5\"/>")
        out.append(text(payload.yLabel ?? "频数", left, 14))
        out.append(text(payload.xLabel ?? payload.unit ?? "观测值", left + width / 2, 352, anchor: "middle"))
        out.append(text("样本数：\(samples.count) · 等宽分箱：\(bins)", left + width / 2, 378, anchor: "middle"))
        return out.joined() + "</svg></figure>"
    }

    private static func open(_ payload: ChatChartPayload, kind: String, height: Int) -> String {
        let title = escape(payload.title ?? (kind == "radar" ? "雷达图" : "直方图"))
        return "<figure class=\"mn-chart\" contenteditable=\"false\" style=\"margin:14px 0\"><figcaption>\(title)</figcaption><svg class=\"mn-\(kind)-chart\" role=\"img\" aria-label=\"\(title)\" width=\"640\" height=\"\(height)\" viewBox=\"0 0 640 \(height)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"max-width:100%;height:auto;color:inherit\">"
    }
    private static func escape(_ value: String) -> String { MathMarkup.escape(value) }
    private static func f(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func tick(_ value: Double) -> String { String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value) }
    private static func text(_ value: String, _ x: Double, _ y: Double, anchor: String = "start", size: Int = 12) -> String {
        "<text x=\"\(f(x))\" y=\"\(f(y))\" text-anchor=\"\(anchor)\" fill=\"currentColor\" font-size=\"\(size)\">\(escape(value))</text>"
    }
}
