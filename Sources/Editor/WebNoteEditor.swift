import SwiftUI
import WebKit
import CryptoKit
import AppKit

/// 正文编辑器能接受的指令。
///
/// 用枚举而不是直接传 JS 字符串：调用方（工具栏）不该知道 `execCommand` 怎么拼，
/// 而且以后换成别的实现时，只需要改执行侧。
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
    /// 选一张本地图片插入到光标处
    case insertImage
    /// 把当前选中的图片换成本地另一张
    case replaceImage
    /// 删除选中的图片
    case deleteImage
}

// 笔记正文的 WebKit 就地编辑器：WKWebView + contenteditable。
//
// 为什么有了 `NoteRichEditor`（NSTextView 方案）还要这个：
//   NSTextView 路线每次编辑都要「整篇 HTML → NSAttributedString → 整篇 HTML」往返，
//   Cocoa 的 HTML 读入/写出器会归一化一切——字体变 Times、`<br>` 变段落、颜色漂移、
//   表格退化。用户只改一个字，代价却是整篇重排。
//
// 这条路线**不重排整篇**：内容以原始 HTML 装进 WebView，用户改一个字只有那个字变，
// 其余 HTML 原样保留。往返成本只剩两处字符串替换：
//     入口：`<img fileid="x">` → `<img src="data:…">`（让用户看得见图）；
//     出口：`<img src="data:…">` → 按 SHA256 指纹反查回 `<img fileid="x">`。
//
// 与 `NoteRichEditor` 的关系：两者并存，由上层决定用哪个；这个文件不改它、不删它。
//
// ⚠️ 已知限制：
//   1. 内容加载走 `loadHTMLString`，是一整页文档，不是真正的"就地 patch"——
//      只有外部 html 真的变化时才重载（见 contentHash 的防循环），正常打字不会触发；
//   2. 复杂 CSS（flex/grid/伪元素）Web 端原生支持，理论上比 NSTextView 路线保真得多，
//      但 Safari 对部分小米笔记私有的行内写法仍可能有细小渲染差异；
//   3. 撤销栈由 WebKit 管理，跨重载（外部改稿触发的 loadHTMLString）会丢。

// MARK: - 编辑器

/// WKWebView + contenteditable 的就地 HTML 编辑器。
///
/// 用法：把备忘录正文 HTML 片段绑进来，用户改完自动回写 `html`（仍是片段）。
/// `isEditable == false` 时降级成"可选中复制的只读渲染"。
struct WebNoteEditor: NSViewRepresentable {

    /// 双向绑定：进来是初始 HTML 片段，出去是编辑后的 HTML 片段。
    @Binding var html: String

    /// 是否可编辑。只读时仍然可选、可复制。
    var isEditable: Bool = true

    /// 笔记里图片的原始字节，key 是 fileId。
    /// 进入时把 `<img fileid="x">` 换成 data URI 显示，导出时按指纹换回。
    var images: [String: Data] = [:]

    /// 内容高度回传。
    ///
    /// WKWebView 没有固有高度（`noIntrinsicMetric`），SwiftUI 在 ScrollView 里
    /// 问不到内容有多高，`.frame(minHeight:)` 就会变成**实际高度**，
    /// 超出的正文被关进 WebView 自己的内部滚动区——外层只看到一块 240pt 的盒子，
    /// 下面全是空白。必须让页面把真实高度量出来报上去。
    @Binding var contentHeight: CGFloat

    /// 外部（工具栏）下发的编辑指令。执行后由编辑侧清空，避免重复执行。
    @Binding var command: NoteEditorCommand?

    func makeCoordinator() -> WebNoteEditorCoordinator { WebNoteEditorCoordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 正文只在内存里：笔记内容不应落进 WebView 的磁盘缓存。
        configuration.websiteDataStore = .nonPersistent()

        let userController = WKUserContentController()
        // 用 weak 代理注册，避免 userContentController 强持有 Coordinator 造成泄漏。
        let proxy = WeakMessageProxy()
        proxy.target = context.coordinator
        userController.add(proxy, name: "changed")
        userController.add(proxy, name: "height")
        // 输入监听脚本对之后的每次 loadHTMLString 都生效（addUserScript 是持久的）。
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
        // 背景透明：外层 SwiftUI 已有底色和 padding，这里再画一层白色会盖住它。
        //
        // 两条都要：`drawsBackground` 是私有 KVC，在新系统上不一定生效；
        // `underPageBackgroundColor` 是公开 API，管的是"页面外的底色"。
        // 只设前者的话，深色模式下会出现一整块白纸。
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        // 不额外去禁 WebView 的内部滚动：macOS 的 WKWebView 没有公开的 `scrollView`
        // 属性（那是 UIKit 才有的）。滚动交给 CSS —— `html, body { overflow: hidden }`
        // 配合外层按内容高度撑开，页面本身就不会产生可滚动区域。

        context.coordinator.webView = webView
        context.coordinator.load(html: html, images: images, editable: isEditable)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Binding 是结构体里的属性，SwiftUI 每次更新都会造一个新的 self，
        // coordinator 里存的那份必须同步，否则回写会写进上一轮的 binding。
        context.coordinator.parent = self

        // 防重载循环的关键：自己改字触发的回写，哈希已被 coordinator 提前更新过，
        // 这里会直接跳过——否则每敲一个字整页重载、光标丢失。
        // 图片字节也算结构不算内容：key 或大小变了就说明该重载（异步到图的场景）。
        let hash = Self.contentHash(html: html, images: images)
        if context.coordinator.appliedHash != hash {
            context.coordinator.load(html: html, images: images, editable: isEditable)
            return
        }
        if context.coordinator.isEditable != isEditable {
            context.coordinator.setEditable(isEditable)
        }

        // 工具栏指令：执行一次就清空。
        // 清空要**异步**做——在 updateNSView 里同步改 Binding 会触发
        // "Modifying state during view update" 警告，严重时死循环。
        if let command {
            let pending = command
            context.coordinator.run(pending)
            DispatchQueue.main.async { self.command = nil }
        }
    }

    /// 内容指纹：HTML + 图片字典的"结构"（key 与字节长度）。
    ///
    /// 刻意不对字节本身做哈希——`updateNSView` 每次敲键都会走一遍，几 MB 的图
    /// 逐字节哈希会把主线程拖住；key 或大小变了就足够说明该重载了。
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

    /// 注入页面的输入监听：`input` 事件 debounce 300ms 后回传 innerHTML。
    ///
    /// 只读 innerHTML，不做任何光标/选区操作——中文输入法的组合串交给 WebKit。
    /// 用捕获阶段监听，contenteditable 在 body 上，事件一定能到达 document。
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
    })();
    """

    /// 内容高度监听：渲染完成、内容变化、图片撑开时，把真实高度报回 Swift。
    ///
    /// 多个时机都要量：`DOMContentLoaded` 时图片还没加载（高度偏小），
    /// `load` 之后才准；编辑改变内容时靠 `ResizeObserver`；
    /// 最后再补两个延时兜底，防止首帧布局未完成时报了个 0。
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

// MARK: - Coordinator

final class WebNoteEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    var parent: WebNoteEditor
    weak var webView: WKWebView?

    /// 上一次写进 WebView 的（回传整形后的）HTML 的哈希。
    ///
    /// 这是防重载循环的关键：`changed` 回调把内容回写 binding 后，SwiftUI 立刻调
    /// `updateNSView`，此时传进来的 html 就是刚回写的那个。若这里不认账、无条件
    /// `loadHTMLString`，光标会丢、中文输入法组合串会断。
    private(set) var appliedHash: Int?

    private(set) var isEditable: Bool

    init(_ parent: WebNoteEditor) {
        self.parent = parent
        self.isEditable = parent.isEditable
        super.init()
    }

    /// 把 HTML 包成完整文档加载，并记下这次写入的哈希。
    ///
    /// **baseURL 必须是 nil**：一旦设了，HTML 里的相对 `src` 会变成可解析的远程
    /// 地址，WebView 会真的去联网下载。
    func load(html: String, images: [String: Data], editable: Bool) {
        isEditable = editable
        let prepared = WebNoteHTMLBridge.preparingImagesForDisplay(html, images: images)
        let document = WebNoteHTMLBridge.fullDocument(prepared, editable: editable)
        appliedHash = WebNoteEditor.contentHash(html: html, images: images)
        webView?.loadHTMLString(document, baseURL: nil)
    }

    /// 不重载页面、只切换可编辑状态（isEditable 翻转时走这条路，保住光标和撤销栈）。
    func setEditable(_ editable: Bool) {
        isEditable = editable
        webView?.evaluateJavaScript(
            "document.body.contentEditable = '\(editable ? "true" : "false")'",
            completionHandler: nil
        )
    }

    // MARK: 工具栏指令

    /// 执行一条编辑指令。
    ///
    /// 格式类走 `execCommand`：WebKit 原生支持加粗/标题/列表，且会自动进入
    /// 撤销栈（⌘Z 能退回来）。自己操作 DOM 就享受不到这一点。
    func run(_ command: NoteEditorCommand) {
        guard let webView else { return }

        switch command {
        case .insertImage:
            insertImage(into: webView)
            return

        case .deleteImage:
            // 选中图片（或被它包住的文本节点）后删掉整个 `<img>`
            webView.evaluateJavaScript("""
            (function(){
                var sel = window.getSelection();
                if (!sel || sel.rangeCount === 0) return;
                var node = sel.anchorNode;
                while (node && node.nodeName !== 'IMG') { node = node.parentNode; }
                if (node) node.remove();
            })();
            """, completionHandler: nil)
            return

        case .replaceImage:
            replaceSelectedImage(into: webView)
            return

        default:
            break
        }

        let js: String
        switch command {
        case .bold: js = "document.execCommand('bold')"
        case .italic: js = "document.execCommand('italic')"
        case .underline: js = "document.execCommand('underline')"
        case .heading1: js = "document.execCommand('formatBlock', false, 'h1')"
        case .heading2: js = "document.execCommand('formatBlock', false, 'h2')"
        case .heading3: js = "document.execCommand('formatBlock', false, 'h3')"
        case .paragraph: js = "document.execCommand('formatBlock', false, 'p')"
        case .bulletList: js = "document.execCommand('insertUnorderedList')"
        case .orderedList: js = "document.execCommand('insertOrderedList')"
        case .undo: js = "document.execCommand('undo')"
        case .redo: js = "document.execCommand('redo')"
        default: return
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 选一张本地图片插到光标处。
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

    /// 把当前选中的图片换成另一张。
    private func replaceSelectedImage(into webView: WKWebView) {
        guard let data = pickImageData() else { return }
        let base64 = data.base64EncodedString()
        webView.evaluateJavaScript("""
        (function(){
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0) return;
            var node = sel.anchorNode;
            while (node && node.nodeName !== 'IMG') { node = node.parentNode; }
            if (!node) return;
            node.src = 'data:image/png;base64,\(base64)';
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

    // MARK: JS 桥

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // 高度回传：交给 SwiftUI 撑开，不再靠 minHeight 猜。
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
            // 只在变化超过 1pt 时写，避免子像素抖动引发无限布局循环
            if abs(height - parent.contentHeight) > 1 {
                parent.contentHeight = height
            }
            return
        }

        guard message.name == "changed", let raw = message.body as? String else { return }

        // data URI 换回 fileid 再写 binding。只读 innerHTML，不碰光标。
        let fragment = WebNoteHTMLBridge.restoringImages(in: raw, images: parent.images)

        // 先更新哈希，再回写 binding：顺序反了的话，binding 触发的那次
        // updateNSView 会看到旧哈希，把刚敲的内容整段重载一遍。
        appliedHash = WebNoteEditor.contentHash(html: fragment, images: parent.images)

        guard fragment != parent.html else { return }
        parent.html = fragment
    }
}

// MARK: - 滚动穿透

/// 自身滚不动时，把滚轮交给外层。
///
/// WKWebView 内部有一个自己的 NSScrollView：内容没溢出时它滚不动，
/// 但它依然**消费掉**滚轮事件，不往 superview 传。
/// 结果是"鼠标停在正文上滚不动，挪到旁边的空白才滚得动"——
/// 而正文几乎占满整栏，用户体感就是"整页不能滚"。
///
/// 这里判断内部是否真的可滚：可滚就自己处理，不可滚就转交给下一响应者，
/// 让外层 SwiftUI 的 ScrollView 接管。
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
            // 自己没得滚：交给外层，别把事件吞掉
            super.nextResponder?.scrollWheel(with: event)
        }
    }

    /// 在子视图里找 WKWebView 内部那个滚动视图。
    /// 这是 WebKit 的固定结构（WKWebView → _WKWebView → NSScrollView），
    /// 只读遍历，不调用任何私有方法。
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

/// WKUserContentController 会强持有注册进来的 handler；包一层弱引用，
/// 否则 Coordinator（连带整个绑定链）永远释放不掉。
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {

    weak var target: WebNoteEditorCoordinator?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - HTML 整形

/// 进 Web 前后的两次图片替换，以及文档包装。
///
/// 正则写法与 `NoteRichEditor.swift` 里的图片处理保持一致（`<img\b[^>]*>`、
/// 大小写不敏感、从后往前替换），两边的行为可以对得上。
enum WebNoteHTMLBridge {

    // MARK: 文档包装

    /// 片段 → 完整文档。样式表对齐 SwiftUI 版正文的观感；
    /// body 的 margin/padding/背景都清零，留白交给外层 SwiftUI。
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

    // MARK: 入口（fileid → data URI）

    /// 把每个 `<img … fileid="X" …>` 换成带 data URI 的 `<img>`。
    ///
    /// `images[X]` 缺失时**保留原标签不动**——宁可不显示，也不能篡改用户笔记
    /// 里本来就有的标签。
    static func preparingImagesForDisplay(_ html: String, images: [String: Data]) -> String {
        guard html.range(of: "<img", options: [.caseInsensitive]) != nil,
              let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        else { return html }

        let text = NSMutableString(string: html)
        let source = text as NSString
        let found = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        guard !found.isEmpty else { return html }

        // 从后往前替换，避免前面的替换把后面的 NSRange 顶偏。
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

    // MARK: 出口（data URI → fileid）

    /// 把能认出来的 `<img src="data:…">` 换回 `<img fileid="…">`。
    ///
    /// 认法：解出字节做 SHA256，反查 `images` 的指纹表——和 `NoteRichEditor`
    /// 导出附件时的反查逻辑一致。未命中的（用户新插的图）保留 data URI。
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

            // 换回 fileid 形态：去掉 src，其余属性原样保留。
            var patched = removingAttribute("src", from: tag)
            patched = removingAttribute("fileid", from: patched)
            patched = settingAttribute("fileid", to: fileId, in: patched)
            text.replaceCharacters(in: match.range, with: patched)
        }
        return text as String
    }

    /// `<img src="data:image/png;base64,AAAA…" …>` → base64 载荷。
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

    // MARK: 标签属性小工具（与 NoteRichEditor 的实现保持一致）

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

    /// 插在标签名后面（`<img` → `<img src="…"`），属性顺序对 HTML 无影响。
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
}
