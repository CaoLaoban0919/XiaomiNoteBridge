import Foundation

enum MathMarkup {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func node(latex: String, display: Bool) -> String {
        node(latex: latex, display: display, source: display ? "$$\(latex)$$" : "$\(latex)$")
    }

    private static func node(latex: String, display: Bool, source: String) -> String {
        "<span class=\"mn-math\(display ? " mn-math-display" : "")\" data-latex=\"\(Data(latex.utf8).base64EncodedString())\" data-display=\"\(display)\" contenteditable=\"false\">\(escape(source))</span>"
    }

    struct Protected {
        var text: String
        var nodes: [(String, String)]
        func restore(_ html: String) -> String {
            nodes.reduce(html) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        }
    }

    static func protect(_ text: String, chart: (String) -> String?) -> Protected {
        let chars = Array(text)
        let prefix = "MNTOKEN" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "X"
        var nodes: [(String, String)] = []
        var output = ""
        var i = 0
        func escaped(_ at: Int) -> Bool {
            var p = at - 1, count = 0
            while p >= 0 && chars[p] == "\\" { count += 1; p -= 1 }
            return count % 2 == 1
        }
        func has(_ token: String, _ at: Int) -> Bool {
            let t = Array(token)
            return at + t.count <= chars.count && Array(chars[at..<(at + t.count)]) == t
        }
        func append(_ html: String) {
            let key = prefix + String(nodes.count) + "END"
            nodes.append((key, html)); output += key
        }
        while i < chars.count {
            // Fences and inline code are protected before looking for math delimiters.
            let atLineStart = i == 0 || chars[i - 1] == "\n"
            if atLineStart {
                var marker = i
                while marker < chars.count && chars[marker] == " " && marker - i < 4 { marker += 1 }
                if marker - i <= 3 && marker < chars.count && (chars[marker] == "`" || chars[marker] == "~") {
                    let symbol = chars[marker]
                    var end = marker
                    while end < chars.count && chars[end] == symbol { end += 1 }
                    if end - marker >= 3 {
                        let length = end - marker
                        var lineEnd = end
                        while lineEnd < chars.count && chars[lineEnd] != "\n" { lineEnd += 1 }
                        let language = String(chars[end..<lineEnd]).trimmingCharacters(in: .whitespaces)
                        let start = min(lineEnd + 1, chars.count)
                        var scan = start, contentEnd = chars.count, next = chars.count
                        while scan < chars.count {
                            var stop = scan
                            while stop < chars.count && chars[stop] != "\n" { stop += 1 }
                            let line = String(chars[scan..<stop]).trimmingCharacters(in: .whitespaces)
                            if line.count >= length && line.allSatisfy({ $0 == symbol }) { contentEnd = scan; next = stop; break }
                            scan = min(stop + 1, chars.count)
                        }
                        var content = String(chars[start..<contentEnd])
                        if content.last == "\n" { content.removeLast() }
                        if language.lowercased() == "chart", let rendered = chart(content) { append(rendered) }
                        else { append("<pre><code>\(escape(content))</code></pre>") }
                        i = next; continue
                    }
                }
            }
            if chars[i] == "`" && !escaped(i) {
                var end = i
                while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - i
                var p = end, closing: Int?
                while p < chars.count {
                    if chars[p] == "`" {
                        var q = p
                        while q < chars.count && chars[q] == "`" { q += 1 }
                        if q - p == count { closing = p; break }
                        p = q
                    } else { p += 1 }
                }
                if let closing { append("<code>\(escape(String(chars[end..<closing])))</code>"); i = closing + count; continue }
                output += String(chars[i..<end]); i = end; continue
            }
            var consumed = false
            if !escaped(i) {
                let pairs: [(String, String, Bool)] = [("$$", "$$", true), ("\\[", "\\]", true), ("\\(", "\\)", false), ("$", "$", false)]
                for (open, close, display) in pairs where has(open, i) {
                    let single = open == "$"
                    if single && ((i > 0 && chars[i-1] == "$") || has("$$", i)) { continue }
                    let start = i + open.count
                    var p = start, closing: Int?
                    while p + close.count <= chars.count {
                        if single && (chars[p] == "\n" || chars[p] == "\r") { break }
                        if has(close, p) && !escaped(p) {
                            if single && ((p > 0 && chars[p-1] == "$") || has("$$", p)) { p += 1; continue }
                            closing = p; break
                        }
                        p += 1
                    }
                    guard let closing, closing > start else { continue }
                    let latex = String(chars[start..<closing])
                    guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    if single {
                        if chars[start].isWhitespace || chars[closing-1].isWhitespace { continue }
                        if closing + 1 < chars.count && chars[closing+1].isNumber { continue }
                    }
                    let next = closing + close.count
                    append(node(latex: latex, display: display, source: String(chars[i..<next])))
                    i = next; consumed = true; break
                }
            }
            if !consumed { output.append(chars[i]); i += 1 }
        }
        return Protected(text: output, nodes: nodes)
    }
}

enum MarkdownHTML {
    static func render(_ source: String, chart: (String) -> String?) -> String {
        let protected = MathMarkup.protect(source, chart: chart)
        let lines = protected.text.components(separatedBy: "\n")
        var out: [String] = [], paragraph: [String] = []
        var list: [String] = [], listKind = ""
        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>" + inline(paragraph.joined(separator: "\n")) + "</p>"); paragraph = [] }
        }
        func flushList() {
            if !list.isEmpty { out.append("<\(listKind)>" + list.map { "<li>\(inline($0))</li>" }.joined() + "</\(listKind)>"); list = [] }
        }
        func flush() { flushParagraph(); flushList() }
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); i += 1; continue }
            if i + 1 < lines.count, let header = row(line), let divider = row(lines[i+1]), header.count == divider.count, divider.allSatisfy(isDivider) {
                flush()
                var rows: [[String]] = []
                i += 2
                while i < lines.count, let cells = row(lines[i]), cells.count <= header.count, !cells.allSatisfy(isDivider) {
                    rows.append(cells + Array(repeating: "", count: header.count - cells.count)); i += 1
                }
                out.append("<div class=\"mn-table-scroll\"><table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>" + rows.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined() + "</tbody></table></div>")
                continue
            }
            if line == "---" || line == "***" || line == "___" { flush(); out.append("<hr/>"); i += 1; continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if hashes > 0 && hashes <= 6 && line.dropFirst(hashes).first == " " {
                flush(); out.append("<h\(hashes)>\(inline(String(line.dropFirst(hashes+1))))</h\(hashes)>"); i += 1; continue
            }
            if line.hasPrefix("> ") { flush(); out.append("<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>"); i += 1; continue }
            var item: String?, kind = "ul"
            if ["- ", "* ", "+ ", "• "].contains(where: { line.hasPrefix($0) }) { item = String(line.dropFirst(2)) }
            else if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { item = String(line[range.upperBound...]); kind = "ol" }
            if let item {
                flushParagraph(); if listKind != kind { flushList() }; listKind = kind; list.append(item); i += 1; continue
            }
            flushList(); paragraph.append(line); i += 1
        }
        flush()
        // Restore only after Markdown has finished, so formula and code contents never enter that parser.
        return protected.restore(out.joined())
    }

    private static func inline(_ source: String) -> String {
        var html = MathMarkup.escape(source)
        for (pattern, template) in [(#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"), (#"__([^_]+)__"#, "<strong>$1</strong>"), (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, "<em>$1</em>")] {
            if let regex = try? NSRegularExpression(pattern: pattern) { html = regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: template) }
        }
        return html.replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: "\n", with: "<br/>")
    }

    private static func row(_ source: String) -> [String]? {
        // Full-width pipes are recognized only inside a structurally confirmed table.
        let line = source.trimmingCharacters(in: .whitespaces)
        var cells: [String] = [], cell = "", backslashes = 0, separators = 0
        for char in line {
            if (char == "|" || char == "｜") && backslashes % 2 == 0 { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; separators += 1 }
            else { cell.append(char) }
            backslashes = char == "\\" ? backslashes + 1 : 0
        }
        guard separators > 0 else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if line.first == "|" || line.first == "｜" { cells.removeFirst() }
        if (line.last == "|" || line.last == "｜") && backslashes == 0 && cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func isDivider(_ value: String) -> Bool {
        value.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil
    }
}
