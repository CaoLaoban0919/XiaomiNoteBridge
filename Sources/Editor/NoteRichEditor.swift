import SwiftUI
import AppKit
import CryptoKit

struct NoteRichEditor: NSViewRepresentable {

    @Binding var html: String

    var isEditable: Bool = true

    var images: [String: Data] = [:]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator

        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false

        textView.importsGraphics = true

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 0

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.apply(html)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {

        context.coordinator.parent = self

        guard let textView = context.coordinator.textView else { return }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        if context.coordinator.appliedHash != Self.contentHash(html: html, images: images) {
            context.coordinator.apply(html)
        }
    }

    static func contentHash(html: String, images: [String: Data]) -> Int {
        var hasher = Hasher()
        hasher.combine(html)
        hasher.combine(images.count)
        for key in images.keys.sorted() {
            hasher.combine(key)
            hasher.combine(images[key]?.count ?? 0)
        }
        return hasher.finalize()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: NoteRichEditor
        weak var textView: NSTextView?

        private(set) var appliedHash: Int?

        init(_ parent: NoteRichEditor) {
            self.parent = parent
        }

        func apply(_ html: String) {
            guard let textView, let storage = textView.textStorage else { return }
            storage.setAttributedString(
                NoteHTMLBridge.attributed(from: html, images: parent.images)
            )
            appliedHash = NoteRichEditor.contentHash(html: html, images: parent.images)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            guard let fragment = NoteHTMLBridge.fragment(
                from: textView.attributedString(),
                images: parent.images
            ) else { return }

            appliedHash = NoteRichEditor.contentHash(html: fragment, images: parent.images)

            guard fragment != parent.html else { return }
            parent.html = fragment
        }
    }
}

final class NoteImageAttachment: NSTextAttachment {

    var fileId: String?

    var extraAttributes: String = ""

    var sourceData: Data?
}

private enum NoteHTMLBridge {

    static let imageMarker = "\u{E000}"

    static func attributed(from html: String, images: [String: Data]) -> NSAttributedString {
        guard !html.isEmpty else {
            return NSAttributedString(string: "")
        }

        let styled = stylingHeadings(html)

        let (prepared, slots) = markingImages(in: styled, images: images)

        guard let data = prepared.data(using: .utf8) else { return NSAttributedString(string: prepared) }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        let parsed = (try? NSAttributedString(data: data, options: options, documentAttributes: nil))
            ?? NSAttributedString(string: prepared)

        return insertingAttachments(into: parsed, slots: slots)
    }

    static func stylingHeadings(_ html: String) -> String {

        let ladder: [(tag: String, size: Int, weight: Int)] = [
            ("h1", 26, 700),
            ("h2", 21, 700),
            ("h3", 18, 600),
            ("h4", 16, 600),
            ("h5", 15, 600),
            ("h6", 14, 600),
        ]

        var out = html
        for item in ladder {
            let plain = "<\(item.tag)>"
            guard out.contains(plain) else { continue }
            out = out.replacingOccurrences(
                of: plain,
                with: "<\(item.tag) style=\"font-size:\(item.size)px;font-weight:\(item.weight)\">")
        }
        return out
    }

    static func markingImages(
        in html: String,
        images: [String: Data]
    ) -> (String, [ImageSlot]) {
        guard html.range(of: "<img", options: [.caseInsensitive]) != nil,
              let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        else { return (html, []) }

        let text = NSMutableString(string: html)
        let found = regex.matches(in: html, range: NSRange(location: 0, length: text.length))
        guard !found.isEmpty else { return (html, []) }

        var replacements: [(NSRange, String)] = []
        var slots: [ImageSlot] = []

        for match in found {
            let tag = text.substring(with: match.range)
            guard let fileId = attribute("fileid", in: tag) else { continue }

            slots.append(
                ImageSlot(
                    fileId: fileId,
                    extraAttributes: extraAttributes(of: tag),
                    data: images[fileId]
                )
            )
            replacements.append((match.range, imageMarker))
        }

        for (range, replacement) in replacements.reversed() {
            text.replaceCharacters(in: range, with: replacement)
        }
        return (text as String, slots)
    }

    static func insertingAttachments(into attributed: NSAttributedString, slots: [ImageSlot]) -> NSAttributedString {
        guard !slots.isEmpty else { return attributed }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        var cursor = 0

        for slot in slots {
            let source = mutable.string as NSString
            guard cursor < source.length else { break }
            let found = source.range(
                of: imageMarker,
                options: [],
                range: NSRange(location: cursor, length: source.length - cursor)
            )
            guard found.location != NSNotFound else { break }

            let inherited = mutable.attributes(at: found.location, effectiveRange: nil)
            let replacement = NSMutableAttributedString(
                attributedString: NSAttributedString(attachment: attachment(for: slot))
            )
            replacement.addAttributes(inherited, range: NSRange(location: 0, length: replacement.length))
            mutable.replaceCharacters(in: found, with: replacement)

            cursor = found.location + replacement.length
        }
        return mutable
    }

    static func attachment(for slot: ImageSlot) -> NSTextAttachment {
        let attachment = NoteImageAttachment()
        attachment.fileId = slot.fileId
        attachment.extraAttributes = slot.extraAttributes
        attachment.sourceData = slot.data

        if let data = slot.data, let image = NSImage(data: data) {
            attachment.image = image
            attachment.bounds = NSRect(origin: .zero, size: displaySize(for: image.size))
        } else {

            attachment.image = placeholderImage()
            attachment.bounds = NSRect(origin: .zero, size: placeholderSize)
        }
        return attachment
    }

    static func displaySize(for size: NSSize) -> NSSize {
        guard size.width > 1, size.height > 1 else { return placeholderSize }
        let scale = min(1, min(420 / size.width, 320 / size.height))
        return NSSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    static let placeholderSize = NSSize(width: 28, height: 22)

    static func placeholderImage() -> NSImage {
        let size = placeholderSize
        return NSImage(size: size, flipped: false) { rect in
            NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

            NSColor.secondaryLabelColor.withAlphaComponent(0.75).setFill()
            let mountain = NSBezierPath()
            mountain.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
            mountain.line(to: NSPoint(x: rect.minX + 11, y: rect.minY + 13))
            mountain.line(to: NSPoint(x: rect.minX + 16, y: rect.minY + 7))
            mountain.line(to: NSPoint(x: rect.minX + 20, y: rect.minY + 12))
            mountain.line(to: NSPoint(x: rect.minX + 24, y: rect.minY + 4))
            mountain.close()
            mountain.fill()

            NSBezierPath(ovalIn: NSRect(x: rect.minX + 18, y: rect.minY + 15, width: 4, height: 4)).fill()
            return true
        }
    }

    static func fragment(from attributed: NSAttributedString, images: [String: Data]) -> String? {
        guard attributed.length > 0 else { return "" }

        let (stripped, slots) = detachingImages(from: attributed, images: images)

        let range = NSRange(location: 0, length: stripped.length)
        guard let data = try? stripped.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
              ),
              let full = String(data: data, encoding: .utf8)
        else { return nil }

        return restoringImages(in: fragment(fromFullDocument: full), slots: slots)
    }

    static func detachingImages(
        from attributed: NSAttributedString,
        images: [String: Data]
    ) -> (NSAttributedString, [String]) {
        let mutable = NSMutableAttributedString(attributedString: attributed)

        var found: [(range: NSRange, attachment: NSTextAttachment)] = []
        mutable.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: mutable.length),
            options: []
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            found.append((range, attachment))
        }
        guard !found.isEmpty else { return (mutable, []) }

        let fingerprints = imageFingerprints(images)
        let slots = found.map { imageHTML(for: $0.attachment, fingerprints: fingerprints) }

        for item in found.reversed() {
            let attributes = mutable.attributes(at: item.range.location, effectiveRange: nil)
            let token = NSMutableAttributedString(string: imageMarker)
            token.addAttributes(attributes, range: NSRange(location: 0, length: token.length))
            token.removeAttribute(.attachment, range: NSRange(location: 0, length: token.length))
            mutable.replaceCharacters(in: item.range, with: token)
        }
        return (mutable, slots)
    }

    static func imageHTML(
        for attachment: NSTextAttachment,
        fingerprints: [SHA256.Digest: String]
    ) -> String {
        if let note = attachment as? NoteImageAttachment, let fileId = note.fileId {
            return imageTag(fileId: fileId, extraAttributes: note.extraAttributes)
        }

        guard let data = attachmentData(attachment) else { return "" }

        if let fileId = fingerprints[SHA256.hash(data: data)] {
            return imageTag(fileId: fileId, extraAttributes: "")
        }

        return "<img src=\"data:\(mimeType(of: data));base64,\(data.base64EncodedString())\"/>"
    }

    static func imageTag(fileId: String, extraAttributes: String) -> String {
        let extra = extraAttributes.isEmpty ? "" : " " + extraAttributes
        return "<img fileid=\"\(fileId)\"\(extra)/>"
    }

    static func attachmentData(_ attachment: NSTextAttachment) -> Data? {
        if let note = attachment as? NoteImageAttachment, let data = note.sourceData, !data.isEmpty {
            return data
        }

        if let data = attachment.fileWrapper?.regularFileContents {
            return data
        }

        return attachment.image?.tiffRepresentation
    }

    static func imageFingerprints(_ images: [String: Data]) -> [SHA256.Digest: String] {
        var map: [SHA256.Digest: String] = [:]
        for (fileId, data) in images {
            let digest = SHA256.hash(data: data)
            if map[digest] == nil { map[digest] = fileId }
        }
        return map
    }

    static func restoringImages(in fragment: String, slots: [String]) -> String {
        guard fragment.contains(imageMarker) else { return fragment }

        var result = fragment
        for html in slots {
            guard let range = result.range(of: imageMarker) else { break }
            result.replaceSubrange(range, with: html)
        }
        return result.replacingOccurrences(of: imageMarker, with: "")
    }

    static func mimeType(of data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return "image/png"
    }

    static func fragment(fromFullDocument full: String) -> String {
        let body = bodyFragment(full)
        return inlining(body, classes: classStyles(full))
    }

    static func bodyFragment(_ full: String) -> String {
        let found = matches("<body[^>]*>([\\s\\S]*)</body>", in: full, options: [.caseInsensitive])
        return found.first.map { $0[1] } ?? full
    }

    static func classStyles(_ full: String) -> [String: String] {
        let css = matches("<style[^>]*>([\\s\\S]*?)</style>", in: full, options: [.caseInsensitive])
            .map { $0[1] }
            .joined(separator: "\n")
        guard !css.isEmpty else { return [:] }

        var map: [String: String] = [:]
        for rule in matches("([^{}]+)\\{([^{}]*)\\}", in: css) {
            let declarations = cleanedDeclarations(rule[2])
            guard !declarations.isEmpty else { continue }

            for className in matches("\\.([A-Za-z0-9_-]+)", in: rule[1]).map({ $0[1] }) {
                map[className] = map[className].map { $0 + "; " + declarations } ?? declarations
            }
        }
        return map
    }

    static func cleanedDeclarations(_ raw: String) -> String {
        raw.split(separator: ";").compactMap { piece -> String? in
            let declaration = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !declaration.isEmpty else { return nil }
            let name = declaration.split(separator: ":", maxSplits: 1)
                .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard !name.hasPrefix("-webkit-"), name != "font-kerning" else { return nil }
            return declaration
        }
        .joined(separator: "; ")
    }

    static func inlining(_ body: String, classes: [String: String]) -> String {
        guard !classes.isEmpty, body.contains("class=") else { return body }
        guard let regex = try? NSRegularExpression(pattern: "<[a-zA-Z][^>]*>") else { return body }

        let text = NSMutableString(string: body)
        let found = regex.matches(in: body, range: NSRange(location: 0, length: text.length))

        for match in found.reversed() {
            let tag = text.substring(with: match.range)
            guard let classValue = attribute("class", in: tag) else { continue }

            let declarations = classValue.split(separator: " ")
                .compactMap { classes[String($0)] }
                .joined(separator: "; ")
            guard !declarations.isEmpty else { continue }

            var patched = tag
            if let inline = attribute("style", in: patched) {
                patched = removingAttribute("style", from: patched)
                patched = settingAttribute("style", to: declarations + "; " + inline, in: patched)
            } else {
                patched = settingAttribute("style", to: declarations, in: patched)
            }
            patched = removingAttribute("class", from: patched)

            text.replaceCharacters(in: match.range, with: patched)
        }
        return text as String
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\s\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range])
    }

    static func removingAttribute(_ name: String, from tag: String) -> String {
        let pattern = "\\s\(name)\\s*=\\s*[\"'][^\"']*[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return tag }
        return regex.stringByReplacingMatches(
            in: tag,
            range: NSRange(location: 0, length: (tag as NSString).length),
            withTemplate: ""
        )
    }

    static func settingAttribute(_ name: String, to value: String, in tag: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "^<[a-zA-Z][a-zA-Z0-9-]*"),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
        else { return tag }

        let text = NSMutableString(string: tag)
        text.insert(" \(name)=\"\(value)\"", at: match.range.location + match.range.length)
        return text as String
    }

    static func extraAttributes(of tag: String) -> String {
        var body = tag
        if let head = body.range(of: "<img", options: [.caseInsensitive, .anchored]) {
            body.removeSubrange(head)
        }
        body = removingAttribute("fileid", from: body)
        while let last = body.last, last == ">" || last == "/" || last.isWhitespace {
            body.removeLast()
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
}

private struct ImageSlot {
    var fileId: String
    var extraAttributes: String

    var data: Data?
}
