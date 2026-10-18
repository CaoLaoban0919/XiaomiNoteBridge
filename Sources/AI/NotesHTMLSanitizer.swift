import Foundation

enum NotesHTMLSanitizer {

    static func sanitize(_ html: String) -> String {
        sanitizeWithReport(html).html
    }

    static func sanitizeWithReport(_ html: String) -> (html: String, fixes: [String]) {
        var stats = Stats()
        let lex = tokenize(html)
        stats.unterminatedTags = lex.unterminatedTags
        stats.comments = lex.comments

        var body: [String] = []
        var stack: [String] = []
        var unwrappedDepth: [String: Int] = [:]
        var ignoredDepth: [String: Int] = [:]
        var skipping: (name: String, depth: Int)?

        func closeTop() {
            guard let top = stack.popLast() else { return }
            body.append("</\(top)>")
        }

        func unwrapContainer(named name: String) {
            stats.unwrapped[name, default: 0] += 1
        }

        func emitImagePlaceholder() {
            let text = "[图片已移除：备忘录不支持内嵌图片]"
            if let top = stack.last, inlineTextParents.contains(top) {
                body.append(text)
            } else {
                body.append("<p>\(text)</p>")
            }
        }

        for token in lex.tokens {

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

                if stack.isEmpty, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                body.append(normalizeText(raw, stats: &stats))

            case .comment:

                stats.comments += 1

            case .declaration:

                continue

            case .start(let name, let attrs, let selfClosing):

                if removedTags.contains(name) {
                    stats.removed[name, default: 0] += 1

                    if !voidTags.contains(name), !selfClosing {
                        skipping = (name: name, depth: 1)
                    }
                    continue
                }

                if name == "img" {
                    let src = attributeValue("src", in: attrs)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let lower = src.lowercased()
                    if lower.hasPrefix("data:") || lower.isEmpty {
                        stats.dataImages += 1
                        emitImagePlaceholder()
                        continue
                    }

                }

                if unwrapTags.contains(name) {
                    unwrapContainer(named: name)

                    _ = sanitizeStyle(attributeValue("style", in: attrs), stats: &stats)
                    if !selfClosing {
                        unwrappedDepth[name, default: 0] += 1
                    }
                    continue
                }

                if !allowedTags.contains(name) {
                    stats.unknownTags += 1
                    if !selfClosing {
                        ignoredDepth[name, default: 0] += 1
                    }
                    continue
                }

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

                var attributeText = ""
                if let style = sanitizeStyle(attributeValue("style", in: attrs), stats: &stats) {
                    attributeText += " style=\"\(escapeAttributeValue(style))\""
                }
                for attr in attrs {
                    switch attr.name {
                    case "style":
                        break
                    case "href" where name == "a":
                        let value = attr.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = value.lowercased()

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

                        stats.droppedAttributes += 1
                    }
                }

                if voidTags.contains(name) {
                    if !selfClosing {
                        stats.voidFixed += 1
                    }
                    body.append("<\(name)\(attributeText)/>")
                    continue
                }

                body.append("<\(name)\(attributeText)>")
                if selfClosing {

                    body.append("</\(name)>")
                } else {
                    stack.append(name)
                }

            case .end(let name):

                if removedTags.contains(name) {
                    continue
                }

                if let depth = unwrappedDepth[name], depth > 0 {
                    unwrappedDepth[name] = depth - 1
                    continue
                }
                if let depth = ignoredDepth[name], depth > 0 {
                    ignoredDepth[name] = depth - 1
                    continue
                }

                if voidTags.contains(name) {
                    stats.strayEndTags += 1
                    continue
                }
                if let index = stack.lastIndex(of: name) {

                    while stack.count - 1 > index {
                        closeTop()
                        stats.implicitClosed += 1
                    }
                    closeTop()
                } else {

                    stats.strayEndTags += 1
                }
            }
        }

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

    private static let removedTags: Set<String> = [
        "script", "style", "iframe", "object", "embed", "form", "input", "button",
        "link", "meta", "svg", "head", "noscript", "frame", "frameset", "applet",
        "base", "template", "select", "textarea", "option", "video", "audio", "canvas",
    ]

    private static let voidTags: Set<String> = [
        "br", "hr", "img", "input", "link", "meta", "area", "base", "col",
        "embed", "param", "source", "track", "wbr",
    ]

    private static let unwrapTags: Set<String> = [
        "div", "section", "article", "main", "header", "footer", "nav", "aside",
        "html", "body", "figure", "figcaption", "details", "summary",
    ]

    private static let allowedTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "blockquote", "pre",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
        "br", "hr", "img",
        "b", "strong", "i", "em", "u", "s", "strike", "del", "ins", "sub", "sup",
        "a", "span", "code",
    ]

    private static let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
        "blockquote", "pre", "hr",
    ]

    private static let inlineTextParents: Set<String> = [
        "p", "li", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "span", "a", "b", "strong", "i", "em",
        "u", "s", "del", "ins", "code",
    ]

    private static let allowedStyleProperties: Set<String> = [
        "font-weight", "font-style", "text-decoration", "text-align", "color",
    ]

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

    private static let namedColors: Set<String> = [
        "black", "white", "red", "green", "blue", "yellow", "orange", "purple",
        "gray", "grey", "brown", "pink", "cyan", "magenta", "navy", "teal",
        "olive", "lime", "maroon", "silver", "gold", "darkgray", "darkgrey",
        "lightgray", "lightgrey", "darkred", "darkgreen", "darkblue", "transparent",
    ]

    private static let safeNamedEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

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

    private struct Attribute {
        let name: String
        let value: String
    }

    private enum Token {
        case text(String)
        case start(String, [Attribute], Bool)
        case end(String)
        case comment(String)
        case declaration(String)
    }

    private struct LexResult {
        var tokens: [Token] = []
        var unterminatedTags = 0
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

            if i + 1 < count, chars[i + 1] == "/" {
                var j = i + 2
                var name = ""
                while j < count, isNameCharacter(chars[j]) {
                    name.append(chars[j])
                    j += 1
                }

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

            text.append("<")
            i += 1
        }

        flushText()
        return result
    }

    private static func normalizeText(_ raw: String, stats: inout Stats) -> String {
        let chars = Array(raw)
        var result = ""
        var i = 0

        while i < chars.count {
            let char = chars[i]

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

                    result += "&amp;\(name);"
                    stats.entities += 1
                }
            default:
                if let mapped = namedEntities[name] {
                    result += mapped
                    stats.entities += 1
                } else {

                    result += "&amp;\(name);"
                    stats.entities += 1
                }
            }
            i = j + 1
        }

        return result
    }

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

private extension NotesHTMLSanitizer {

    static func isNameStart(_ char: Character) -> Bool {
        char.isLetter
    }

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
