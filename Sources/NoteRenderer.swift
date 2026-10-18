import SwiftUI
import AppKit

enum NoteHTML {

    static func parse(_ html: String) -> [NoteBlock] {
        var parser = NoteHTMLParser()
        parser.consume(NoteTokenizer.tokenize(html))
        parser.finish()
        return numbering(parser.blocks)
    }

    static func displayNumbers(_ blocks: [NoteBlock]) -> [Int] {
        numbering(blocks).map { block in
            if case .numbered(_, let number, _) = block { return number }
            return 0
        }
    }

    private static func numbering(_ blocks: [NoteBlock]) -> [NoteBlock] {
        var out = blocks
        var counters: [Int: Int] = [:]

        for index in out.indices {
            guard case .numbered(let indent, _, let runs) = out[index] else {

                counters.removeAll()
                continue
            }

            let number = (counters[indent] ?? 0) + 1
            counters[indent] = number

            for key in counters.keys.filter({ $0 > indent }) {
                counters.removeValue(forKey: key)
            }
            out[index] = .numbered(indent: indent, number: number, runs: runs)
        }
        return out
    }
}

private enum NoteToken {
    case text(String)
    case open(name: String, attrs: [String: String], selfClosing: Bool)
    case close(String)
}

private enum NoteTokenizer {

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

private struct BlockFrame {
    var tag: String
    var align: NoteAlign = .leading
    var indent: Int = 0
    var listKind: ListKind = .none
    var literal: String?
}

private enum ListKind { case none, disc, decimal }

private struct NoteHTMLParser {
    private(set) var blocks: [NoteBlock] = []

    private var runs: [NoteRun] = []
    private var marks: [InlineMark] = []
    private var block: BlockFrame?

    private var listDepth = 0

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

            listDepth += 1

        case "br":
            if block == nil {

                blocks.append(.paragraph(align: .leading, indent: 0, runs: []))
            } else {
                appendText("\n")
            }

        case "hr":
            flushBlock()
            blocks.append(.divider)

        case "img":

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

    private mutating func appendText(_ raw: String) {
        guard !raw.isEmpty else { return }

        let text = NoteHTMLParser.decodeEntities(raw)

        if let current = block, current.tag == "pre" {
            block?.literal = (current.literal ?? "") + text
            return
        }

        if block == nil {

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
        guard !content.isEmpty else { return }

        switch frame.tag {
        case "h1", "h2", "h3":
            blocks.append(.heading(level: Int(frame.tag.dropFirst()) ?? 3, runs: content))

        case "li":
            if frame.listKind == .decimal {

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

private extension NoteHTMLParser {

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

    static func checkbox(_ runs: [NoteRun]) -> (checked: Bool, runs: [NoteRun])? {
        guard let first = runs.first, let head = first.text.first else { return nil }
        guard head == "\u{2611}" || head == "\u{2610}" else { return nil }
        let checked = head == "\u{2611}"

        var rest = String(first.text.dropFirst())
        if rest.hasPrefix(" ") { rest.removeFirst() }

        var out = runs
        if rest.isEmpty {
            out.removeFirst()
        } else {
            out[0].text = rest
        }
        return (checked, out)
    }
}

private extension NoteHTMLParser {

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

private enum NoteFont {
    static let h1 = DS.Fonts.screenTitle
    static let h2 = Font.system(size: 16, weight: .semibold)
    static let h3 = Font.system(size: 14, weight: .semibold)
    static let body = DS.Fonts.body
    static let code = Font.system(size: 12, design: .monospaced)
}

private enum NoteMetric {

    static let markerColumn: CGFloat = 18

    static let quoteBar: CGFloat = DS.Optical.tight
}

struct NoteHTMLView: View {
    let blocks: [NoteBlock]

    let images: [String: Data]

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

    private func highlightColor(_ hex: String) -> Color? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
