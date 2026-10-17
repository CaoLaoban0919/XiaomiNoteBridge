import SwiftUI
import AppKit
import CryptoKit

// 笔记正文的原生富文本编辑器：HTML → NSAttributedString → NSTextView → HTML。
//
// 为什么是 NSTextView 而不是继续用 `NoteHTMLView`：
//   - `NoteHTMLView` 把 `[NoteBlock]` 摊成一组只读 SwiftUI 视图，光标、选区、输入法
//     全都没有落点，无法编辑；
//   - NSTextView 自带中文输入法、撤销栈、选区和附件（图片）选中删除，这些都是
//     "能改笔记"的最低要求，自己实现一遍不现实。
//
// 与 `NoteHTMLView` 的分工：这个文件只负责"可编辑"，不负责设计还原。
// 字号/间距沿用小米 HTML 里自带的样式，不强行套 `DS.Fonts`——否则用户编辑后
// 写回的 HTML 会掺进一堆和被编辑前不一致的字号。
//
// ⚠️ 已知限制（刻意不解决，和 `NotesHTMLSanitizer` 的取舍方向一致）：
//   1. 复杂 CSS（flex / grid / position / 伪元素）经 NSAttributedString 往返会丢，
//      只剩字号、颜色、粗斜体、下划线、对齐、列表缩进这几项；
//   2. 表格会退化成制表符分隔的文本行；
//   3. 字体族会被 Cocoa 归一化成 Times / 系统回退字体，中文仍走 PingFang 回退。
//   这些都和备忘录自身的表达能力对齐，不算功能损失。
//
// 图片（第 4 条曾经的坑，现已自己接管）：
//   `NSAttributedString` 的 HTML 读入器会**整条丢弃** `<img fileid="…">`（没有 src），
//   导出时又会把 `data:` 图的 src 写成 `file:///unknown.png`——两头都丢图。
//   所以图片不交给 Cocoa 的 HTML 转换器，而是：
//     入口：把 `<img fileid="x">` 换成一个单字符占位符交给 HTML 解析，
//           解析完在占位符处插入真正的 `NSTextAttachment`（字节存在附件里），
//           这样用户能看见、能选中、能删；
//     出口：把附件换回占位符再导出，最后按附件里的 fileId（或对字节做 SHA256
//           指纹反查 `images`）还原成 `<img fileid="x">`。
//   附件被用户删掉，输出里就没有这个标签——写回时图真的没了，这正是"能删图"。

// MARK: - 编辑器

/// HTML ↔ 富文本的双向桥。
///
/// 用法：把备忘录正文 HTML 绑进来，用户改完读回 `html` 写回接口。
/// `isEditable == false` 时降级成"可选中复制的只读渲染"。
struct NoteRichEditor: NSViewRepresentable {

    /// 双向绑定：进来是初始 HTML，出去是编辑后的 HTML 片段。
    @Binding var html: String

    /// 是否可编辑。只读时仍然可选、可复制。
    var isEditable: Bool = true

    /// 笔记里图片的原始字节，key 是 fileId。
    /// 进入编辑器时用来把 `<img fileid="x">` 换成内联图，让用户看得见、选得中、删得掉。
    var images: [String: Data] = [:]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false          // 外层已有底色，这里再画一层会盖住
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator

        textView.isRichText = true                  // 保留加粗/字号/颜色，不要降级成纯文本
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true                // 只读也要能选、能复制
        textView.drawsBackground = false

        // **允许把图片拖进正文。**
        // NSTextView 默认只在纯文本模式下拒绝图形，但富文本模式下也需要显式打开，
        // 否则拖进来的图会被当成"不支持的类型"直接拒收。
        // 拖入后会变成 `NSTextAttachment` 插在光标处，这正是"往笔记里加图"的动作。
        //
        // 注意：这类新图没有 fileId，导出时只能保留 data URI，
        // 而备忘录本身不支持内嵌图片，所以它不会被写进云端——只留在本地。
        textView.importsGraphics = true

        // 关掉自动替换。中文用户写笔记时，这三个尤其致命：
        //   - 引号替换会把 `"` 变成 `“”`，粘代码/英文引号全毁；
        //   - 破折号替换会把 `--` 变成 `—`；
        //   - 拼写纠正会在中文里乱改英文单词。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // 左右内边距交给外层 SwiftUI padding，这里只留上下呼吸感；
        // `lineFragmentPadding` 默认是 5，不清零的话"零内边距"其实还是缩进 5pt。
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 0

        // 纵向无限长、横向跟随容器：正文自动换行，长文由外层 scroll view 滚动。
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
        // Binding 是结构体里的属性，SwiftUI 每次更新都会造一个新的 self，
        // coordinator 里存的那份必须同步，否则回写会写进上一轮的 binding。
        context.coordinator.parent = self

        guard let textView = context.coordinator.textView else { return }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        // 只有"外部 html 变了"才重设内容。自己改字触发的回写，hash 已经被
        // coordinator 提前更新过，这里会直接跳过——否则每敲一个字光标就跳回开头。
        // 图片字节也算进 hash：图片是异步拉回来的，晚到时旧内容里还没有附件。
        if context.coordinator.appliedHash != Self.contentHash(html: html, images: images) {
            context.coordinator.apply(html)
        }
    }

    /// 内容指纹：HTML + 图片字典的"结构"（key 与字节长度）。
    ///
    /// 刻意不对字节本身做哈希——`updateNSView` 每次敲键都会走一遍，几 MB 的图
    /// 逐字节哈希会把主线程拖住；key 或大小变了就足够说明该重贴内容了。
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

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: NoteRichEditor
        weak var textView: NSTextView?

        /// 上一次写进 textStorage 的 HTML 的哈希。
        ///
        /// 这是防光标重置的关键：`textDidChange` 把内容转成 HTML 回写 binding 后，
        /// SwiftUI 立刻会调 `updateNSView`，此时传进来的 html 就是刚刚回写的那个。
        /// 若这里不认账、无条件 `setAttributedString`，光标与选区会被清掉，
        /// 中文输入法还会因为文本被替换而断掉组合串。
        private(set) var appliedHash: Int?

        init(_ parent: NoteRichEditor) {
            self.parent = parent
        }

        /// 把 HTML 贴进 textStorage，并记下这次写入的哈希。
        func apply(_ html: String) {
            guard let textView, let storage = textView.textStorage else { return }
            storage.setAttributedString(
                NoteHTMLBridge.attributed(from: html, images: parent.images)
            )
            appliedHash = NoteRichEditor.contentHash(html: html, images: parent.images)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            // 转换失败时**不能**回写空串：那等于把用户的笔记清空。
            // 宁可这一轮不同步，也不能丢内容。
            guard let fragment = NoteHTMLBridge.fragment(
                from: textView.attributedString(),
                images: parent.images
            ) else { return }

            // 先更新哈希，再回写 binding：顺序反了的话，binding 触发的那次
            // updateNSView 会看到旧哈希，把刚敲的内容整段重设一遍。
            appliedHash = NoteRichEditor.contentHash(html: fragment, images: parent.images)

            guard fragment != parent.html else { return }
            parent.html = fragment
        }
    }
}

// MARK: - 图片附件

/// 带来源信息的图片附件。
///
/// 原生 `NSTextAttachment` 只记字节，不记"这张图对应笔记里的哪个 fileId"。
/// 往返要靠它：入口塞进来，出口取回去，不必猜。
final class NoteImageAttachment: NSTextAttachment {

    /// 笔记里的图片 id。`nil` 表示这张图不是从笔记里来的（用户新插的）。
    var fileId: String?

    /// 原标签上除 `fileid` 以外的属性，导出时原样带回去（`width`、`style` 等）。
    var extraAttributes: String = ""

    /// 原始字节。`fileWrapper` 也存了一份，这里留一份是为了不依赖 Cocoa 的封装。
    var sourceData: Data?
}

// MARK: - HTML ↔ NSAttributedString

/// 两个方向的转换，以及导出时的"文档 → 片段"整形。
private enum NoteHTMLBridge {

    /// 图片占位符：BMP 私有区的首字符，笔记正文里不可能出现。
    ///
    /// 用一个字符而不是长串，是因为 HTML writer 会给文本段套 `<span>`/`<p>`，
    /// 长串可能被切断；单字符最多被包一层 span，替换后仍是合法 HTML。
    static let imageMarker = "\u{E000}"

    // MARK: 读入

    static func attributed(from html: String, images: [String: Data]) -> NSAttributedString {
        guard !html.isEmpty else {
            return NSAttributedString(string: "")
        }

        // **先补标题字号。**
        // Cocoa 的 HTML 导入器不会套用 h1–h6 的默认字号，只给加粗——
        // 结果是标题和正文一样大，整篇笔记失去层级。这里补上行内字号再解析。
        let styled = stylingHeadings(html)

        // 再把图片标签换成占位符：Cocoa 的读入器认不得 `<img fileid>`，
        // 会连标签一起丢掉；换成纯文本字符就能安全穿过解析。
        let (prepared, slots) = markingImages(in: styled, images: images)

        guard let data = prepared.data(using: .utf8) else { return NSAttributedString(string: prepared) }

        // 刻意**不设 baseURL**：一旦设了，HTML 里的相对 src 会变成可解析的远程地址，
        // 读入过程会真的去下载图片（笔记里常见外链图），既慢又可能卡住主线程。
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        // 解不出来就按纯文本兜底，至少让用户看到内容、能改，而不是白屏。
        let parsed = (try? NSAttributedString(data: data, options: options, documentAttributes: nil))
            ?? NSAttributedString(string: prepared)

        return insertingAttachments(into: parsed, slots: slots)
    }

    /// 给没有自身样式的 `h1`–`h6` 补上行内字号与字重。
    ///
    /// 只处理**裸标签**（`<h1>` 而不是 `<h1 class=…>`）：带属性的可能已经有内联样式，
    /// 硬塞会把原样式覆盖掉。宁可漏补几个，也不擅自改用户已有的格式。
    static func stylingHeadings(_ html: String) -> String {
        // 字号按 macOS 正文 13pt 的比例给，保证 h1 明显大于正文、h6 略大于正文
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

    /// 把每个 `<img …>` 换成占位符，同时按出现顺序记下它的来源信息。
    ///
    /// 没有 `fileid` 的图（外链图、用户自己写的 `<img src>`）不动，交给 Cocoa 处理。
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

            // `images[fileId]` 缺失时**照样**换成占位符：不换的话这个标签会被
            // HTML 读入器整个删掉，等于凭空丢引用。占位符会以灰框形式显示，
            // 导出时再原样还原成 `<img fileid="…">`。
            slots.append(
                ImageSlot(
                    fileId: fileId,
                    extraAttributes: extraAttributes(of: tag),
                    data: images[fileId]
                )
            )
            replacements.append((match.range, imageMarker))
        }

        // 从后往前替换，避免前面的替换把后面的 NSRange 顶偏。
        for (range, replacement) in replacements.reversed() {
            text.replaceCharacters(in: range, with: replacement)
        }
        return (text as String, slots)
    }

    /// 把占位符逐个换成真正的附件。占位符与附件都是 1 个 UTF-16 单元，
    /// 长度不变，所以可以在同一个可变串上边走边换。
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

            // 继承占位符原本的段落/字号属性，图片所在行的对齐、缩进才不会变。
            let inherited = mutable.attributes(at: found.location, effectiveRange: nil)
            let replacement = NSMutableAttributedString(
                attributedString: NSAttributedString(attachment: attachment(for: slot))
            )
            replacement.addAttributes(inherited, range: NSRange(location: 0, length: replacement.length))
            mutable.replaceCharacters(in: found, with: replacement)

            // 附件与占位符等长，但用 `replacement.length` 更稳，免得被 AppKit 归一化。
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
            // 字节没拉回来的图：给个灰框，让用户知道"这里有一张图"，
            // 也保证它能被选中、被删除——只是暂时看不到内容。
            attachment.image = placeholderImage()
            attachment.bounds = NSRect(origin: .zero, size: placeholderSize)
        }
        return attachment
    }

    /// 显示尺寸：等比缩到 420×320 以内。原图字节不受影响，导出仍然是原图。
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

            // 一座小山 + 一个太阳，示意"这里是一张图"。
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

    // MARK: 写出

    /// 富文本 → HTML **片段**。失败返回 nil（调用方据此放弃本轮回写）。
    static func fragment(from attributed: NSAttributedString, images: [String: Data]) -> String? {
        guard attributed.length > 0 else { return "" }

        // 附件先摘掉换成占位符：Cocoa 的 HTML writer 会把附件写成
        // `file:///unknown.png`，字节回不到 HTML。换回占位符后由我们自己补标签。
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

    /// 每个附件 → 它在 HTML 里应该变成的标签片段。
    ///
    /// 同时把附件字符换成占位符，等 HTML 生成完再贴回去。
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

        // 从后往前换，前面的 NSRange 才不会被顶偏。
        for item in found.reversed() {
            let attributes = mutable.attributes(at: item.range.location, effectiveRange: nil)
            let token = NSMutableAttributedString(string: imageMarker)
            token.addAttributes(attributes, range: NSRange(location: 0, length: token.length))
            token.removeAttribute(.attachment, range: NSRange(location: 0, length: token.length))
            mutable.replaceCharacters(in: item.range, with: token)
        }
        return (mutable, slots)
    }

    /// 附件 → `<img …>`。
    ///
    /// 优先用附件自带的 fileId（入口塞进去的，绝对准）；没有就对字节做 SHA256
    /// 反查 `images`——用户从别处复制粘贴进来的图，字节可能正好是笔记里的某张。
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

        // 认不出来的图（用户新插的）：保留 data URI 原样。
        // 写不进备忘录，但至少不会在编辑器里被抹掉。
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
        // 用户粘贴/拖进来的附件是 AppKit 造的，字节在 fileWrapper 里。
        if let data = attachment.fileWrapper?.regularFileContents {
            return data
        }
        // 连 fileWrapper 都没有的（极少数）：退回位图表示，总比丢图强。
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

    /// 按顺序把占位符还原成图片标签。标签数量对不上时剩下的占位符直接删掉，
    /// 免得把 U+E000 这种不可见字符写进笔记。
    static func restoringImages(in fragment: String, slots: [String]) -> String {
        guard fragment.contains(imageMarker) else { return fragment }

        var result = fragment
        for html in slots {
            guard let range = result.range(of: imageMarker) else { break }
            result.replaceSubrange(range, with: html)
        }
        return result.replacingOccurrences(of: imageMarker, with: "")
    }

    /// 图片字节的类型。只做魔数嗅探，够认笔记里常见的几种。
    static func mimeType(of data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return "image/png"
    }

    /// 完整 HTML 文档 → 备忘录能接受的正文片段。
    ///
    /// `data(from:)` 产出的是 `<html><head><style>…</style></head><body>…` 这种完整文档，
    /// 而写回接口只吃片段。这里的两步都不能省：
    ///
    ///   1. 取 `<body>` 内部；
    ///   2. **把 head 里的 class 规则内联成 style 属性**。
    ///
    /// 第 2 步不是可选优化：Cocoa 的 HTML writer 只给粗体/斜体留行内 `<b>/<i>`，
    /// 而颜色、字号、下划线、对齐、缩进全部写成 `class="s2"` + head 里的 `<style>`。
    /// 只取 body 的话这些样式会就地蒸发 —— 用户改了两个字，整篇的颜色和对齐就没了。
    static func fragment(fromFullDocument full: String) -> String {
        let body = bodyFragment(full)
        return inlining(body, classes: classStyles(full))
    }

    // MARK: 片段抽取

    /// `<body>` 内部。找不到就原样返回（宁可多给，也不要丢内容）。
    static func bodyFragment(_ full: String) -> String {
        let found = matches("<body[^>]*>([\\s\\S]*)</body>", in: full, options: [.caseInsensitive])
        return found.first.map { $0[1] } ?? full
    }

    /// head 里 `选择器 { 声明 }` 的 class 索引：`s2` → `font: 20px …; color: #fb0007`。
    ///
    /// 只认 `.cls` 这种形态，够用：writer 的产出里选择器永远是 `p.p1` / `span.s2` /
    /// `ul.ul1` 这类挂在 class 上的写法，没有后代选择器和媒体查询。
    static func classStyles(_ full: String) -> [String: String] {
        let css = matches("<style[^>]*>([\\s\\S]*?)</style>", in: full, options: [.caseInsensitive])
            .map { $0[1] }
            .joined(separator: "\n")
        guard !css.isEmpty else { return [:] }

        var map: [String: String] = [:]
        for rule in matches("([^{}]+)\\{([^{}]*)\\}", in: css) {
            let declarations = cleanedDeclarations(rule[2])
            guard !declarations.isEmpty else { continue }
            // 选择器可能是逗号分隔的一组，每个 class 都吃同一份声明。
            for className in matches("\\.([A-Za-z0-9_-]+)", in: rule[1]).map({ $0[1] }) {
                map[className] = map[className].map { $0 + "; " + declarations } ?? declarations
            }
        }
        return map
    }

    /// 丢掉 Cocoa 私货、并把声明规整成一条 `a: b; c: d`。
    ///
    /// `-webkit-text-stroke` 是 HTML writer 每条规则都会补的残句（只给颜色不给宽度），
    /// 浏览器按无效声明忽略，但别的渲染器可能当成描边；`font-kerning` 是排版细节，
    /// 备忘录侧没有对应语义。两者都清掉，输出更像人手写的 HTML。
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

    // MARK: class → style 内联

    /// 把 body 里每个带 `class` 的标签换成等价的 `style="…"`。
    ///
    /// 已有 style 的标签保留原值并追加在后面（行内样式优先级更高，和 CSS 的层叠一致）。
    /// 从后往前替换，避免前面的替换把后面的 NSRange 顶偏。
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

    // MARK: 标签属性小工具

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

    /// 插在标签名后面（`<p` → `<p style="…"`），属性顺序对 HTML 无影响。
    static func settingAttribute(_ name: String, to value: String, in tag: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "^<[a-zA-Z][a-zA-Z0-9-]*"),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
        else { return tag }

        let text = NSMutableString(string: tag)
        text.insert(" \(name)=\"\(value)\"", at: match.range.location + match.range.length)
        return text as String
    }

    /// `<img fileid="x" width="10"/>` → `width="10"`。导出的标签要原样带回这些属主。
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

    /// 正则取所有匹配，每项是 `[整段, 分组1, 分组2…]`。
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

// MARK: - 图片槽位

/// 一个 `<img fileid>` 在解析前后的全部信息。
private struct ImageSlot {
    var fileId: String
    var extraAttributes: String
    /// 原始字节。`nil` 表示这张图的数据还没到，先显示占位框。
    var data: Data?
}
