import Foundation

/// 图表协议由聊天、正文与导出共用；曲线采样在本地完成，不执行模型提供的代码。
struct ChatChartPayload: Decodable {
    let type: String
    let title: String?
    let unit: String?
    let data: [Item]
    let series: [Series]
    let expression: String?
    let samples: [Double]
    let bins: Int?
    let xMin: Double?
    let xMax: Double?
    let yMin: Double?
    let yMax: Double?
    let zMin: Double?
    let zMax: Double?
    let xLabel: String?
    let yLabel: String?
    let zLabel: String?

    struct Item: Decodable {
        let label: String
        let value: Double
        let x: Double?
        let defined: Bool
        private enum CodingKeys: String, CodingKey { case label, value, x, y }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            x = try c.decodeIfPresent(Double.self, forKey: .x)
            let key: CodingKeys = c.contains(.y) ? .y : .value
            let number = try c.decodeIfPresent(Double.self, forKey: key)
            guard c.contains(key) else { throw DecodingError.keyNotFound(key, .init(codingPath: c.codingPath, debugDescription: "图表数据缺少 value 或 y")) }
            value = number ?? 0
            defined = number != nil
        }
    }
    struct Series: Decodable {
        let label: String?
        let expression: String?
        let data: [Item]?
    }
    private enum CodingKeys: String, CodingKey {
        case type, title, unit, data, series, expression, samples, bins, xMin, xMax, yMin, yMax, zMin, zMax, xLabel, yLabel, zLabel
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        data = try c.decodeIfPresent([Item].self, forKey: .data) ?? []
        series = try c.decodeIfPresent([Series].self, forKey: .series) ?? []
        expression = try c.decodeIfPresent(String.self, forKey: .expression)
        samples = try c.decodeIfPresent([Double].self, forKey: .samples) ?? []
        bins = try c.decodeIfPresent(Int.self, forKey: .bins)
        xMin = try c.decodeIfPresent(Double.self, forKey: .xMin)
        xMax = try c.decodeIfPresent(Double.self, forKey: .xMax)
        yMin = try c.decodeIfPresent(Double.self, forKey: .yMin)
        yMax = try c.decodeIfPresent(Double.self, forKey: .yMax)
        zMin = try c.decodeIfPresent(Double.self, forKey: .zMin)
        zMax = try c.decodeIfPresent(Double.self, forKey: .zMax)
        xLabel = try c.decodeIfPresent(String.self, forKey: .xLabel)
        yLabel = try c.decodeIfPresent(String.self, forKey: .yLabel)
        zLabel = try c.decodeIfPresent(String.self, forKey: .zLabel)
    }
}

enum CartesianChart {
    struct Point { let x: Double; let y: Double? }
    private struct Curve { let label: String; let points: [Point]; let expression: CurveExpression? }

    static func svg(_ payload: ChatChartPayload, palette: [String]) -> String? {
        guard !palette.isEmpty, payload.series.count <= 8 else { return nil }
        let isArea = payload.type.lowercased() == "area"
        let isScatter = payload.type.lowercased() == "scatter"
        let hasExpression = payload.expression != nil || payload.series.contains { $0.expression != nil }
        guard !isScatter || !hasExpression else { return nil }
        let sampleMin = payload.xMin ?? -10, sampleMax = payload.xMax ?? 10
        if hasExpression {
            guard sampleMin.isFinite, sampleMax.isFinite, sampleMin < sampleMax, (sampleMax - sampleMin).isFinite else { return nil }
        }
        var curves: [Curve] = []
        func curve(label: String, expression: String?, data: [ChatChartPayload.Item]) -> Curve? {
            if let expression {
                guard data.isEmpty, let parsed = CurveExpression(expression) else { return nil }
                let points = (0...600).map { index -> Point in
                    let x = sampleMin + (sampleMax - sampleMin) * Double(index) / 600
                    let y = parsed.value(at: x)
                    return Point(x: x, y: y.isFinite ? y : nil)
                }
                guard points.filter({ $0.y != nil }).count >= 2 else { return nil }
                return Curve(label: label.isEmpty ? expression : label, points: points, expression: parsed)
            }
            guard !data.isEmpty, data.count <= 2000 else { return nil }
            let numeric = data.contains { $0.x != nil }
            guard !isScatter || numeric else { return nil }
            guard !numeric || data.allSatisfy({ $0.x != nil }) else { return nil }
            var points: [Point] = []
            for (index, item) in data.enumerated() {
                let x = item.x ?? Double(index)
                guard x.isFinite, item.value.isFinite else { return nil }
                points.append(Point(x: x, y: item.defined ? item.value : nil))
            }
            if numeric { points.sort { $0.x < $1.x } }
            guard points.contains(where: { $0.y != nil }) else { return nil }
            return Curve(label: label, points: points, expression: nil)
        }
        if payload.expression != nil || !payload.data.isEmpty {
            guard let item = curve(label: payload.expression ?? "", expression: payload.expression, data: payload.data) else { return nil }
            curves.append(item)
        }
        for series in payload.series {
            guard let item = curve(label: series.label ?? "", expression: series.expression, data: series.data ?? []) else { return nil }
            curves.append(item)
        }
        guard !curves.isEmpty, curves.count <= 8 else { return nil }
        let points = curves.flatMap { $0.points }
        var xMin = payload.xMin ?? points.map { $0.x }.min() ?? 0
        var xMax = payload.xMax ?? points.map { $0.x }.max() ?? 1
        if xMin == xMax, payload.xMin == nil, payload.xMax == nil { xMin -= 1; xMax += 1 }
        guard xMin.isFinite, xMax.isFinite, xMin < xMax, (xMax - xMin).isFinite else { return nil }
        let values = points.filter { $0.x >= xMin && $0.x <= xMax }.compactMap { $0.y }.sorted()
        guard !values.isEmpty else { return nil }
        // 只对采样函数采用稳健纵轴范围，避免极点附近的巨值压平整条曲线。
        let robustLow = values[values.count / 50], robustHigh = values[values.count - 1 - values.count / 50]
        let hasOutliers = hasExpression && values.count > 30 && values[values.count - 1] - values[0] > max(robustHigh - robustLow, 1) * 10
        let low = hasOutliers ? robustLow : values[0]
        let high = hasOutliers ? robustHigh : values[values.count - 1]
        let padding = low == high ? max(abs(low) * 0.1, 1) : (high - low) * 0.08
        let yMin = payload.yMin ?? (isArea ? min(0, low - padding) : low - padding)
        let yMax = payload.yMax ?? (isArea ? max(0, high + padding) : high + padding)
        guard yMin.isFinite, yMax.isFinite, yMin < yMax, (yMax - yMin).isFinite else { return nil }
        let left = 74.0, top = 24.0, width = 532.0, height = 280.0
        let legendRows = (curves.count + 1) / 2
        let totalHeight = 370 + legendRows * 25
        let hasCategoryLabels = curves.count == 1 && !payload.data.isEmpty && payload.data.count <= 8
            && payload.data.allSatisfy { $0.x == nil } && payload.data.contains { !$0.label.isEmpty }
        func px(_ x: Double) -> Double { left + (x - xMin) / (xMax - xMin) * width }
        func py(_ y: Double) -> Double { top + (yMax - y) / (yMax - yMin) * height }
        let title = escape(payload.title ?? "")
        var out = ["<figure class=\"mn-chart\" contenteditable=\"false\" style=\"margin:14px 0\"><figcaption>\(title)</figcaption><svg class=\"mn-cartesian-chart\" role=\"img\" aria-label=\"\(title.isEmpty ? "曲线图" : title)\" width=\"640\" height=\"\(totalHeight)\" viewBox=\"0 0 640 \(totalHeight)\" xmlns=\"http://www.w3.org/2000/svg\" style=\"max-width:100%;height:auto;color:inherit\">"]
        for index in 0...5 {
            let x = left + width * Double(index) / 5, y = top + height * Double(index) / 5
            out.append("<path d=\"M\(f(x)),\(f(top)) V\(f(top+height)) M\(f(left)),\(f(y)) H\(f(left+width))\" fill=\"none\" stroke=\"currentColor\" stroke-opacity=\"0.12\"/>")
            if !hasCategoryLabels {
                out.append(text(tick(xMin + (xMax-xMin)*Double(index)/5), x: x, y: top+height+22, anchor: "middle"))
            }
            out.append(text(tick(yMax - (yMax-yMin)*Double(index)/5), x: left-9, y: y+4, anchor: "end"))
        }
        let axisX = min(max(px(0), left), left+width), axisY = min(max(py(0), top), top+height)
        out.append("<path class=\"mn-chart-axes\" d=\"M\(f(left)),\(f(axisY)) H\(f(left+width)) M\(f(axisX)),\(f(top)) V\(f(top+height))\" fill=\"none\" stroke=\"currentColor\" stroke-opacity=\"0.5\"/>")
        for (index, curve) in curves.enumerated() {
            var path = "", previous: Point?
            var area = "", segment = "", segmentFirstX: Double?, segmentLastX: Double?
            func finishSegment() {
                if let first = segmentFirstX, let last = segmentLastX {
                    area += "M\(f(first)),\(f(axisY)) " + segment + "L\(f(last)),\(f(axisY)) Z "
                }
                segment = ""; segmentFirstX = nil; segmentLastX = nil
            }
            for point in curve.points {
                guard let y = point.y, point.x >= xMin, point.x <= xMax, y >= yMin, y <= yMax else { finishSegment(); previous = nil; continue }
                var connect = previous != nil
                if let previous, let previousY = previous.y, let expression = curve.expression {
                    // 极点附近的跳变分段，避免跨过无定义区间连线。
                    let midpoint = expression.value(at: previous.x + (point.x - previous.x) / 2)
                    let jump = abs(y-previousY) / (yMax-yMin)
                    let flipsAtPole = y * previousY < 0 && abs(midpoint - (y + previousY) / 2) > abs(y - previousY) * 0.5
                    if !midpoint.isFinite || jump > 0.35 || flipsAtPole { connect = false }
                }
                if !connect { finishSegment() }
                if segmentFirstX == nil { segmentFirstX = px(point.x) }
                segmentLastX = px(point.x)
                segment += "L\(f(px(point.x))),\(f(py(y))) "
                path += "\(connect ? "L" : "M")\(f(px(point.x))),\(f(py(y))) "
                if curve.expression == nil, isScatter || curve.points.count <= 100 {
                    out.append("<circle class=\"mn-chart-point\" cx=\"\(f(px(point.x)))\" cy=\"\(f(py(y)))\" r=\"3\" fill=\"\(palette[index % palette.count])\"/>")
                }
                previous = point
            }
            guard !path.isEmpty else { return nil }
            finishSegment()
            if isArea {
                out.append("<path class=\"mn-chart-area\" data-series=\"\(index)\" d=\"\(area)\" fill=\"\(palette[index % palette.count])\" fill-opacity=\"0.2\" stroke=\"none\"/>")
            }
            if !isScatter {
                out.append("<path class=\"mn-chart-curve\" data-series=\"\(index)\" d=\"\(path)\" fill=\"none\" stroke=\"\(palette[index % palette.count])\" stroke-width=\"2.2\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>")
            }
            let legendX = left + Double(index % 2) * 266, legendY = 369 + Double(index / 2) * 25
            if isScatter {
                out.append("<circle cx=\"\(f(legendX + 9))\" cy=\"\(f(legendY - 4))\" r=\"3\" fill=\"\(palette[index % palette.count])\"/>")
            } else {
                out.append("<path d=\"M\(f(legendX)),\(f(legendY-4)) h18\" stroke=\"\(palette[index % palette.count])\" stroke-width=\"3\"/>")
            }
            out.append(text(String((curve.label.isEmpty ? "系列 \(index+1)" : curve.label).prefix(32)), x: legendX+25, y: legendY))
        }
        out.append(text(payload.xLabel ?? "x", x: left+width/2, y: 348, anchor: "middle"))
        out.append(text(payload.yLabel ?? payload.unit ?? "y", x: left, y: 14))
        // 分类折线的标签保留；数值横轴不会强制等距。
        if hasCategoryLabels {
            for (index, item) in payload.data.enumerated() where !item.label.isEmpty {
                out.append(text(String(item.label.prefix(20)), x: px(Double(index)), y: top+height+22, anchor: "middle"))
            }
        }
        return out.joined() + "</svg></figure>"
    }

    private static func f(_ number: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), number) }
    private static func tick(_ number: Double) -> String { String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), abs(number) < 1e-12 ? 0 : number) }
    private static func escape(_ text: String) -> String { MathMarkup.escape(text) }
    private static func text(_ value: String, x: Double, y: Double, anchor: String = "start") -> String {
        "<text x=\"\(f(x))\" y=\"\(f(y))\" text-anchor=\"\(anchor)\" fill=\"currentColor\" font-size=\"12\">\(escape(value))</text>"
    }
}

/// 有界的算术表达式解析器：接受指定变量、常量和白名单函数，无 JavaScript/eval。
struct CurveExpression {
    private indirect enum Node {
        case number(Double), x, y, negate(Node), binary(Character, Node, Node), function(String, Node)
        func value(_ x: Double, _ y: Double) -> Double {
            switch self {
            case .number(let value): return value
            case .x: return x
            case .y: return y
            case .negate(let node): return -node.value(x, y)
            case .binary(let op, let a, let b):
                let lhs = a.value(x, y), rhs = b.value(x, y)
                switch op {
                case "+": return lhs+rhs
                case "-": return lhs-rhs
                case "*": return lhs*rhs
                case "/": return lhs/rhs
                default: return pow(lhs, rhs)
                }
            case .function(let name, let node):
                let value = node.value(x, y)
                switch name {
                case "sin": return sin(value)
                case "cos": return cos(value)
                case "tan": return tan(value)
                case "asin": return asin(value)
                case "acos": return acos(value)
                case "atan": return atan(value)
                case "sqrt": return sqrt(value)
                case "abs": return abs(value)
                case "exp": return exp(value)
                case "ln", "log": return log(value)
                case "log10": return log10(value)
                case "floor": return floor(value)
                case "ceil": return ceil(value)
                default: return .nan
                }
            }
        }
    }
    private enum Token: Equatable { case number(Double), name(String), symbol(Character) }
    private struct Parser {
        let tokens: [Token]; let variables: Set<String>; var index = 0; var depth = 0
        mutating func take(_ symbol: Character) -> Bool {
            guard index < tokens.count, tokens[index] == .symbol(symbol) else { return false }
            index += 1; return true
        }
        mutating func sum() -> Node? {
            guard var node = product() else { return nil }
            while index < tokens.count {
                if take("+") { guard let rhs = product() else { return nil }; node = .binary("+", node, rhs) }
                else if take("-") { guard let rhs = product() else { return nil }; node = .binary("-", node, rhs) }
                else { break }
            }
            return node
        }
        mutating func product() -> Node? {
            guard var node = unary() else { return nil }
            while index < tokens.count {
                if take("*") { guard let rhs = unary() else { return nil }; node = .binary("*", node, rhs) }
                else if take("/") { guard let rhs = unary() else { return nil }; node = .binary("/", node, rhs) }
                else { break }
            }
            return node
        }
        mutating func unary() -> Node? {
            depth += 1; defer { depth -= 1 }; guard depth <= 32 else { return nil }
            if take("+") { return unary() }
            if take("-") { return unary().map { .negate($0) } }
            guard let lhs = atom() else { return nil }
            if take("^") { guard let rhs = unary() else { return nil }; return .binary("^", lhs, rhs) }
            return lhs
        }
        mutating func atom() -> Node? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]; index += 1
            switch token {
            case .number(let value): return .number(value)
            case .name(let name):
                if name == "x", variables.contains(name) { return .x }
                if name == "y", variables.contains(name) { return .y }
                if name == "pi" || name == "π" { return .number(.pi) }
                if name == "e" { return .number(M_E) }
                guard ["sin","cos","tan","asin","acos","atan","sqrt","abs","exp","ln","log","log10","floor","ceil"].contains(name), take("("), let argument = sum(), take(")") else { return nil }
                return .function(name, argument)
            case .symbol("("):
                guard let node = sum(), take(")") else { return nil }; return node
            default: return nil
            }
        }
    }
    private let node: Node
    init?(_ source: String, variables: Set<String> = ["x"]) {
        guard !source.isEmpty, source.count <= 512 else { return nil }
        let chars = Array(source.lowercased()); var index = 0; var tokens: [Token] = []
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace { index += 1; continue }
            if "+-*/^()".contains(char) { tokens.append(.symbol(char)); index += 1 }
            else if char.isASCII && char.isNumber || char == "." {
                let start = index; index += 1
                while index < chars.count && ((chars[index].isASCII && chars[index].isNumber) || chars[index] == ".") { index += 1 }
                if index < chars.count && chars[index] == "e" {
                    index += 1
                    if index < chars.count && (chars[index] == "+" || chars[index] == "-") { index += 1 }
                    while index < chars.count && chars[index].isASCII && chars[index].isNumber { index += 1 }
                }
                guard let number = Double(String(chars[start..<index])), number.isFinite else { return nil }
                tokens.append(.number(number))
            } else if char.isLetter {
                let start = index; index += 1
                while index < chars.count && (chars[index].isLetter || chars[index].isNumber) { index += 1 }
                tokens.append(.name(String(chars[start..<index])))
            } else { return nil }
            guard tokens.count <= 256 else { return nil }
        }
        var parser = Parser(tokens: tokens, variables: variables)
        guard let parsed = parser.sum(), parser.index == tokens.count else { return nil }
        node = parsed
    }
    func value(at x: Double, y: Double = 0) -> Double { node.value(x, y) }
}
