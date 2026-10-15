import SwiftUI
import AppKit

// 笔记正文渲染：`XiaomiConvert.toHtmlFragment` 的输出 → `[NoteBlock]` → SwiftUI 视图。
//
// 解析与渲染分离，和 `MarkdownLite` 同一套路子：
//   - `NoteHTML.parse` 是纯函数，没有副作用，可以反复调用；
//   - `NoteHTMLView` 只吃 `[NoteBlock]`，不认识 HTML。
//
// 为什么不用 `AttributedString(markdown:)` 或 WKWebView：
//   - 输入不是 Markdown，是小米自己的一层 HTML 方言，`,` 的列表连 `<ul>` 都没有；
//   - 笔记正文要随浅色/深色模式、字号走原生排版，WebView 会把这件事锁死在网页里。
//
// ⚠️ 输入形态的两个坑（都已按实际输出核对）：
//   1. 列表项是**裸 `<li>`**，外面没有 `<ul>` / `<ol>`，类型只能从
//      `style="list-style-type:disc|decimal"` 读；
//   2. 转换器逐 token 拼接，**不吞源码里的换行**，所以段落文字尾部常带 `\n`
//      （例如 `<li …>第一项\n</li>`），标签之间也有裸换行。解析时要按 HTML 的
//      空白折叠规则处理，否则每段都会多出一个空行。

// MARK: - 解析器

/// 小米 HTML 片段 → 块级模型。纯函数，无副作用。
enum NoteHTML {

    /// HTML 片段 → `[NoteBlock]`。
    ///
    /// 白名单外的标签一律**只丢标签、保留文字**，不会整块丢弃。
    static func parse(_ html: String) -> [NoteBlock] {
        var parser = NoteHTMLParser()
        parser.consume(NoteTokenizer.tokenize(html))
        parser.finish()
        return numbering(parser.blocks)
    }

    /// 有序列表的显示序号：按缩进层级分别累加。
    ///
    /// 规则：**每个缩进层级各有一个独立计数器**，同层连续出现就 1、2、3…；
    /// 下探到更深层时深层从 1 开始，**回到浅层要继续数而不是重新从 1 开始**
    /// （与 Word / HTML / Markdown 的通行行为一致）。
    /// 只有「列表被别的块打断」才整体归零——那确实是新的一段列表。
    /// 渲染侧用它拿显示序号，所以即使调用方手工拼 `[NoteBlock]`、`number` 填了 0，
    /// 显示也不会错。
    static func displayNumbers(_ blocks: [NoteBlock]) -> [Int] {
        numbering(blocks).map { block in
            if case .numbered(_, let number, _) = block { return number }
            return 0
        }
    }

    /// 唯一的编号实现：解析回填 `number` 与实际渲染取序号都走这里，避免两套规则走偏。
    private static func numbering(_ blocks: [NoteBlock]) -> [NoteBlock] {
        var out = blocks
        var counters: [Int: Int] = [:]

        for index in out.indices {
            guard case .numbered(let indent, _, let runs) = out[index] else {
                // 列表被别的块打断 → 下一段 decimal 整体从 1 重新开始
                counters.removeAll()
                continue
            }
            // 关键：**不判断"上次是不是同一缩进"**。
            // 早先那版要求 lastIndent == indent 才继续数，于是"下探再回到浅层"
            // 会重新从 1 开始；用户预期是接着数（1,2 → 深层 1 → 回到浅层 3）。
            let number = (counters[indent] ?? 0) + 1
            counters[indent] = number
            // 下探后清掉更深层的计数，回来时重新从 1 开始。
            // 先收集 key 再删——边遍历 keys 边改字典会运行时崩。
            for key in counters.keys.filter({ $0 > indent }) {
                counters.removeValue(forKey: key)
            }
            out[index] = .numbered(indent: indent, number: number, runs: runs)
        }
        return out
    }
}

// MARK: - 词法

/// 扫描出来的一枚 token。结构刻意和 `XiaomiConvert.Token` 对齐，但这里独立实现：
/// 渲染层不该为了拿一个扫描器去依赖转换引擎。
private enum NoteToken {
    case text(String)
    case open(name: String, attrs: [String: String], selfClosing: Bool)
    case close(String)
}

private enum NoteTokenizer {

    /// 容错的标签扫描器：遇到解析不了的 `<` 就当作普通文字，不丢内容。
    static func tokenize(_ source: String) -> [NoteToken] {
        var tokens: [NoteToken] = []
        var buffer = ""
        let chars = Array(source)
        var i = 0

        func flushText() {
            if !buffer.isEmpty {
                tokens.append(.text(buffer))
                buffer = ""
            }
        }

        while i < chars.count {
            guard chars[i] == "<" else {
                buffer.append(chars[i])
                i += 1
                continue
            }
            // 找到与 `<` 配对的 `>`，引号内的 `>` 不算
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
                buffer.append(contentsOf: chars[i...])
                break
            }
            let inner = String(chars[(i + 1)..<j])
            i = j + 1

            if let token = parseTag(inner) {
                flushText()
                tokens.append(token)
            } else {
                // 注释 / doctype / 解析不出名字的尖括号 → 当文字原样留着
                buffer += "<" + inner + ">"
            }
        }
        flushText()
        return tokens
    }

    private static func parseTag(_ inner: String) -> NoteToken? {
        var s = inner.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("!") || s.hasPrefix("?") { return nil }

        if s.hasPrefix("/") {
            let name = s.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
            return name.isEmpty ? nil : .close(name)
        }

        var selfClosing = false
        if s.hasSuffix("/") {
            selfClosing = true
            s = String(s.dropLast())
        }

        var name = s
        var rest = ""
        if let space = s.firstIndex(where: { $0.isWhitespace }) {
            name = String(s[s.startIndex..<space])
            rest = String(s[space...])
        }
        name = name.lowercased()
        guard let first = name.first, first.isLetter else { return nil }

        return .open(name: name, attrs: attributes(rest), selfClosing: selfClosing)
    }

    /// 只解出 `key="value"` 这一种形态，够用：真正要用到的属性只有
    /// `style` / `fileid` / `href`，都是引号包着的。
    private static func attributes(_ raw: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let chars = Array(raw)
        var i = 0

        func skipSpaces() {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
        }

        while i < chars.count {
            skipSpaces()
            guard i < chars.count else { break }

            var name = ""
            while i < chars.count, chars[i] != "=", !chars[i].isWhitespace {
                name.append(chars[i])
                i += 1
            }
            skipSpaces()

            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                skipSpaces()
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    while i < chars.count, chars[i] != quote {
                        value.append(chars[i])
                        i += 1
                    }
                    if i < chars.count { i += 1 }
                } else {
                    while i < chars.count, !chars[i].isWhitespace {
                        value.append(chars[i])
                        i += 1
                    }
                }
            }
            if !name.isEmpty {
                attrs[name.lowercased()] = value
            }
        }
        return attrs
    }
}

// MARK: - 语法

/// 行内标记。`span`（荧光笔）和 `a`（链接）带着值，其余只占位，保证闭合标签能配对。
private struct InlineMark {
    var category: String
    var value: String?

    static let bold = InlineMark(category: "bold")
    static let italic = InlineMark(category: "italic")
    static let underline = InlineMark(category: "underline")
    static let strike = InlineMark(category: "strike")
    static let code = InlineMark(category: "code")

    static func highlight(_ hex: String?) -> InlineMark { InlineMark(category: "highlight", value: hex) }
    static func link(_ href: String) -> InlineMark { InlineMark(category: "link", value: href) }
}

/// 正在拼的块。小米的输出是扁平的，块不会真的嵌套，
/// 所以这里只保留"当前这一块"，而不是一个块栈。
private struct BlockFrame {
    var tag: String                       // div / h1 / h2 / h3 / li / blockquote / pre
    var align: NoteAlign = .leading
    var indent: Int = 0                   // 像素，来自 style="margin-left:Npx"
    var listKind: ListKind = .none
    var literal: String?                  // pre 的原始文本（含换行）
}

private enum ListKind { case none, disc, decimal }

private struct NoteHTMLParser {
    private(set) var blocks: [NoteBlock] = []

    private var runs: [NoteRun] = []
    private var marks: [InlineMark] = []
    private var block: BlockFrame?

    /// `<ul>` / `<ol>` 的嵌套深度。**只用来算缩进，不用来判断列表类型。**
    ///
    /// 小米普通笔记的列表项是裸 `<li>`、没有容器标签，走那条路时它恒为 0；
    /// 只有思维导图路径会输出真正的嵌套 `<ul><li>`，那时它才起作用。
    private var listDepth = 0

    /// 每嵌套一层 `<ul>` 额外缩进的像素。
    /// 取 16 是为了和转换器的步长一致（`XiaomiConvert.indentPx` 是 `level * 16`），
    /// 否则思维导图的缩进会和普通笔记的缩进对不齐。
    private static let listDepthStep = 16

    mutating func consume(_ tokens: [NoteToken]) {
        for token in tokens {
            switch token {
            case .text(let text):
                appendText(text)
            case .open(let name, let attrs, _):
                open(name, attrs)
            case .close(let name):
                close(name)
            }
        }
    }

    mutating func finish() {
        flushBlock()
    }

    // MARK: 标签

    private mutating func open(_ name: String, _ attrs: [String: String]) {
        switch name {
        case "div", "p":
            startBlock(BlockFrame(tag: "div",
                                  align: NoteHTMLParser.align(attrs),
                                  indent: NoteHTMLParser.indent(attrs)))

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = min(Int(name.dropFirst()) ?? 3, 3)
            startBlock(BlockFrame(tag: "h\(level)"))

        case "li":
            // 列表**类型**只能从 style 里读：小米普通笔记是裸 <li>，父标签不存在。
            // 缩进则是两件事相加 —— style 里的 margin-left + <ul> 嵌套深度 × 步长。
            // 类型和缩进是正交的，别混在一起判。
            let style = NoteHTMLParser.compactStyle(attrs)
            let kind: ListKind = style.contains("list-style-type:decimal") ? .decimal : .disc
            startBlock(BlockFrame(tag: "li",
                                  indent: NoteHTMLParser.indent(attrs) + listDepth * Self.listDepthStep,
                                  listKind: kind))

        case "blockquote":
            startBlock(BlockFrame(tag: "blockquote"))

        case "pre":
            startBlock(BlockFrame(tag: "pre", literal: ""))

        case "ul", "ol":
            // 普通笔记的列表项是裸 <li>、没有容器标签，所以这里通常不出现；
            // 思维导图路径会输出嵌套的 <ul><li>，此时用深度换算出缩进。
            listDepth += 1

        case "br":
            if block == nil {
                // 空 div 被转换器换成 <br/>，一个 br 就是源码里的一行空行
                blocks.append(.paragraph(align: .leading, indent: 0, runs: []))
            } else {
                appendText("\n")
            }

        case "hr":
            flushBlock()
            blocks.append(.divider)

        case "img":
            // 图片是块级；若正拼着一段文字，先把那段收掉，保证顺序不乱
            flushBlock()
            let fileId = attrs["fileid"] ?? ""
            if !fileId.isEmpty {
                blocks.append(.image(fileId: fileId))
            }

        case "strong", "b":
            marks.append(.bold)
        case "em", "i":
            marks.append(.italic)
        case "u":
            marks.append(.underline)
        case "del", "s", "strike":
            marks.append(.strike)
        case "code":
            marks.append(.code)
        case "span":
            marks.append(.highlight(NoteHTMLParser.backgroundHex(attrs)))
        case "a":
            marks.append(.link(attrs["href"] ?? ""))

        default:
            // 白名单外的标签：只丢标签，里面的文字照收
            break
        }
    }

    private mutating func close(_ name: String) {
        switch name {
        case "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre":
            closeBlock(name)
        case "ul", "ol":
            listDepth = max(0, listDepth - 1)
        case "strong", "b":
            popMark("bold")
        case "em", "i":
            popMark("italic")
        case "u":
            popMark("underline")
        case "del", "s", "strike":
            popMark("strike")
        case "code":
            popMark("code")
        case "span":
            popMark("highlight")
        case "a":
            popMark("link")
        default:
            break
        }
    }

    // MARK: 文字与样式

    private mutating func appendText(_ raw: String) {
        guard !raw.isEmpty else { return }
        // 实体要在确定它"是文字"之后才还原，否则还原出来的 `<` 会被当成标签。
        let text = NoteHTMLParser.decodeEntities(raw)

        // pre 里原样保留，包括换行
        if let current = block, current.tag == "pre" {
            block?.literal = (current.literal ?? "") + text
            return
        }

        if block == nil {
            // 顶层的裸文字。转换器会把 `<background>` 单独输出成裸 `<span>`，
            // 所以这里必须能凭空开一个段落，不能把文字丢掉。
            // 但标签之间的换行也是裸文字 —— 纯空白直接丢，别变成空段落。
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            startBlock(BlockFrame(tag: "div"))
        }

        var run = currentStyle()
        run.text = text
        appendRun(run)
    }

    private mutating func appendRun(_ run: NoteRun) {
        guard !run.text.isEmpty else { return }
        if var last = runs.last, NoteHTMLParser.sameStyle(last, run) {
            last.text += run.text
            runs[runs.count - 1] = last
        } else {
            runs.append(run)
        }
    }

    /// 把当前所有行内标记合并成一个 run 模板（嵌套样式叠加成一份）。
    private func currentStyle() -> NoteRun {
        var run = NoteRun(text: "")
        for mark in marks {
            switch mark.category {
            case "bold": run.bold = true
            case "italic": run.italic = true
            case "underline": run.underline = true
            case "strike": run.strike = true
            case "code": run.code = true
            case "highlight": run.background = mark.value
            case "link": run.link = mark.value
            default: break
            }
        }
        return run
    }

    private mutating func popMark(_ category: String) {
        guard let index = marks.lastIndex(where: { $0.category == category }) else { return }
        marks.remove(at: index)
    }

    // MARK: 块

    private mutating func startBlock(_ frame: BlockFrame) {
        flushBlock()
        block = frame
    }

    private mutating func closeBlock(_ name: String) {
        guard let current = block, Self.matches(close: name, open: current.tag) else { return }
        flushBlock()
    }

    private static func matches(close name: String, open tag: String) -> Bool {
        switch name {
        case "p": return tag == "div" || tag == "p"
        case "h4", "h5", "h6": return tag == "h1" || tag == "h2" || tag == "h3"
        default: return tag == name
        }
    }

    private mutating func flushBlock() {
        guard let current = block else { return }
        block = nil
        let captured = runs
        runs = []
        marks = []
        emit(current, captured)
    }

    private mutating func emit(_ frame: BlockFrame, _ captured: [NoteRun]) {
        if frame.tag == "pre" {
            blocks.append(.codeBlock(frame.literal ?? ""))
            return
        }

        let content = NoteHTMLParser.normalized(captured)
        guard !content.isEmpty else { return }   // 空块（例如只被 img 占着的 div）直接丢

        switch frame.tag {
        case "h1", "h2", "h3":
            blocks.append(.heading(level: Int(frame.tag.dropFirst()) ?? 3, runs: content))

        case "li":
            if frame.listKind == .decimal {
                // number 稍后由 numbering 统一回填
                blocks.append(.numbered(indent: frame.indent, number: 0, runs: content))
            } else {
                blocks.append(.bullet(indent: frame.indent, runs: content))
            }

        case "blockquote":
            blocks.append(.quote(runs: content))

        default:
            if let (checked, stripped) = NoteHTMLParser.checkbox(content) {
                blocks.append(.checkbox(indent: frame.indent, checked: checked, runs: stripped))
            } else {
                blocks.append(.paragraph(align: frame.align, indent: frame.indent, runs: content))
            }
        }
    }
}

// MARK: - 文本归一化

private extension NoteHTMLParser {

    /// 按 HTML 的空白规则收一收：连续空格/制表收敛成一个空格，换行单独保留
    /// （保留换行是为了让段内的 `<br/>` 还能断行），首尾空白交给 `trimmed`。
    static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        var pendingNewline = false

        for ch in text {
            if ch == "\n" || ch == "\r" {
                pendingNewline = true
                pendingSpace = false
            } else if ch.isWhitespace {
                if !pendingNewline { pendingSpace = true }
            } else {
                if pendingNewline {
                    out.append("\n")
                } else if pendingSpace {
                    out.append(" ")
                }
                out.append(ch)
                pendingNewline = false
                pendingSpace = false
            }
        }
        if pendingNewline {
            out.append("\n")
        } else if pendingSpace {
            out.append(" ")
        }
        return out
    }

    /// 去掉块首尾的空白，并顺手把同样式、被空白拆开的 run 合并回去。
    static func normalized(_ runs: [NoteRun]) -> [NoteRun] {
        var folded: [NoteRun] = []
        for run in runs {
            var copy = run
            copy.text = collapseWhitespace(run.text)
            guard !copy.text.isEmpty else { continue }
            if var last = folded.last, sameStyle(last, copy) {
                last.text += copy.text
                folded[folded.count - 1] = last
            } else {
                folded.append(copy)
            }
        }
        return trimmed(folded)
    }

    static func trimmed(_ runs: [NoteRun]) -> [NoteRun] {
        var out = runs
        while let first = out.first {
            let text = String(first.text.drop(while: { $0.isWhitespace }))
            if text.isEmpty {
                out.removeFirst()
            } else {
                out[0].text = text
                break
            }
        }
        while let last = out.last {
            let text = String(last.text.reversed().drop(while: { $0.isWhitespace }).reversed())
            if text.isEmpty {
                out.removeLast()
            } else {
                out[out.count - 1].text = text
                break
            }
        }
        return out
    }

    /// 待办项：转换器输出 `<div>☑ 文字</div>` / `<div>☐ 文字</div>`，
    /// 靠开头的记号判定，并把记号从正文里摘掉（渲染时换成真正的勾选框）。
    static func checkbox(_ runs: [NoteRun]) -> (checked: Bool, runs: [NoteRun])? {
        guard let first = runs.first, let head = first.text.first else { return nil }
        guard head == "\u{2611}" || head == "\u{2610}" else { return nil }
        let checked = head == "\u{2611}"

        var rest = String(first.text.dropFirst())
        if rest.hasPrefix(" ") { rest.removeFirst() }   // pendingPair 在记号后补了一个空格

        var out = runs
        if rest.isEmpty {
            out.removeFirst()
        } else {
            out[0].text = rest
        }
        return (checked, out)
    }
}

// MARK: - 属性解析

private extension NoteHTMLParser {

    /// 去掉 style 里的空格，`text-align: center` 和 `text-align:center` 才是同一种写法。
    static func compactStyle(_ attrs: [String: String]) -> String {
        (attrs["style"] ?? "").replacingOccurrences(of: " ", with: "")
    }

    static func indent(_ attrs: [String: String]) -> Int {
        let style = compactStyle(attrs)
        guard let range = style.range(of: "margin-left:") else { return 0 }
        var digits = ""
        var index = range.upperBound
        while index < style.endIndex, style[index].isNumber {
            digits.append(style[index])
            index = style.index(after: index)
        }
        return Int(digits) ?? 0
    }

    static func align(_ attrs: [String: String]) -> NoteAlign {
        let style = compactStyle(attrs)
        if style.contains("text-align:center") { return .center }
        if style.contains("text-align:right") { return .trailing }
        return .leading
    }

    /// 荧光笔颜色，输出是 `#RRGGBB`（转换器已把小米的 BGR 顺序翻正）。
    static func backgroundHex(_ attrs: [String: String]) -> String? {
        let style = compactStyle(attrs)
        guard let range = style.range(of: "background-color:") else { return nil }
        var hex = ""
        var index = range.upperBound
        while index < style.endIndex, style[index] != ";" {
            hex.append(style[index])
            index = style.index(after: index)
        }
        hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard hex.count == 6 else { return nil }
        return hex
    }

    /// 还原小米正文里会出现的几种实体。
    ///
    /// 依据：`XiaomiConvert.sanitizeToENML` 里要"先还原实体再转义"——说明正文文字
    /// 本身是带实体的，这里做同一件事，免得笔记里出现字面上的 `&amp;`。
    /// `&amp;` 放最后，避免把 `&amp;lt;` 二次还原成 `<`。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
                                      ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                      ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }

    /// 同样式判断：只有这些字段全等，两段文字才能并成一个 run。
    static func sameStyle(_ a: NoteRun, _ b: NoteRun) -> Bool {
        a.bold == b.bold
            && a.italic == b.italic
            && a.underline == b.underline
            && a.strike == b.strike
            && a.code == b.code
            && a.background == b.background
            && a.link == b.link
    }
}

// MARK: - 渲染

/// 正文各级字号。
///
/// `DS.Fonts` 只有 20 / 13 / 12 / 11 四档，缺 14 / 16 这两档，而正文需要
/// h1 > h2 > h3 的明显递进——只靠粗细区分，读长文时层级会糊掉。
/// 所以在本文件内补两级，理由写在这里而不是散在视图里：
///   - h1 直接复用 `DS.Fonts.screenTitle`（20，与页面标题同档）；
///   - h2 / h3 取 16 / 14，和正文 13 依次拉开，且都比正文大，
///     不至于让"标题"看起来比"正文"还轻。
private enum NoteFont {
    static let h1 = DS.Fonts.screenTitle                    // 20
    static let h2 = Font.system(size: 16, weight: .semibold)
    static let h3 = Font.system(size: 14, weight: .semibold)
    static let body = DS.Fonts.body                         // 13
    static let code = Font.system(size: 12, design: .monospaced)
}

/// 元素自身的尺度。不是间距，所以不进 `Space`。
private enum NoteMetric {
    /// 列表标记列宽。取 18 是为了和 `DSBulletRow` 的图标列同宽，
    /// 全应用的"标记列"保持一条线；`monospacedDigit` 保证 `9.` 和 `10.` 不跳。
    static let markerColumn: CGFloat = 18
    /// 引用左侧竖条宽度（元素内部微调，走 Optical）。
    static let quoteBar: CGFloat = DS.Optical.tight
}

/// 把 `[NoteBlock]` 画成纵向排列的正文。
struct NoteHTMLView: View {
    let blocks: [NoteBlock]
    /// fileId → 图片字节。缺的项显示灰底占位框，不留空白。
    let images: [String: Data]

    /// 序号在渲染期按缩进层级算，保证外部手工拼的块也能正确编号。
    private var numbers: [Int] { NoteHTML.displayNumbers(blocks) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(Array(blocks.indices), id: \.self) { index in
                blockView(blocks[index], number: numbers[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: NoteBlock, number: Int) -> some View {
        switch block {

        case .heading(let level, let runs):
            text(runs, font: headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let align, let indent, let runs):
            text(runs, font: NoteFont.body)
                .multilineTextAlignment(textAlignment(align))
                .frame(maxWidth: .infinity, alignment: frameAlignment(align))
                .padding(.leading, CGFloat(indent))

        case .bullet(let indent, let runs):
            HStack(alignment: .top, spacing: DS.Space.s) {
                Text("•")
                    .font(NoteFont.body)
                    .foregroundStyle(.secondary)
                    .frame(width: NoteMetric.markerColumn, alignment: .trailing)
                text(runs, font: NoteFont.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent))

        case .numbered(let indent, _, let runs):
            HStack(alignment: .top, spacing: DS.Space.s) {
                Text("\(number).")
                    .font(NoteFont.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: NoteMetric.markerColumn, alignment: .trailing)
                text(runs, font: NoteFont.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent))

        case .checkbox(let indent, let checked, let runs):
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: checked ? "checkmark.square" : "square")
                    .font(NoteFont.body)
                    .foregroundStyle(checked ? DS.Palette.accent : Color.secondary)
                    .frame(width: NoteMetric.markerColumn, alignment: .leading)
                    .padding(.top, DS.Optical.hairline)
                text(runs, font: NoteFont.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent))

        case .quote(let runs):
            HStack(alignment: .top, spacing: DS.Space.m) {
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Palette.stroke)
                    .frame(width: NoteMetric.quoteBar)
                text(runs, font: NoteFont.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(let code):
            Text(code)
                .font(NoteFont.code)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Optical.control)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.m))

        case .divider:
            Rectangle()
                .fill(DS.Palette.divider)
                .frame(height: DS.Optical.hairline)
                .padding(.vertical, DS.Space.xs)

        case .image(let fileId):
            imageView(fileId)
        }
    }

    // MARK: 局部视图

    /// 段落正文。`runs` 为空表示一行空行（源码里的空 div 变成了 `<br/>`），
    /// 用一个空格撑出行高，不至于塌成 0。
    private func text(_ runs: [NoteRun], font: Font) -> some View {
        Text(attributed(runs, base: font))
            .lineSpacing(DS.Space.xs)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func imageView(_ fileId: String) -> some View {
        if let data = images[fileId], let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                // 按宽度等比缩放：容器更窄就跟着缩，比原图宽也不会被放大
                .frame(maxWidth: image.size.width, alignment: .leading)
        } else {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "photo")
                    .font(NoteFont.body)
                    .foregroundStyle(DS.Status.idle)
                Text("图片未下载")
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.m))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m)
                    .stroke(DS.Palette.stroke, lineWidth: DS.Optical.hairline)
            )
        }
    }

    // MARK: 行内样式 → AttributedString

    private func attributed(_ runs: [NoteRun], base: Font) -> AttributedString {
        guard !runs.isEmpty else { return AttributedString(" ") }

        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)

            var font = run.code ? NoteFont.code : base
            if run.bold { font = font.bold() }
            if run.italic { font = font.italic() }
            piece.font = font

            if run.underline { piece.underlineStyle = .single }
            if run.strike { piece.strikethroughStyle = .single }
            if let hex = run.background, let color = highlightColor(hex) {
                piece.backgroundColor = color
            }
            if let link = run.link, let url = URL(string: link) {
                piece.link = url
                piece.foregroundColor = DS.Palette.accent
            }
            out.append(piece)
        }
        return out
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return NoteFont.h1
        case 2: return NoteFont.h2
        default: return NoteFont.h3
        }
    }

    private func textAlignment(_ align: NoteAlign) -> TextAlignment {
        switch align {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ align: NoteAlign) -> Alignment {
        switch align {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// `#RRGGBB`（不含 `#`）→ Color。荧光笔色来自笔记数据，不是设计 token，
    /// 所以只能从十六进制还原，不能用调色板里的语义色。
    private func highlightColor(_ hex: String) -> Color? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
