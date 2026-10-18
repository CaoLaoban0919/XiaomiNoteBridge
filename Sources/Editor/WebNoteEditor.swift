import SwiftUI
import WebKit
import CryptoKit
import AppKit

enum NoteEditorCommand: Equatable {
    case bold
    case italic
    case underline
    case heading1
    case heading2
    case heading3
    case paragraph
    case bulletList
    case orderedList
    case undo
    case redo

    case insertImage
}

struct WebNoteEditor: NSViewRepresentable {

    @Binding var html: String

    var isEditable: Bool = true

    var images: [String: Data] = [:]

    @Binding var contentHeight: CGFloat

    @Binding var command: NoteEditorCommand?

    func makeCoordinator() -> WebNoteEditorCoordinator { WebNoteEditorCoordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        configuration.websiteDataStore = .nonPersistent()

        let userController = WKUserContentController()

        let proxy = WeakMessageProxy()
        proxy.target = context.coordinator
        userController.add(proxy, name: "changed")
        userController.add(proxy, name: "height")

        userController.addUserScript(
            WKUserScript(
                source: Self.changeWatcherJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        userController.addUserScript(
            WKUserScript(
                source: Self.heightWatcherJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController = userController

        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        context.coordinator.webView = webView
        context.coordinator.load(html: html, images: images, editable: isEditable)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {

        context.coordinator.parent = self

        let hash = Self.contentHash(html: html, images: images)
        if context.coordinator.appliedHash != hash {
            context.coordinator.load(html: html, images: images, editable: isEditable)

            if command != nil {
                DispatchQueue.main.async { self.command = nil }
            }
            return
        }
        if context.coordinator.isEditable != isEditable {
            context.coordinator.setEditable(isEditable)
        }

        if let command {
            let pending = command
            context.coordinator.run(pending)
            DispatchQueue.main.async { self.command = nil }
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

    static let changeWatcherJS = """
    (function() {
        var timer = null;
        document.addEventListener('input', function() {
            if (timer) clearTimeout(timer);
            timer = setTimeout(function() {
                timer = null;
                try {
                    window.webkit.messageHandlers.changed.postMessage(document.body.innerHTML);
                } catch (e) {}
            }, 300);
        }, true);

        // 点图片时把选区落到图片上。
        // contenteditable 里点一下图片，WebKit 通常只把光标放在图片**旁边**，
        // 不产生"选中"——于是按 Delete 删不掉，界面也判断不出选中了哪张图。
        // 这里点中图片就强制 selectNode，用户就能直接按 Delete 删除。
        document.addEventListener('click', function(e) {
            var target = e.target;
            if (target && target.nodeName === 'IMG') {
                var range = document.createRange();
                range.selectNode(target);
                var sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
            }
        }, true);
    })();
    """

    static let heightWatcherJS = """
    (function() {
        var last = 0;
        function report() {
            try {
                var h = Math.ceil(document.body.scrollHeight);
                if (h > 0 && h !== last) {
                    last = h;
                    window.webkit.messageHandlers.height.postMessage(h);
                }
            } catch (e) {}
        }
        document.addEventListener('DOMContentLoaded', report);
        window.addEventListener('load', report);
        if (window.ResizeObserver) {
            new ResizeObserver(report).observe(document.body);
        }
        setTimeout(report, 50);
        setTimeout(report, 300);
        setTimeout(report, 1000);
    })();
    """
}

final class WebNoteEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    var parent: WebNoteEditor
    weak var webView: WKWebView?

    private(set) var appliedHash: Int?

    private(set) var isEditable: Bool

    init(_ parent: WebNoteEditor) {
        self.parent = parent
        self.isEditable = parent.isEditable
        super.init()
    }

    func load(html: String, images: [String: Data], editable: Bool) {
        isEditable = editable
        let prepared = WebNoteHTMLBridge.preparingImagesForDisplay(html, images: images)
        let document = WebNoteHTMLBridge.fullDocument(prepared, editable: editable)
        appliedHash = WebNoteEditor.contentHash(html: html, images: images)
        webView?.loadHTMLString(document, baseURL: nil)
    }

    func setEditable(_ editable: Bool) {
        isEditable = editable
        webView?.evaluateJavaScript(
            "document.body.contentEditable = '\(editable ? "true" : "false")'",
            completionHandler: nil
        )
    }

    func run(_ command: NoteEditorCommand) {
        guard let webView else { return }

        webView.window?.makeFirstResponder(webView)

        switch command {
        case .insertImage:

            DispatchQueue.main.async { [weak self] in
                guard let self, let webView = self.webView else { return }
                self.insertImage(into: webView)
            }
            return

        default:
            break
        }

        if let tag = Self.blockTag(for: command) {
            webView.evaluateJavaScript(Self.setBlockScript(tag), completionHandler: nil)
            return
        }

        let js: String
        switch command {
        case .bold: js = "document.execCommand('bold')"
        case .italic: js = "document.execCommand('italic')"
        case .underline: js = "document.execCommand('underline')"
        case .bulletList: js = "document.execCommand('insertUnorderedList')"
        case .orderedList: js = "document.execCommand('insertOrderedList')"
        case .undo: js = "document.execCommand('undo')"
        case .redo: js = "document.execCommand('redo')"
        default: return
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func blockTag(for command: NoteEditorCommand) -> String? {
        switch command {
        case .heading1: return "h1"
        case .heading2: return "h2"
        case .heading3: return "h3"
        case .paragraph: return "p"
        default: return nil
        }
    }

    private static func setBlockScript(_ tag: String) -> String {
        """
        (function(){
            var target = '\(tag)';
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0) return;

            // 1. 先试原生路径（可进撤销栈）
            try { document.execCommand('formatBlock', false, target); } catch (e) {}

            // 2. 核对实际结果：WebKit 有时报成功但没改
            var actual = '';
            try { actual = (document.queryCommandValue('formatBlock') || '').toLowerCase(); } catch (e) {}
            if (actual === target) return;

            // 3. 兜底：手动替换最近的块级祖先
            var node = sel.anchorNode;
            while (node && node.nodeType !== 1) { node = node.parentNode; }
            var blocks = ['H1','H2','H3','H4','H5','H6','P','DIV','LI','BLOCKQUOTE'];
            while (node && blocks.indexOf(node.tagName) === -1) { node = node.parentNode; }
            if (!node || node === document.body || !node.parentNode) return;

            var el = document.createElement(target);
            el.innerHTML = node.innerHTML;
            node.parentNode.replaceChild(el, node);

            // 光标落到新块末尾，继续打字不会跳回旧块
            var range = document.createRange();
            range.selectNodeContents(el);
            range.collapse(false);
            sel.removeAllRanges();
            sel.addRange(range);
        })();
        """
    }

    private func insertImage(into webView: WKWebView) {
        guard let data = pickImageData() else { return }
        let base64 = data.base64EncodedString()
        webView.evaluateJavaScript("""
        (function(){
            var img = document.createElement('img');
            img.src = 'data:image/png;base64,\(base64)';
            img.style.maxWidth = '100%';
            var sel = window.getSelection();
            if (sel && sel.rangeCount > 0) {
                var range = sel.getRangeAt(0);
                range.deleteContents();
                range.insertNode(img);
                range.collapse(false);
            } else {
                document.body.appendChild(img);
            }
        })();
        """, completionHandler: nil)
    }

    private func pickImageData() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "选择要插入的图片"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {

        if message.name == "height" {
            let raw: Double
            if let d = message.body as? Double {
                raw = d
            } else if let i = message.body as? Int {
                raw = Double(i)
            } else {
                return
            }
            guard raw > 0 else { return }
            let height = CGFloat(raw)

            if abs(height - parent.contentHeight) > 1 {
                parent.contentHeight = height
            }
            return
        }

        guard message.name == "changed", let raw = message.body as? String else { return }

        let fragment = WebNoteHTMLBridge.restoringImages(in: raw, images: parent.images)

        appliedHash = WebNoteEditor.contentHash(html: fragment, images: parent.images)

        guard fragment != parent.html else { return }
        parent.html = fragment
    }
}

final class PassthroughWebView: WKWebView {

    override func scrollWheel(with event: NSEvent) {
        guard let inner = innerScrollView() else {
            super.nextResponder?.scrollWheel(with: event)
            return
        }

        let documentHeight = inner.documentView?.frame.height ?? 0
        let viewportHeight = inner.contentSize.height
        let canScroll = documentHeight > viewportHeight + 1

        if canScroll {
            super.scrollWheel(with: event)
        } else {

            super.nextResponder?.scrollWheel(with: event)
        }
    }

    private func innerScrollView() -> NSScrollView? {
        for subview in subviews {
            if let scroll = subview as? NSScrollView { return scroll }
            if let scroll = subview.subviews.compactMap({ $0 as? NSScrollView }).first {
                return scroll
            }
        }
        return nil
    }
}

private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {

    weak var target: WebNoteEditorCoordinator?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

enum WebNoteHTMLBridge {

    static func fullDocument(_ body: String, editable: Bool) -> String {
        let editableAttr = editable ? "true" : "false"
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <style>\(documentCSS)</style></head>\
        <body contenteditable="\(editableAttr)">\(body)</body></html>
        """
    }

    static let documentCSS = """
    :root { color-scheme: light dark; }

    /* 文档本身必须透明：WebView 的默认文档底色是白，
       深色模式下就是"一整块白纸"压在深色界面上。 */
    html, body { background: transparent !important; }
    /* **不要加 `overflow: hidden`。**
       它会让 `scrollHeight` 返回视口高度而不是内容高度，
       高度回传随之失效，正文被裁在被限高的盒子里又无法滚动——
       表现就是"笔记完全翻不动"。滚动交给外层 SwiftUI ScrollView。 */

    body {
        margin: 0;
        padding: 0;
        /* **可编辑区必须铺满 SwiftUI 给的最小高度。**
           body 默认高度 = 内容高度：一行字的笔记只有 21pt，
           而外层把 WebView 撑到 240pt，剩下 219pt 落在 contenteditable 之外，
           点在那里不出光标、键盘没有落点——表现就是"打不进字"。
           这里补上同样数值的 min-height，两边严丝合缝。 */
        min-height: 240px;
        font-family: -apple-system, "PingFang SC", sans-serif;
        font-size: 13px;
        line-height: 1.65;
        -webkit-user-select: text;
        /* 必须显式给颜色。WebView 的默认文字色是黑，不会跟随系统外观——
           深色模式下就是"黑字压深底"，等于整页看不见。 */
        color: #1c1c1e;
    }
    h1 { font-size: 26px; font-weight: 700; }
    h2 { font-size: 21px; font-weight: 700; }
    h3 { font-size: 18px; font-weight: 600; }
    p { margin: 0.6em 0; }
    ul, ol { padding-left: 1.4em; }
    img { max-width: 100%; height: auto; }

    @media (prefers-color-scheme: dark) {
        body { color: #e6e6e8; }

        /* 笔记正文里的颜色是**内联写死**的（小米导出、AI 生成都常见），
           它们不认 `body` 的 color。只把"纯黑/近黑"提亮，
           其它颜色原样保留——用户有意用的红字、高亮不该被改掉。 */
        [style*="color:#000"], [style*="color: #000"],
        [style*="color:#000000"], [style*="color: #000000"],
        [style*="color:rgb(0,0,0)"], [style*="color: rgb(0, 0, 0)"],
        [style*="color:black"], [style*="color: black"] {
            color: #e6e6e8 !important;
        }

        /* 内联白色底同理：小米笔记常给整段包一层白底，
           深色下那块会变成刺眼的白纸。只在深色模式清掉它。 */
        [style*="background:#fff"], [style*="background: #fff"],
        [style*="background:#ffffff"], [style*="background: #ffffff"],
        [style*="background:white"], [style*="background: white"],
        [style*="background-color:rgb(255,255,255)"],
        [style*="background-color: rgb(255, 255, 255)"] {
            background: transparent !important;
        }

        /* 深色底上的链接，默认蓝偏暗，提亮一档 */
        a { color: #6cb6ff; }
    }
    """

    static func preparingImagesForDisplay(_ html: String, images: [String: Data]) -> String {
        guard html.range(of: "<img", options: [.caseInsensitive]) != nil,
              let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        else { return html }

        let text = NSMutableString(string: html)
        let source = text as NSString
        let found = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        guard !found.isEmpty else { return html }

        for match in found.reversed() {
            let tag = source.substring(with: match.range)
            guard let fileId = attribute("fileid", in: tag),
                  let data = images[fileId], !data.isEmpty
            else { continue }

            let uri = "data:\(mimeType(of: data));base64,\(data.base64EncodedString())"
            var patched = removingAttribute("src", from: tag)
            patched = settingAttribute("src", to: uri, in: patched)
            text.replaceCharacters(in: match.range, with: patched)
        }
        return text as String
    }

    static func restoringImages(in fragment: String, images: [String: Data]) -> String {
        guard fragment.range(of: "<img", options: [.caseInsensitive]) != nil,
              let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        else { return fragment }

        let source = fragment as NSString
        let found = regex.matches(
            in: fragment,
            range: NSRange(location: 0, length: source.length)
        )
        guard !found.isEmpty else { return fragment }

        var fingerprints: [SHA256.Digest: String] = [:]
        for (fileId, data) in images {
            let digest = SHA256.hash(data: data)
            if fingerprints[digest] == nil { fingerprints[digest] = fileId }
        }

        let text = NSMutableString(string: fragment)
        for match in found.reversed() {
            let tag = source.substring(with: match.range)
            guard let payload = dataURIPayload(in: tag),
                  let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
                  let fileId = fingerprints[SHA256.hash(data: data)]
            else { continue }

            var patched = removingAttribute("src", from: tag)
            patched = removingAttribute("fileid", from: patched)
            patched = settingAttribute("fileid", to: fileId, in: patched)
            text.replaceCharacters(in: match.range, with: patched)
        }
        return text as String
    }

    static func dataURIPayload(in tag: String) -> String? {
        let pattern = "\\ssrc\\s*=\\s*[\"']data:[^\"']*;base64,([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: tag,
                range: NSRange(location: 0, length: (tag as NSString).length)
              ),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range])
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\s\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: tag,
                range: NSRange(location: 0, length: (tag as NSString).length)
              ),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range])
    }

    static func removingAttribute(_ name: String, from tag: String) -> String {
        let pattern = "\\s\(name)\\s*=\\s*[\"'][^\"']*[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return tag
        }
        return regex.stringByReplacingMatches(
            in: tag,
            range: NSRange(location: 0, length: (tag as NSString).length),
            withTemplate: ""
        )
    }

    static func settingAttribute(_ name: String, to value: String, in tag: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "^<[a-zA-Z][a-zA-Z0-9-]*"),
              let match = regex.firstMatch(
                in: tag,
                range: NSRange(location: 0, length: (tag as NSString).length)
              )
        else { return tag }

        let text = NSMutableString(string: tag)
        text.insert(" \(name)=\"\(value)\"", at: match.range.location + match.range.length)
        return text as String
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
}
