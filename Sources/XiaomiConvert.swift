import Foundation

/// 小米笔记私有 XML 内容 → ENML（Evernote / Apple 备忘录可导入的 HTML 子集）的转换引擎。
///
/// 分两阶段：
/// 1. `toHtmlFragment`：把小米私有标签（`<text>`、`<bullet>`、`<size>`…）改写成普通 HTML。
///    采用 token 流处理，**不依赖源码里是否有换行**——参考实现用 `/<bullet ...\/>(.*?)\n/`
///    这类正则，换行缺失时整段列表会静默丢失。
/// 2. `sanitizeToENML`：按 ENML 白名单清洗，并把图片换成 `<en-media>`。
///
/// 思路参照 idootop/mi-note-export（MIT）与 aerragha/xiaomi-notes-to-apple-notes（MIT）。
enum XiaomiConvert {

    // MARK: - ENML 白名单

    static let safeElements: Set<String> = [
        "div", "p", "span", "br", "b", "strong", "i", "em", "u", "s", "del", "strike",
        "ul", "ol", "li", "blockquote", "pre", "code", "a", "h1", "h2", "h3", "h4",
        "h5", "h6", "hr", "table", "thead", "tbody", "tfoot", "tr", "td", "th",
        "center", "font", "sup", "sub", "big", "small", "ins", "cite", "q", "dl",
        "dt", "dd", "kbd", "samp", "var", "abbr", "acronym", "col", "colgroup", "tt",
    ]

    static let styleAllowed: Set<String> = ["div", "span", "p", "td", "th"]

    // MARK: - 基础工具

    static func escapeXML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    /// 只还原小米会写出的几种实体，不处理十六进制实体
    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
                       ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }

    /// 正则替换；transform 收到 [完整匹配, 捕获组…]
    static func replaceRegex(_ pattern: String,
                             in source: String,
                             options: NSRegularExpression.Options = [],
                             transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return source }
        let ns = source as NSString
        let matches = re.matches(in: source, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return source }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            var groups: [String] = [ns.substring(with: m.range)]
            for g in 1..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// 小米把荧光笔颜色按 BGR 存，转成 CSS 用的 RGB
    private static func bgrToRGB(_ raw: String) -> String? {
        let hex = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        let filtered = hex.filter { $0.isHexDigit }
        guard filtered.count >= 6 else { return nil }
        let c = Array(filtered.suffix(6))
        return String(c[4..<6]) + String(c[2..<4]) + String(c[0..<2])
    }

    private static func indentPx(_ raw: String?) -> Int {
        let level = max(0, (Int(raw ?? "1") ?? 1) - 1)
        return level * 16
    }

    // MARK: - 思维导图

    static let mindPrefix = "<MiMind Prdfix>"

    static func isMindMap(_ content: String) -> Bool { content.hasPrefix(mindPrefix) }

    private static func mindRoot(_ content: String) -> [String: Any]? {
        let jsonStr = String(content.dropFirst(mindPrefix.count))
        guard let d1 = jsonStr.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let innerStr = outer["content"] as? String,
              let d2 = innerStr.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let root = inner["data"] as? [String: Any]
        else { return nil }
        return root
    }

    static func mindRootLabel(_ content: String) -> String? {
        guard let root = mindRoot(content) else { return nil }
        let label = (root["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    /// 思维导图直接产出 ENML 片段（自己转义，不再过白名单）
    private static func mindMapToENML(_ content: String) -> String {
        guard let root = mindRoot(content) else {
            return "<div>\(escapeXML(content))</div>"
        }
        func build(_ node: [String: Any]) -> String {
            guard let kids = node["children"] as? [[String: Any]], !kids.isEmpty else { return "" }
            let items = kids.map { c -> String in
                let label = escapeXML(c["label"] as? String ?? "")
                return "<li>\(label)\(build(c))</li>"
            }.joined()
            return "<ul>\(items)</ul>"
        }
        let title = escapeXML(root["label"] as? String ?? "思维导图")
        return "<h1>\(title)</h1>\(build(root))"
    }

    /// 小米把内嵌图片写成 `☺ <fileId><0/></>` 这种占位符，先还原成 `<img fileid="…"/>`
    static func normalizeImageMarkers(_ content: String, fileIds: [String]) -> String {
        var out = content
        for id in fileIds {
            let img = "<img fileid=\"\(id)\"/>"
            out = out.replacingOccurrences(of: "☺ \(id)<0/></>", with: img)
            out = out.replacingOccurrences(of: "☺ \(id)<1/></>", with: img)
            out = out.replacingOccurrences(of: "☺ \(id)", with: img)
        }
        return out
    }

    // MARK: - 阶段一：小米 XML → HTML

    /// 列表 / 待办标记在源码里是独立的自闭合标签，内容跟在后面。
    private enum Pending {
        case none
        case bullet(Int)
        case order(Int)
        case check(Int, Bool)
    }

    private enum OpenMark {
        case tag(String)      // 普通标签
        case text(String)     // text 元素，携带收尾时要输出的闭合串
    }

    /// 小米标签名 → 输出的 HTML 标签名。
    /// 开标签压栈时用的是 HTML 名，所以处理 `</b>`、`</size>` 这类闭合标签时
    /// 必须先把小米名映射过去，否则永远匹配不上、标签会一直不闭合。
    private static let htmlTagFor: [String: String] = [
        "size": "h1",
        "mid-size": "h2",
        "h3-size": "h3",
        "b": "strong",
        "i": "em",
        "u": "u",
        "delete": "del",
        "quote": "blockquote",
        "background": "span",
        "left": "div",
        "right": "div",
        "center": "div",
    ]

    private static func pendingPair(_ p: Pending) -> (open: String, close: String) {
        switch p {
        case .none:
            return ("", "")
        case .bullet(let n):
            return ("<li style=\"list-style-type:disc;list-style-position:inside;margin-left:\(indentPx(String(n)))px\">", "</li>")
        case .order(let n):
            return ("<li style=\"list-style-type:decimal;list-style-position:inside;margin-left:\(indentPx(String(n)))px\">", "</li>")
        case .check(let n, let checked):
            return ("<div style=\"margin-left:\(indentPx(String(n)))px\">\(checked ? "\u{2611}" : "\u{2610}") ", "</div>")
        }
    }

    private static func flushPending(_ out: inout String, _ pending: inout Pending) {
        guard case .none = pending else {
            let (o, c) = pendingPair(pending)
            out += o + c
            pending = .none
            return
        }
    }

    /// 小米 XML → HTML 片段（不做实体转义，交给阶段二统一处理）
    static func toHtmlFragment(_ raw: String, files: [MiFileRef]) -> String {
        let source = normalizeImageMarkers(raw, fileIds: files.map { $0.fileId })
        let tokens = tokenize(source)

        var out = ""
        var openMarks: [OpenMark] = []
        var pending: Pending = .none

        func closeDownTo(_ predicate: (OpenMark) -> Bool, emitMatched: Bool) {
            guard let idx = openMarks.lastIndex(where: predicate) else { return }
            while openMarks.count - 1 > idx {
                if case .tag(let n) = openMarks.removeLast() { out += "</\(n)>" }
            }
            guard emitMatched, let last = openMarks.last else { return }
            openMarks.removeLast()
            switch last {
            case .tag(let n): out += "</\(n)>"
            case .text(let closeTag): out += closeTag
            }
        }

        for token in tokens {
            switch token {

            case .text(let t):
                if case .none = pending {
                    out += t
                } else if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 标记和内容之间的空白，丢掉
                } else {
                    let (o, c) = pendingPair(pending)
                    out += o + t + c
                    pending = .none
                }

            case .close(let name):
                if name == "text" {
                    closeDownTo({ if case .text = $0 { return true }; return false }, emitMatched: true)
                } else {
                    let target = htmlTagFor[name] ?? name
                    closeDownTo({ if case .tag(let n) = $0 { return n == target }; return false }, emitMatched: true)
                }

            case .tag(let name, let attrs, let selfClosing):
                let a = Dictionary(attrs, uniquingKeysWith: { first, _ in first })

                switch name {
                // 忽略的标记
                case "new-format":
                    break

                // 列表 / 待办：只记状态，等后面的内容
                case "bullet":
                    flushPending(&out, &pending)
                    pending = .bullet(Int(a["indent"] ?? "1") ?? 1)
                case "order":
                    flushPending(&out, &pending)
                    pending = .order(Int(a["indent"] ?? "1") ?? 1)
                case "input":
                    flushPending(&out, &pending)
                    pending = .check(Int(a["indent"] ?? "1") ?? 1, a["checked"] != nil)

                // 正文块
                case "text":
                    if case .none = pending {
                        let px = indentPx(a["indent"])
                        out += px == 0 ? "<div>" : "<div style=\"margin-left:\(px)px\">"
                        openMarks.append(.text("</div>"))
                    } else {
                        let (o, c) = pendingPair(pending)
                        out += o
                        openMarks.append(.text(c))
                        pending = .none
                    }

                // 行内样式
                case "size":      out += "<h1>"; openMarks.append(.tag("h1"))
                case "mid-size":  out += "<h2>"; openMarks.append(.tag("h2"))
                case "h3-size":   out += "<h3>"; openMarks.append(.tag("h3"))
                case "b":         out += "<strong>"; openMarks.append(.tag("strong"))
                case "i":         out += "<em>"; openMarks.append(.tag("em"))
                case "u":         out += "<u>"; openMarks.append(.tag("u"))
                case "delete":    out += "<del>"; openMarks.append(.tag("del"))
                case "quote":     out += "<blockquote>"; openMarks.append(.tag("blockquote"))

                case "left":
                    flushPending(&out, &pending)
                    out += "<div style=\"text-align:left\">"; openMarks.append(.tag("div"))
                case "right":
                    flushPending(&out, &pending)
                    out += "<div style=\"text-align:right\">"; openMarks.append(.tag("div"))
                case "center":
                    flushPending(&out, &pending)
                    out += "<div style=\"text-align:center\">"; openMarks.append(.tag("div"))

                case "background":
                    let rgb = bgrToRGB(a["color"] ?? "")
                    out += rgb.map { "<span style=\"background-color:#\($0)\">" } ?? "<span>"
                    openMarks.append(.tag("span"))

                case "hr":
                    flushPending(&out, &pending)
                    out += "<hr/>"

                // 附件
                case "img":
                    // `☺ <fileId><0/></>` 会被统一还原成 <img>，所以这里要按真实类型分流
                    let fid = a["fileid"] ?? ""
                    if let f = files.first(where: { $0.fileId == fid }) {
                        if f.isImage {
                            out += "<img fileid=\"\(fid)\"/>"
                        } else {
                            flushPending(&out, &pending)
                            let label = f.mimeType.hasPrefix("audio/") ? "录音附件" : "视频附件"
                            out += "<div>[\(label)：\(fid)]</div>"
                        }
                    }
                case "sound", "video":
                    flushPending(&out, &pending)
                    if let fid = a["fileid"] {
                        let label = name == "sound" ? "录音附件" : "视频附件"
                        out += "<div>[\(label)：\(fid)]</div>"
                    }

                default:
                    // 白名单外的私有标签：只拆标签，保留内容
                    _ = selfClosing
                }
            }
        }

        flushPending(&out, &pending)
        // 收尾补齐
        while let last = openMarks.popLast() {
            switch last {
            case .tag(let n): out += "</\(n)>"
            case .text(let closeTag): out += closeTag
            }
        }
        out = out.replacingOccurrences(of: "<div></div>", with: "<br/>")
        out = out.replacingOccurrences(of: " style=\"margin-left:0px\"", with: "")
        return out
    }

    // MARK: - 阶段二：HTML → ENML

    enum Token {
        case text(String)
        case tag(name: String, attrs: [(String, String)], selfClosing: Bool)
        case close(String)
    }

    /// 容错的标签扫描器。小米内容不是严格 XML，遇到解析不了的 `<` 就当作普通文字。
    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var buffer = ""
        var i = 0

        func flushText() {
            if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" }
        }

        while i < chars.count {
            guard chars[i] == "<" else {
                buffer.append(chars[i]); i += 1; continue
            }
            var j = i + 1
            var quote: Character?
            while j < chars.count {
                let c = chars[j]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    break
                }
                j += 1
            }
            guard j < chars.count else {
                buffer.append(contentsOf: chars[i...]); break
            }
            let inner = String(chars[(i + 1)..<j])
            if let t = parseTag(inner) {
                flushText()
                tokens.append(t)
            } else if inner.hasPrefix("!") || inner.hasPrefix("?") || inner.hasPrefix("/") {
                flushText()
                // 注释 / doctype / 无名的闭合标签，丢弃
            } else {
                buffer.append("<" + inner + ">")
            }
            i = j + 1
        }
        flushText()
        return tokens
    }

    static func parseTag(_ inner: String) -> Token? {
        var s = inner.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.hasPrefix("/") {
            let name = s.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
            return name.isEmpty ? nil : .close(name)
        }
        if s.hasPrefix("!") || s.hasPrefix("?") { return nil }

        var selfClosing = false
        if s.hasSuffix("/") { selfClosing = true; s = String(s.dropLast()) }

        var name = s
        var rest = ""
        if let sp = s.firstIndex(where: { $0.isWhitespace }) {
            name = String(s[s.startIndex..<sp])
            rest = String(s[sp...])
        }
        name = name.lowercased()
        guard name.first?.isLetter == true || name.first == "_" else { return nil }

        var attrs: [(String, String)] = []
        if !rest.isEmpty,
           let re = try? NSRegularExpression(pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')") {
            let ns = rest as NSString
            for m in re.matches(in: rest, options: [], range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1)).lowercased()
                let dq = m.range(at: 3)
                let sq = m.range(at: 4)
                let value = dq.location != NSNotFound ? ns.substring(with: dq)
                    : (sq.location != NSNotFound ? ns.substring(with: sq) : "")
                attrs.append((key, value))
            }
        }
        return .tag(name: name, attrs: attrs, selfClosing: selfClosing)
    }

    /// 按 ENML 白名单清洗，`<img fileid="…"/>` 换成 `<en-media/>`
    /// - Parameter imageMeta: fileId -> (mime, md5hex)
    static func sanitizeToENML(_ html: String, imageMeta: [String: (mime: String, hash: String)]) -> String {
        let tokens = tokenize(html)
        var out = ""
        var openStack: [String] = []
        var implicitUL = false
        var explicitListDepth = 0

        func closeImplicitList() {
            guard implicitUL else { return }
            out += "</ul>"
            implicitUL = false
            if let idx = openStack.lastIndex(of: "ul") { openStack.remove(at: idx) }
        }

        for token in tokens {
            switch token {

            case .text(let t):
                // 先还原实体再转义：这样用户输入的 "<" 不会在词法阶段被当成标签
                out += escapeXML(decodeEntities(t))

            case .tag(let name, let attrs, let selfClosing):
                let attrMap = Dictionary(attrs, uniquingKeysWith: { a, _ in a })

                if name == "img" {
                    let fid = attrMap["fileid"] ?? ""
                    if let meta = imageMeta[fid] {
                        out += "<en-media type=\"\(escapeXML(meta.mime))\" hash=\"\(meta.hash)\"/>"
                    }
                    continue
                }
                if name == "input" {
                    out += (attrMap["checked"] != nil) ? "\u{2611} " : "\u{2610} "
                    continue
                }
                guard safeElements.contains(name) else { continue }

                if name == "li" {
                    if explicitListDepth == 0 && !implicitUL {
                        out += "<ul>"
                        openStack.append("ul")
                        implicitUL = true
                    }
                } else {
                    closeImplicitList()
                    if name == "ul" || name == "ol" { explicitListDepth += 1 }
                }

                var attrString = ""
                if name == "a", let href = attrMap["href"], !href.isEmpty {
                    attrString += " href=\"\(escapeXML(href))\""
                }
                if styleAllowed.contains(name), let style = attrMap["style"], !style.isEmpty {
                    attrString += " style=\"\(escapeXML(style))\""
                }
                if name == "font" {
                    if let color = attrMap["color"] { attrString += " color=\"\(escapeXML(color))\"" }
                }

                if selfClosing || name == "br" || name == "hr" {
                    out += "<\(name)\(attrString)/>"
                } else {
                    out += "<\(name)\(attrString)>"
                    openStack.append(name)
                }

            case .close(let name):
                if name == "li" {
                    if let idx = openStack.lastIndex(of: "li") {
                        openStack.remove(at: idx)
                        out += "</li>"
                    }
                    continue
                }
                closeImplicitList()
                if name == "ul" || name == "ol" { explicitListDepth = max(0, explicitListDepth - 1) }
                if safeElements.contains(name), let idx = openStack.lastIndex(of: name) {
                    openStack.remove(at: idx)
                    out += "</\(name)>"
                }
            }
        }

        closeImplicitList()
        for name in openStack.reversed() { out += "</\(name)>" }
        return out
    }

    // MARK: - 对外入口

    /// 小米 XML → ENML 主体
    static func toENMLBody(_ raw: String,
                           files: [MiFileRef],
                           imageMeta: [String: (mime: String, hash: String)]) -> String {
        if isMindMap(raw) { return mindMapToENML(raw) }
        return sanitizeToENML(toHtmlFragment(raw, files: files), imageMeta: imageMeta)
    }

    /// 小米原文 → **用于界面显示**的 HTML 片段。
    ///
    /// 分流规则和 `toENMLBody` 一致：思维导图走 `mindMapToENML`，其余走 `toHtmlFragment`。
    ///
    /// **调用方不要自己判断 `isMindMap` 再选函数。** 这个分流是领域知识，
    /// 只在这里实现一处才不会漏——漏了的后果是思维导图笔记被当成普通 XML 解析，
    /// 渲染出一堆乱码。
    static func toDisplayHTML(_ raw: String, files: [MiFileRef]) -> String {
        if isMindMap(raw) { return mindMapToENML(raw) }
        return toHtmlFragment(raw, files: files)
    }

    /// 标题：优先 extraInfo.title，其次是思维导图根节点，最后正文首行
    static func deriveTitle(explicitTitle: String?, rawContent: String) -> String {
        if let t = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if isMindMap(rawContent), let label = mindRootLabel(rawContent) { return label }

        var text = replaceRegex("<[^>]+>", in: rawContent) { _ in "\n" }
        text = decodeEntities(text)
        let first = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let f = first, !f.isEmpty { return String(f.prefix(100)) }
        return "未命名"
    }
}
