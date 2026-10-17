import Foundation

// 把 AI 生成的 HTML 收拾成「备忘录能安全接收」的形态。
//
// 为什么需要这一层：
//   AI 写回来的是**浏览器口径的 HTML**，而 `NotesImporter.setBody` 走的是
//   AppleScript 的 `body` 属性，最终由「备忘录」自己那套富文本引擎解析。
//   那套引擎的容忍度远低于浏览器：不认 `class`、不认 data URI、不认 flex/grid、
//   某些标签会让**整条写入失败**（不是丢样式，是这一条笔记根本写不进去）。
//   所以在写入之前必须做一次"降级"，宁可丢样式，也不能丢内容或写失败。
//
// 为什么手写 tokenizer 而不用正则、不用 `XMLParser`：
//   1. 正则处理标签必须知道嵌套层次。`<div><div></div></div>` 用
//      `<div>(.*?)</div>` 去替换必然错配；要写对就得递归/回溯，那已经不是正则了。
//      而且属性里可能出现 `>`（`style="content:'>'"`），正则连边界都切不准。
//   2. `XMLParser` 要求**严格 XML**：属性必须带引号、`<br>` 必须写成 `<br/>`、
//      `&nbsp;` 是未定义实体会直接报错。AI 生成的片段恰恰处处不严格，
//      拿它做词法分析等于把「能修的输入」判成「解析失败」。
//   3. 所以这里只做**词法**（扫描 `<` 到 `>`，区分开始/结束/自闭合/注释/声明），
//      语法层面的错误用"标签栈 + 尽力补闭合"处理。够用，且永远不会抛错。
//
// 输出形态：单个 `<div>` 根节点。备忘录接受"一个根"，多个并列的顶层块
// 在个别版本上会被吞掉后面的内容，包一层最稳。

enum NotesHTMLSanitizer {

    // MARK: - 对外接口

    /// 把任意 HTML 片段规范化为「备忘录能安全接收」的形态。
    ///
    /// 不抛错、不做网络/磁盘访问，纯字符串变换，可任意次调用。
    /// - Parameter html: 可能是完整文档、片段、甚至纯文本。
    /// - Returns: 一定以 `<div>` 开头、`</div>` 结尾的 HTML；空输入返回 `<div></div>`。
    static func sanitize(_ html: String) -> String {
        sanitizeWithReport(html).html
    }

    /// 一次性诊断：返回规范化后的 HTML，以及这次实际做了哪些改动。
    ///
    /// `fixes` 里的每一条都是可以直接显示给用户的中文短句（带数量），
    /// 界面据此提示「已自动修正 N 处」。没有改动时返回空数组。
    static func sanitizeWithReport(_ html: String) -> (html: String, fixes: [String]) {
        var stats = Stats()
        let lex = tokenize(html)
        stats.unterminatedTags = lex.unterminatedTags
        stats.comments = lex.comments

        var body: [String] = []          // 已产出的片段
        var stack: [String] = []         // 已输出、仍未闭合的标签
        var unwrappedDepth: [String: Int] = [:]   // 被"解包"的容器，其结束标签要吞掉
        var ignoredDepth: [String: Int] = [:]     // 被判定为不支持的标签，同理
        var skipping: (name: String, depth: Int)? // 正在整段删除的危险标签

        // 关闭栈顶并写出结束标签。
        func closeTop() {
            guard let top = stack.popLast() else { return }
            body.append("</\(top)>")
        }

        // 去掉标签名后，内容仍然要留在原位置，否则"解包"就变成"删除"了。
        func unwrapContainer(named name: String) {
            stats.unwrapped[name, default: 0] += 1
        }

        // 图片占位：如果当前位置在一个能放文字的容器里就直接写文字，
        // 否则补一个 `<p>`——备忘录对"裸文字直接挂在根 div 下"的处理不一致，
        // 能包一层就包一层。
        func emitImagePlaceholder() {
            let text = "[图片已移除：备忘录不支持内嵌图片]"
            if let top = stack.last, inlineTextParents.contains(top) {
                body.append(text)
            } else {
                body.append("<p>\(text)</p>")
            }
        }

        for token in lex.tokens {
            // 正在删除某个危险标签（连同内容）：只关心同名标签的嵌套深度。
            // 内容里的 `<div>`、`</p>` 一律不参与结构判断，否则会把后面的正文搅乱。
            if let current = skipping {
                switch token {
                case .start(let name, _, let selfClosing):
                    if name == current.name, !selfClosing {
                        skipping = (name: current.name, depth: current.depth + 1)
                    }
                case .end(let name):
                    if name == current.name {
                        let next = current.depth - 1
                        skipping = next > 0 ? (name: current.name, depth: next) : nil
                    }
                default:
                    break
                }
                continue
            }

            switch token {
            case .text(let raw):
                // 根节点之外的纯空白没有意义，留着只会让备忘录多出空行。
                if stack.isEmpty, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                body.append(normalizeText(raw, stats: &stats))

            case .comment:
                // 注释会被备忘录原样吞进正文，直接丢掉。
                stats.comments += 1

            case .declaration:
                // `<!doctype>`、`<?xml ...?>` 对正文没有意义。
                continue

            case .start(let name, let attrs, let selfClosing):
                // 1) 危险标签：连同内容一起删。
                if removedTags.contains(name) {
                    stats.removed[name, default: 0] += 1
                    // `input`/`link`/`meta` 是空元素，后面没有"内容"可删；
                    // 若也进删除模式，会一直吃到下一个 `</input>`（永远等不到），
                    // 把整篇正文吞掉。这类必须"只删标签本身"。
                    if !voidTags.contains(name), !selfClosing {
                        skipping = (name: name, depth: 1)
                    }
                    continue
                }

                // 2) 内嵌图片：整条删掉，插一行占位文字。
                //
                // 为什么必须整条删：`<img src="data:image/png;base64,...">` 的数据量
                // 往往几十 KB 到几 MB，AppleScript 的 `body` 塞进去后，备忘录的
                // 富文本解析器会把整个属性当成无法识别的 URL —— 实测结果是**整条写入失败**
                // （不是图片变成裂图，是这条笔记的正文全部没写进去）。
                // 所以宁可掉图，也必须把 data URI 抹掉，并显式告诉用户图去哪了。
                if name == "img" {
                    let src = attributeValue("src", in: attrs)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let lower = src.lowercased()
                    if lower.hasPrefix("data:") || lower.isEmpty {
                        stats.dataImages += 1
                        emitImagePlaceholder()
                        continue
                    }
                    // 普通 http/file 图片：备忘录可能自行下载，保留 src/alt 由它决定。
                }

                // 3) 无语义容器：拆掉标签、保留内容。
                if unwrapTags.contains(name) {
                    unwrapContainer(named: name)
                    // 容器自身的样式也要过一遍：即使标签被拆掉，
                    // `style="display:flex"` 依然要被统计为「已丢弃的布局样式」，
                    // 否则界面上会出现"说修了 N 处、但 N 对不上"的困惑。
                    _ = sanitizeStyle(attributeValue("style", in: attrs), stats: &stats)
                    if !selfClosing {
                        unwrappedDepth[name, default: 0] += 1
                    }
                    continue
                }

                // 4) 白名单之外的标签：拆标签留内容。
                //    这里刻意选择"留内容"而不是"整段删"——AI 可能用到 `<mark>`、
                //    `<figure>` 这类备忘录不认但内容有价值的标签，删内容是不可接受的损失。
                if !allowedTags.contains(name) {
                    stats.unknownTags += 1
                    if !selfClosing {
                        ignoredDepth[name, default: 0] += 1
                    }
                    continue
                }

                // 5) 结构修正：块级标签出现时，把不该还开着的同类标签收掉。
                //    典型来源是 AI 漏写 `</p>` / `</li>`，浏览器能自动纠正，
                //    备忘录不会，必须由我们先修正，否则整段会被当成一个段落。
                if blockTags.contains(name), stack.last == "p" {
                    closeTop()
                    stats.implicitClosed += 1
                }
                if name == "li", stack.last == "li" {
                    closeTop()
                    stats.implicitClosed += 1
                }
                if (name == "td" || name == "th"), stack.last == "td" || stack.last == "th" {
                    closeTop()
                    stats.implicitClosed += 1
                }
                if name == "tr", stack.last == "tr" {
                    closeTop()
                    stats.implicitClosed += 1
                }

                // 6) 属性白名单 + 样式白名单。
                var attributeText = ""
                if let style = sanitizeStyle(attributeValue("style", in: attrs), stats: &stats) {
                    attributeText += " style=\"\(escapeAttributeValue(style))\""
                }
                for attr in attrs {
                    switch attr.name {
                    case "style":
                        break // 已经处理过
                    case "href" where name == "a":
                        let value = attr.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = value.lowercased()
                        // javascript: / data: 在备忘录里没有意义，而且可能让解析器罢工。
                        if value.isEmpty || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") {
                            stats.droppedAttributes += 1
                        } else {
                            attributeText += " href=\"\(escapeAttributeValue(value))\""
                        }
                    case "src" where name == "img":
                        attributeText += " src=\"\(escapeAttributeValue(attr.value))\""
                    case "alt" where name == "img":
                        attributeText += " alt=\"\(escapeAttributeValue(attr.value))\""
                    case "colspan", "rowspan":
                        // 表格合并单元格是备忘录支持的，丢了会让表格错位。
                        if (name == "td" || name == "th"),
                           Int(attr.value.trimmingCharacters(in: .whitespaces)) != nil {
                            attributeText += " \(attr.name)=\"\(escapeAttributeValue(attr.value))\""
                        } else {
                            stats.droppedAttributes += 1
                        }
                    case "start" where name == "ol":
                        if Int(attr.value.trimmingCharacters(in: .whitespaces)) != nil {
                            attributeText += " start=\"\(escapeAttributeValue(attr.value))\""
                        } else {
                            stats.droppedAttributes += 1
                        }
                    default:
                        // class / id / data-* / 事件属性……备忘录一个都不认。
                        stats.droppedAttributes += 1
                    }
                }

                // 7) 空元素写成自闭合；`<br>` → `<br/>` 是备忘录最稳的写法。
                if voidTags.contains(name) {
                    if !selfClosing {
                        stats.voidFixed += 1
                    }
                    body.append("<\(name)\(attributeText)/>")
                    continue
                }

                body.append("<\(name)\(attributeText)>")
                if selfClosing {
                    // `<p/>` 这种写法少见但 AI 会吐；当成空段落，别往栈里塞。
                    body.append("</\(name)>")
                } else {
                    stack.append(name)
                }

            case .end(let name):
                // 危险标签的结束标签：内容已经整段删了，这里什么都不用做。
                if removedTags.contains(name) {
                    continue
                }
                // 被解包/被忽略的标签，结束标签也要按深度吞掉，否则会被误判成"多余结束标签"。
                if let depth = unwrappedDepth[name], depth > 0 {
                    unwrappedDepth[name] = depth - 1
                    continue
                }
                if let depth = ignoredDepth[name], depth > 0 {
                    ignoredDepth[name] = depth - 1
                    continue
                }
                // `</br>` / `</img>`：空元素本就没有结束标签，忽略。
                if voidTags.contains(name) {
                    stats.strayEndTags += 1
                    continue
                }
                if let index = stack.lastIndex(of: name) {
                    // 结束标签之前还开着的标签都属于嵌套错误（如 `<b><i></b>`），
                    // 一并补闭合，保证输出结构合法。
                    while stack.count - 1 > index {
                        closeTop()
                        stats.implicitClosed += 1
                    }
                    closeTop()
                } else {
                    // 找不到对应的开始标签：孤立的 `</div>` 之类，直接丢掉。
                    stats.strayEndTags += 1
                }
            }
        }

        // 8) 收尾：仍开着的标签一律补闭合。
        //    备忘录不像浏览器那样能猜出段落边界，未闭合的 `<p>` 会让后面所有内容并进同一段。
        while !stack.isEmpty {
            closeTop()
            stats.autoClosed += 1
        }

        if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stats.emptyInput = true
        }

        let inner = body.joined()
        let result = inner.isEmpty ? "<div></div>" : "<div>\(inner)</div>"
        return (result, makeFixes(stats))
    }

    // MARK: - 标签 / 属性 / 样式白名单

    /// 必须连内容一起删的标签。
    ///
    /// 分三类：
    /// - 可执行/可注入：`script`、`iframe`、`object`、`embed`、`svg`
    /// - 备忘录解析器直接不认、且会让写入失败：`style`、`link`、`meta`、`head`
    /// - 交互控件在备忘录里没有对应物，留着只会变成一堆裸文字：`form`、`input`、`button`
    private static let removedTags: Set<String> = [
        "script", "style", "iframe", "object", "embed", "form", "input", "button",
        "link", "meta", "svg", "head", "noscript", "frame", "frameset", "applet",
        "base", "template", "select", "textarea", "option", "video", "audio", "canvas",
    ]

    /// 空元素：没有内容，也不需要结束标签。
    private static let voidTags: Set<String> = [
        "br", "hr", "img", "input", "link", "meta", "area", "base", "col",
        "embed", "param", "source", "track", "wbr",
    ]

    /// 拆掉标签、保留内容的容器。
    /// 备忘录只认段落级的 `p`/`h1-h6`/`ul`/`ol`/`table`，`div` 套 `div` 会让它排版崩掉。
    private static let unwrapTags: Set<String> = [
        "div", "section", "article", "main", "header", "footer", "nav", "aside",
        "html", "body", "figure", "figcaption", "details", "summary",
    ]

    /// 输出时保留的标签。
    private static let allowedTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "blockquote", "pre",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
        "br", "hr", "img",
        "b", "strong", "i", "em", "u", "s", "strike", "del", "ins", "sub", "sup",
        "a", "span", "code",
    ]

    /// 块级标签：出现时说明上一个段落该结束了。
    private static let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
        "blockquote", "pre", "hr",
    ]

    /// 可以直接承载文字的容器：图片占位符落在这些容器里时不用再包 `<p>`。
    private static let inlineTextParents: Set<String> = [
        "p", "li", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "span", "a", "b", "strong", "i", "em",
        "u", "s", "del", "ins", "code",
    ]

    /// 样式白名单：这五个属性在备忘录里有确定对应的富文本效果。
    private static let allowedStyleProperties: Set<String> = [
        "font-weight", "font-style", "text-decoration", "text-align", "color",
    ]

    /// 布局相关属性：备忘录不支持，留着会让整段排版崩掉（不只是这条样式失效）。
    private static let layoutStyleProperties: Set<String> = [
        "position", "display", "float", "clear", "flex", "flex-direction",
        "flex-wrap", "flex-flow", "flex-grow", "flex-shrink", "flex-basis",
        "justify-content", "align-items", "align-content", "align-self",
        "grid", "grid-template", "grid-template-columns", "grid-template-rows",
        "grid-column", "grid-row", "gap", "row-gap", "column-gap",
        "width", "height", "min-width", "max-width", "min-height", "max-height",
        "top", "right", "bottom", "left", "z-index", "overflow", "overflow-x",
        "overflow-y", "transform", "transition", "animation", "box-shadow",
        "opacity", "visibility", "float", "clip", "clip-path", "object-fit",
    ]

    /// 常见命名色。备忘录对十六进制最稳，但常见名称它也能认；
    /// 认不出来的名称色会被丢掉（否则可能整条 style 解析失败）。
    private static let namedColors: Set<String> = [
        "black", "white", "red", "green", "blue", "yellow", "orange", "purple",
        "gray", "grey", "brown", "pink", "cyan", "magenta", "navy", "teal",
        "olive", "lime", "maroon", "silver", "gold", "darkgray", "darkgrey",
        "lightgray", "lightgrey", "darkred", "darkgreen", "darkblue", "transparent",
    ]

    /// 备忘录能安全识别的实体：这几个留着原样，其余命名实体转成 Unicode。
    private static let safeNamedEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// 命名实体 → Unicode。
    ///
    /// 不全，只收中文排版和 AI 输出里常见的那些。查不到的走"转义 & 保留原文"，
    /// 视觉上不会丢字（只是显示成字面 `&foo;`），比让备忘录解析失败划算。
    private static let namedEntities: [String: String] = [
        "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "middot": "·",
        "bull": "•", "hellip": "…", "mdash": "—", "ndash": "–", "minus": "−",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "sbquo": "‚",
        "bdquo": "„", "laquo": "«", "raquo": "»", "prime": "′", "Prime": "″",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "lArr": "⇐", "rArr": "⇒", "hArr": "⇔", "forall": "∀", "exist": "∃",
        "empty": "∅", "nabla": "∇", "isin": "∈", "notin": "∉", "ni": "∋",
        "prod": "∏", "sum": "∑", "lowast": "∗", "radic": "√",
        "infin": "∞", "ang": "∠", "and": "∧", "or": "∨", "cap": "∩", "cup": "∪",
        "int": "∫", "there4": "∴", "sim": "∼", "cong": "≅", "asymp": "≈",
        "ne": "≠", "equiv": "≡", "le": "≤", "ge": "≥", "sub": "⊂", "sup": "⊃",
        "nsub": "⊄", "sube": "⊆", "supe": "⊇", "oplus": "⊕", "otimes": "⊗",
        "perp": "⊥", "sdot": "⋅", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊",
        "rfloor": "⌋", "lang": "〈", "rang": "〉", "loz": "◊", "spades": "♠",
        "clubs": "♣", "hearts": "♥", "diams": "♦", "frac14": "¼",
        "frac12": "½", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
        "iexcl": "¡", "iquest": "¿", "cent": "¢", "pound": "£", "yen": "¥",
        "euro": "€", "curren": "¤", "brvbar": "¦", "uml": "¨", "ordf": "ª",
        "not": "¬", "shy": "­", "macr": "¯", "acute": "´", "micro": "µ",
        "cedil": "¸", "ordm": "º", "szlig": "ß", "agrave": "à", "aacute": "á",
        "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ",
        "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "eth": "ð",
        "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ",
        "ouml": "ö", "oslash": "ø", "ugrave": "ù", "uacute": "ú", "ucirc": "û",
        "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ",
    ]

    // MARK: - 词法：轻量 tokenizer

    /// 一个属性。值保持原始文本（不在这里解实体），后面按用途分别处理。
    private struct Attribute {
        let name: String
        let value: String
    }

    /// 词法单元。
    private enum Token {
        case text(String)
        case start(String, [Attribute], Bool)   // 标签名、属性、是否自闭合
        case end(String)
        case comment(String)
        case declaration(String)                 // `<!doctype>` / `<?xml?>`
    }

    /// 词法分析结果。顺带记录"不严格"的地方，供 fixes 汇报。
    private struct LexResult {
        var tokens: [Token] = []
        var unterminatedTags = 0   // 扫到输入结尾还没遇到 `>` 的标签
        var comments = 0
    }

    private static func tokenize(_ source: String) -> LexResult {
        let chars = Array(source)
        let count = chars.count
        var result = LexResult()
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            result.tokens.append(.text(text))
            text = ""
        }

        var i = 0
        while i < count {
            let char = chars[i]
            guard char == "<" else {
                text.append(char)
                i += 1
                continue
            }

            // 注释：`<!-- ... -->`。未闭合就吞到结尾——反正注释内容也没用。
            if i + 3 < count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                flushText()
                var j = i + 4
                var end = -1
                while j + 2 < count {
                    if chars[j] == "-", chars[j + 1] == "-", chars[j + 2] == ">" {
                        end = j + 3
                        break
                    }
                    j += 1
                }
                if end < 0 {
                    result.tokens.append(.comment(String(chars[i..<count])))
                    i = count
                } else {
                    result.tokens.append(.comment(String(chars[(i + 4)..<(end - 3)])))
                    i = end
                }
                continue
            }

            // `<!doctype html>` / `<?xml ... ?>`
            if i + 1 < count, chars[i + 1] == "!" || chars[i + 1] == "?" {
                flushText()
                if let close = indexOf(">", in: chars, from: i + 2) {
                    result.tokens.append(.declaration(String(chars[i...close])))
                    i = close + 1
                } else {
                    result.tokens.append(.declaration(String(chars[i..<count])))
                    i = count
                    result.unterminatedTags += 1
                }
                continue
            }

            // 结束标签
            if i + 1 < count, chars[i + 1] == "/" {
                var j = i + 2
                var name = ""
                while j < count, isNameCharacter(chars[j]) {
                    name.append(chars[j])
                    j += 1
                }
                // `</>` 这类残缺写法当普通文本，别让它吞掉后续内容。
                guard !name.isEmpty else {
                    text.append("<")
                    i += 1
                    continue
                }
                flushText()
                if let close = indexOf(">", in: chars, from: j) {
                    result.tokens.append(.end(name.lowercased()))
                    i = close + 1
                } else {
                    result.tokens.append(.end(name.lowercased()))
                    i = count
                    result.unterminatedTags += 1
                }
                continue
            }

            // 开始标签
            if i + 1 < count, isNameStart(chars[i + 1]) {
                flushText()
                var j = i + 1
                var name = ""
                while j < count, isNameCharacter(chars[j]) {
                    name.append(chars[j])
                    j += 1
                }

                var attributes: [Attribute] = []
                var selfClosing = false
                var closed = false

                while j < count {
                    while j < count, chars[j].isWhitespace { j += 1 }
                    guard j < count else { break }

                    if chars[j] == ">" {
                        j += 1
                        closed = true
                        break
                    }
                    if chars[j] == "/" {
                        if j + 1 < count, chars[j + 1] == ">" {
                            selfClosing = true
                            j += 2
                            closed = true
                            break
                        }
                        j += 1
                        continue
                    }

                    // 属性名：遇到空白、`=`、`>`、`/` 结束。
                    var attributeName = ""
                    while j < count,
                          !chars[j].isWhitespace,
                          chars[j] != "=", chars[j] != ">", chars[j] != "/" {
                        attributeName.append(chars[j])
                        j += 1
                    }
                    guard !attributeName.isEmpty else {
                        j += 1
                        continue
                    }

                    var attributeValue = ""
                    var lookahead = j
                    while lookahead < count, chars[lookahead].isWhitespace { lookahead += 1 }
                    if lookahead < count, chars[lookahead] == "=" {
                        j = lookahead + 1
                        while j < count, chars[j].isWhitespace { j += 1 }
                        // 引号内的 `>` 属于属性值（style 里偶尔出现），不能当标签结束。
                        if j < count, chars[j] == "\"" || chars[j] == "'" {
                            let quote = chars[j]
                            j += 1
                            while j < count, chars[j] != quote {
                                attributeValue.append(chars[j])
                                j += 1
                            }
                            if j < count { j += 1 }
                        } else {
                            while j < count, !chars[j].isWhitespace, chars[j] != ">" {
                                attributeValue.append(chars[j])
                                j += 1
                            }
                        }
                    }
                    attributes.append(Attribute(name: attributeName.lowercased(), value: attributeValue))
                }

                if !closed { result.unterminatedTags += 1 }
                result.tokens.append(.start(name.lowercased(), attributes, selfClosing))
                i = max(j, i + 1)
                continue
            }

            // 不是标签起点的 `<`（例如 `1 < 2`），按普通文本处理。
            text.append("<")
            i += 1
        }

        flushText()
        return result
    }

    // MARK: - 文本与实体

    /// 文本节点的实体规范化。
    ///
    /// 规则：
    /// - `&nbsp;` 原样保留（备忘录认）；
    /// - `&amp;`/`&lt;`/`&gt;`/`&quot;`/`&apos;` 原样保留（安全且必要）；
    /// - 数字实体原样保留（`&#169;` 备忘录认）；
    /// - 其余命名实体转成对应 Unicode 字符（`&copy;` → `©`）；
    /// - 认不出来的实体把 `&` 转义，保持字面显示。
    private static func normalizeText(_ raw: String, stats: inout Stats) -> String {
        let chars = Array(raw)
        var result = ""
        var i = 0

        while i < chars.count {
            let char = chars[i]

            // 文本里出现的裸 `<`（没构成标签）必须转义，否则输出仍然是坏 HTML。
            if char == "<" {
                result += "&lt;"
                stats.entities += 1
                i += 1
                continue
            }
            guard char == "&" else {
                result.append(char)
                i += 1
                continue
            }

            var j = i + 1
            var name = ""
            while j < chars.count,
                  j - i <= 12,
                  chars[j] != ";",
                  !chars[j].isWhitespace,
                  chars[j] != "&",
                  chars[j] != "<" {
                name.append(chars[j])
                j += 1
            }

            guard j < chars.count, chars[j] == ";", !name.isEmpty else {
                // 不是实体，就是一个裸 `&`。
                result += "&amp;"
                stats.entities += 1
                i += 1
                continue
            }

            switch name {
            case "nbsp":
                result += "&nbsp;"
            case _ where safeNamedEntities.contains(name):
                result += "&\(name);"
            case _ where name.hasPrefix("#"):
                if isNumericEntity(name) {
                    result += "&\(name);"
                } else {
                    // 数字实体非法（比如码点越界）：转义 `&`，原文照留。
                    result += "&amp;\(name);"
                    stats.entities += 1
                }
            default:
                if let mapped = namedEntities[name] {
                    result += mapped
                    stats.entities += 1
                } else {
                    // 认不出来的实体：保留原文（只把 `&` 转义），
                    // 显示成字面 `&foo;` 也比让备忘录整段解析失败强。
                    result += "&amp;\(name);"
                    stats.entities += 1
                }
            }
            i = j + 1
        }

        return result
    }

    /// `#123` 或 `#x1F600` 形式，且码点在合法范围内。
    private static func isNumericEntity(_ name: String) -> Bool {
        guard name.hasPrefix("#") else { return false }
        let body = name.dropFirst()
        let digits: Substring
        let radix: Int

        if body.hasPrefix("x") || body.hasPrefix("X") {
            digits = body.dropFirst()
            radix = 16
        } else {
            digits = body
            radix = 10
        }
        guard !digits.isEmpty, let code = Int(digits, radix: radix) else { return false }
        return code > 0 && code <= 0x10FFFF
    }

    // MARK: - 样式

    /// 解析并过滤 `style="..."`。
    ///
    /// 只保留备忘录能落地的五个属性；布局类属性（flex/grid/position/尺寸）
    /// 会**让整段排版崩掉**而不只是"这条样式失效"，所以必须按属性名逐条筛，
    /// 而不是整条 style 保留或整条丢弃。
    private static func sanitizeStyle(_ raw: String?, stats: inout Stats) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var kept: [String] = []
        for declaration in raw.split(separator: ";") {
            let part = String(declaration).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty, let colon = part.firstIndex(of: ":") else { continue }

            let property = String(part[part.startIndex..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = String(part[part.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !property.isEmpty, !value.isEmpty else { continue }

            if isLayoutProperty(property) {
                stats.layoutStyles += 1
                continue
            }
            guard allowedStyleProperties.contains(property) else {
                stats.otherStyles += 1
                continue
            }
            guard let normalized = normalizeStyleValue(property: property, value: value) else {
                stats.otherStyles += 1
                continue
            }
            kept.append("\(property): \(normalized)")
        }

        return kept.isEmpty ? nil : kept.joined(separator: "; ")
    }

    private static func isLayoutProperty(_ property: String) -> Bool {
        if layoutStyleProperties.contains(property) { return true }
        // `margin-*` / `padding-*` / `border-*` / `background-*` 一律算布局噪声。
        for prefix in ["margin", "padding", "border", "background", "inset"] {
            if property == prefix || property.hasPrefix(prefix + "-") { return true }
        }
        return false
    }

    private static func normalizeStyleValue(property: String, value: String) -> String? {
        let lower = value.lowercased()

        switch property {
        case "font-weight":
            if ["normal", "bold", "bolder", "lighter"].contains(lower) { return lower }
            if let weight = Int(lower), (100...900).contains(weight), weight % 100 == 0 {
                return lower
            }
            return nil

        case "font-style":
            return ["normal", "italic", "oblique"].contains(lower) ? lower : nil

        case "text-decoration":
            // 备忘录只认 underline / line-through 这类简单组合。
            let tokens = lower.split(whereSeparator: { $0 == " " }).map(String.init)
            let valid: Set<String> = ["none", "underline", "overline", "line-through"]
            guard !tokens.isEmpty, tokens.allSatisfy({ valid.contains($0) }) else { return nil }
            return tokens.joined(separator: " ")

        case "text-align":
            return ["left", "center", "right", "justify", "start", "end"].contains(lower) ? lower : nil

        case "color":
            return normalizeColor(value)

        default:
            return nil
        }
    }

    /// 颜色统一成 `#RRGGBB` 或保留备忘录认识的名称色。
    /// `rgb()/rgba()` 一律折算成十六进制——备忘录不解析函数式颜色。
    private static func normalizeColor(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("#") {
            let hex = value.dropFirst()
            guard hex.count == 3 || hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else {
                return nil
            }
            return value
        }

        if value.hasPrefix("rgb") {
            guard let open = value.firstIndex(of: "("),
                  let close = value.lastIndex(of: ")"),
                  open < close else { return nil }
            let inside = value[value.index(after: open)..<close]
            let components = inside
                .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == " " })
                .compactMap { Double(String($0)) }
            guard components.count >= 3 else { return nil }

            let red = Int(components[0].rounded())
            let green = Int(components[1].rounded())
            let blue = Int(components[2].rounded())
            guard (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) else {
                return nil
            }
            return String(format: "#%02X%02X%02X", red, green, blue)
        }

        return namedColors.contains(value) ? value : nil
    }

    // MARK: - 属性值转义

    /// 属性值里的 `&` 只转义"不是实体开头"的那些。
    /// 链接常见 `?a=1&amp;b=2`，无脑替换会变成 `&amp;amp;`，把地址写坏。
    private static func escapeAttributeValue(_ raw: String) -> String {
        let chars = Array(raw)
        var result = ""
        var i = 0

        while i < chars.count {
            switch chars[i] {
            case "\"":
                result += "&quot;"
            case "<":
                result += "&lt;"
            case ">":
                result += "&gt;"
            case "&":
                result += startsWithEntity(chars, at: i) ? "&" : "&amp;"
            default:
                result.append(chars[i])
            }
            i += 1
        }

        return result
    }

    private static func startsWithEntity(_ chars: [Character], at index: Int) -> Bool {
        var j = index + 1
        var name = ""
        while j < chars.count,
              j - index <= 12,
              chars[j] != ";",
              !chars[j].isWhitespace {
            name.append(chars[j])
            j += 1
        }
        return j < chars.count && chars[j] == ";" && !name.isEmpty
    }

    // MARK: - 统计与说明文案

    private struct Stats {
        var removed: [String: Int] = [:]
        var unwrapped: [String: Int] = [:]
        var dataImages = 0
        var unknownTags = 0
        var layoutStyles = 0
        var otherStyles = 0
        var droppedAttributes = 0
        var implicitClosed = 0
        var autoClosed = 0
        var strayEndTags = 0
        var voidFixed = 0
        var entities = 0
        var comments = 0
        var unterminatedTags = 0
        var emptyInput = false
    }

    /// 把统计翻译成可以直接显示的中文短句。
    /// 顺序固定，界面逐条展示时不会因为字典顺序而跳动。
    private static func makeFixes(_ stats: Stats) -> [String] {
        var fixes: [String] = []

        if stats.emptyInput {
            fixes.append("输入为空，已输出空容器")
        }

        for name in stats.removed.keys.sorted() {
            let count = stats.removed[name] ?? 0
            fixes.append("移除了 \(count) 个 <\(name)> 标签（连同内容）")
        }
        if stats.dataImages > 0 {
            fixes.append("移除了 \(stats.dataImages) 张内嵌图片（备忘录不支持 data URI），并插入占位文字")
        }
        for name in stats.unwrapped.keys.sorted() {
            let count = stats.unwrapped[name] ?? 0
            fixes.append("去掉了 \(count) 个 <\(name)> 包裹标签（内容保留）")
        }
        if stats.unknownTags > 0 {
            fixes.append("去掉了 \(stats.unknownTags) 个备忘录不支持的标签（内容保留）")
        }
        if stats.layoutStyles > 0 {
            fixes.append("丢弃了 \(stats.layoutStyles) 处布局样式（position/display/flex/尺寸等）")
        }
        if stats.otherStyles > 0 {
            fixes.append("丢弃了 \(stats.otherStyles) 处非白名单样式")
        }
        if stats.droppedAttributes > 0 {
            fixes.append("丢弃了 \(stats.droppedAttributes) 个非白名单属性（class/id/data-* 等）")
        }
        if stats.voidFixed > 0 {
            fixes.append("把 \(stats.voidFixed) 个 <br>/<hr>/<img> 规范为自闭合写法")
        }
        if stats.autoClosed > 0 {
            fixes.append("补闭合了 \(stats.autoClosed) 处未闭合标签")
        }
        if stats.implicitClosed > 0 {
            fixes.append("修正了 \(stats.implicitClosed) 处错误的块级嵌套")
        }
        if stats.strayEndTags > 0 {
            fixes.append("忽略了 \(stats.strayEndTags) 个多余的结束标签")
        }
        if stats.entities > 0 {
            fixes.append("规范化了 \(stats.entities) 处 HTML 实体")
        }
        if stats.comments > 0 {
            fixes.append("去掉了 \(stats.comments) 段 HTML 注释")
        }
        if stats.unterminatedTags > 0 {
            fixes.append("修正了 \(stats.unterminatedTags) 处没写完的标签")
        }

        return fixes
    }
}

// MARK: - 小工具

private extension NotesHTMLSanitizer {
    /// 标签名首字符：必须像字母，否则 `<` 当普通文本（避免把 `1 < 2` 认成标签）。
    static func isNameStart(_ char: Character) -> Bool {
        char.isLetter
    }

    /// 标签名/属性名允许的字符。
    static func isNameCharacter(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "-" || char == "_" || char == ":" || char == "."
    }

    static func indexOf(_ target: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func attributeValue(_ name: String, in attrs: [Attribute]) -> String? {
        attrs.first(where: { $0.name == name })?.value
    }
}
