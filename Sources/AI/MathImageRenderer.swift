import AppKit
import PDFKit
import WebKit

/// 公式和 SVG 图表在导出时转成 PNG；编辑器保留原始内容。
enum MathImageRenderer {
    @MainActor
    private final class Completion<Value> {
        var continuation: CheckedContinuation<Value, Error>?
        var timer: Task<Void, Never>?
        func finish(_ result: Result<Value, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel(); timer = nil
            continuation.resume(with: result)
        }
    }

    /// WebKit 的导航、JS Promise、PDF 回调都可能不返回，不能只给外层轮询设置超时。
    @MainActor
    static func bounded<Value>(timeout: TimeInterval = 12, _ start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let completion = Completion<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion.continuation = continuation
                completion.timer = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000)) }
                    catch { return }
                    completion.finish(.failure(RenderError.timeout))
                }
                start { result in Task { @MainActor in completion.finish(result) } }
            }
        } onCancel: {
            Task { @MainActor in completion.finish(.failure(CancellationError())) }
        }
    }

    @MainActor
    private static func evaluate(_ script: String, in webView: WKWebView) async throws -> Any {
        try await bounded { done in
            webView.evaluateJavaScript(script) { value, error in
                if let error { done(.failure(error)) } else { done(.success(value as Any)) }
            }
        }
    }

    @MainActor
    private static func call(_ script: String, arguments: [String: Any], in webView: WKWebView) async throws -> Any {
        try await bounded { done in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page, completionHandler: done)
        }
    }
    struct RenderedImage {
        let dataURL: String
        let pngData: Data
        let size: NSSize
    }

    enum RenderError: LocalizedError {
        case emptyFormula
        case failed(String)
        case timeout
        case invalidBounds
        case emptyImage

        var errorDescription: String? {
            switch self {
            case .emptyFormula: return "公式内容为空"
            case .failed(let reason): return "公式渲染失败：\(reason)"
            case .timeout: return "公式或图表导出超时，请稍后重试；原笔记未修改。"
            case .invalidBounds: return "公式图片尺寸无效或过大"
            case .emptyImage: return "公式导出没有生成可见像素"
            }
        }
    }

    @MainActor
    static func renderPNG(_ latex: String, display: Bool) async -> String? {
        do { return try await renderedImage(latex, display: display).dataURL }
        catch {
            NSLog("MiNoteMath: %@", error.localizedDescription)
            return nil
        }
    }

    @MainActor
    static func renderedImage(_ latex: String, display: Bool) async throws -> RenderedImage {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RenderError.emptyFormula }
        let source = display ? "\\[\(latex)\\]" : "\\(\(latex)\\)"
        let node = "<span class=\"mn-math\(display ? " mn-math-display" : "")\" data-latex=\"\(Data(latex.utf8).base64EncodedString())\" data-display=\"\(display)\" contenteditable=\"false\">\(escapeHTML(source))</span>"
        let webView = makeWebView()
        defer { webView.stopLoading() }
        webView.loadHTMLString(document(node, image: true), baseURL: nil)
        try await waitUntilReady(webView)
        guard let bounds = try await evaluate(#"""
        (() => {
          const node = document.querySelector('[data-latex]');
          const formula = node && node.querySelector('.katex');
          if (!formula || !node.hasAttribute('data-mn-rendered')) return null;
          const rect = formula.getBoundingClientRect();
          const inner = node.querySelector('.katex-html');
          const content = inner ? inner.getBoundingClientRect() : rect;
          const left = Math.min(rect.left, content.left), top = Math.min(rect.top, content.top);
          const right = Math.max(rect.right, content.right), bottom = Math.max(rect.bottom, content.bottom);
          return [Math.floor(left) - 3, Math.floor(top) - 3, Math.ceil(right - left) + 6, Math.ceil(bottom - top) + 6];
        })()
        """#, in: webView) as? [NSNumber], bounds.count == 4 else { throw RenderError.invalidBounds }
        let rect = CGRect(x: bounds[0].doubleValue, y: bounds[1].doubleValue, width: bounds[2].doubleValue, height: bounds[3].doubleValue)
        return try await image(in: webView, rect: rect)
    }

    @MainActor
    private static func image(in webView: WKWebView, rect: CGRect) async throws -> RenderedImage {
        try Task.checkCancellation()
        await Task.yield()
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.minX >= 0, rect.minY >= 0, rect.width > 6, rect.height > 6, rect.width <= 16_384, rect.height <= 8_192, rect.width * rect.height <= 16_000_000 else { throw RenderError.invalidBounds }
        // SVG 的响应式宽度会随 WebView 改变；截取已有布局，不能因截图调整宽度。
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        let pdf: Data = try await bounded { done in
            webView.createPDF(configuration: configuration, completionHandler: done)
        }
        guard let document = PDFDocument(data: pdf), let page = document.page(at: 0) else { throw RenderError.emptyImage }
        let pageBounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(ceil(pageBounds.width * scale)), height = Int(ceil(pageBounds.height * scale))
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.emptyImage }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { throw RenderError.emptyImage }
        var ink = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            if min(buffer[index], buffer[index + 1], buffer[index + 2]) < 230 { ink += 1 }
        }
        guard ink > 0, let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw RenderError.emptyImage }
        return RenderedImage(dataURL: "data:image/png;base64," + png.base64EncodedString(), pngData: png, size: rect.size)
    }

    /// 只有全部源节点成功时才返回导出 HTML；任何公式失败都不返回部分结果。
    @MainActor
    static func exportHTML(_ html: String) async throws -> String {
        try Task.checkCancellation()
        let webView = makeWebView()
        defer { webView.stopLoading() }
        webView.loadHTMLString(document("", image: false), baseURL: nil)
        try await waitUntilReady(webView)
        _ = try await call(#"""
        const parsed = new DOMParser().parseFromString(html, 'text/html');
        for (const element of parsed.querySelectorAll('script,link,meta,base,iframe,object,embed')) element.remove();
        for (const element of parsed.querySelectorAll('*')) {
          for (const attribute of Array.from(element.attributes)) if (attribute.name.toLowerCase().startsWith('on')) element.removeAttribute(attribute.name);
        }
        document.body.replaceChildren(...Array.from(parsed.body.childNodes));
        await window.MiNoteMath.start();
        document.body.innerHTML = window.MiNoteMath.canonicalHTML();
        await window.MiNoteMath.start();
        return true;
        """#, arguments: ["html": html], in: webView)
        guard let formulas = try await evaluate(#"""
        Array.from(document.querySelectorAll('[data-latex]')).map(node => ({
          latex: node.getAttribute('data-latex'), display: node.getAttribute('data-display') === 'true'
        }))
        """#, in: webView) as? [[String: Any]] else { throw RenderError.failed("无法读取公式源节点") }
        var images: [[String: Any]] = []
        for formula in formulas {
            guard let encoded = formula["latex"] as? String, let data = Data(base64Encoded: encoded), let latex = String(data: data, encoding: .utf8) else { throw RenderError.failed("公式源码编码无效") }
            let image = try await renderedImage(latex, display: formula["display"] as? Bool ?? false)
            images.append(["src": image.dataURL, "width": image.size.width, "height": image.size.height])
        }
        _ = try await call(#"""
        document.body.innerHTML = window.MiNoteMath.canonicalHTML();
        const nodes = Array.from(document.querySelectorAll('[data-latex]'));
        if (nodes.length !== images.length) throw new Error('公式节点数量发生变化');
        nodes.forEach((node, index) => {
          const image = document.createElement('img');
          image.src = images[index].src;
          image.alt = node.textContent;
          image.setAttribute('data-latex', node.getAttribute('data-latex'));
          image.setAttribute('data-display', node.getAttribute('data-display'));
          image.setAttribute('data-math-source', btoa(Array.from(new TextEncoder().encode(node.textContent), b => String.fromCharCode(b)).join('')));
          image.style.cssText = 'max-width:100%;height:auto;background:#fff;color:#222;' + (node.getAttribute('data-display') === 'true' ? 'display:block;margin:8px 0;' : 'display:inline-block;vertical-align:middle;');
          image.width = Math.ceil(images[index].width);
          image.height = Math.ceil(images[index].height);
          node.replaceWith(image);
        });
        return document.body.innerHTML;
        """#, arguments: ["images": images], in: webView)
        // Apple 备忘录不接收内联 SVG。先截图再替换，避免 ENML 清理时整张图消失。
        guard let charts = try await evaluate(#"""
        Array.from(document.querySelectorAll('svg')).filter(svg => !svg.parentElement.closest('svg')).map(svg => {
          const rect = svg.getBoundingClientRect();
          return [rect.x, rect.y, rect.width, rect.height];
        })
        """#, in: webView) as? [[NSNumber]] else { throw RenderError.failed("无法读取图表尺寸") }
        var chartImages: [[String: Any]] = []
        for bounds in charts {
            guard bounds.count == 4 else { throw RenderError.invalidBounds }
            let rect = CGRect(x: bounds[0].doubleValue, y: bounds[1].doubleValue, width: bounds[2].doubleValue, height: bounds[3].doubleValue)
            let rendered = try await image(in: webView, rect: rect)
            chartImages.append(["src": rendered.dataURL, "width": rendered.size.width, "height": rendered.size.height])
        }
        guard let output = try await call(#"""
        const charts = Array.from(document.querySelectorAll('svg')).filter(svg => !svg.parentElement.closest('svg'));
        if (charts.length !== images.length) throw new Error('图表数量发生变化');
        charts.forEach((svg, index) => {
          const image = document.createElement('img');
          image.src = images[index].src;
          image.width = Math.ceil(images[index].width);
          image.height = Math.ceil(images[index].height);
          image.alt = svg.getAttribute('aria-label') || '图表';
          image.style.cssText = 'max-width:100%;height:auto;display:block;background:#fff;';
          svg.replaceWith(image);
        });
        return document.body.innerHTML;
        """#, arguments: ["images": chartImages], in: webView) as? String else { throw RenderError.failed("导出图表失败") }
        return output
    }

    /// 旧调用方兼容入口；失败时完整保留输入，不删除定界符。
    @MainActor
    static func replaceDisplayMath(in text: String) async -> String {
        do { return try await exportHTML(text) }
        catch {
            NSLog("MiNoteMath 导出失败：%@", error.localizedDescription)
            return text
        }
    }

    @MainActor
    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 400), configuration: configuration)
    }

    @MainActor
    private static func waitUntilReady(_ webView: WKWebView) async throws {
        for _ in 0..<400 {
            try Task.checkCancellation()
            if let state = try await evaluate("({ready:window.__mathReady === true, settled:window.__mathSettled === true, errors:window.__mathErrors || []})", in: webView) as? [String: Any] {
                if state["ready"] as? Bool == true { return }
                if state["settled"] as? Bool == true {
                    let errors = state["errors"] as? [[String: Any]] ?? []
                    throw RenderError.failed(errors.compactMap { $0["message"] as? String }.joined(separator: "；"))
                }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw RenderError.timeout
    }

    private static func document(_ body: String, image: Bool) -> String {
        let exportStyle = image ? "html,body{margin:0;padding:0;background:#fff;color:#222;}body{padding:12px;display:inline-block;width:max-content;font-size:18px;}body>.mn-math{display:inline-block;max-width:none;overflow:visible;margin:0;padding:0;}" : "html,body{background:#fff;color:#222;}"
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src data:;\">\(MathWebDocument.head())<style>\(exportStyle)</style></head><body>\(body)</body></html>"
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
