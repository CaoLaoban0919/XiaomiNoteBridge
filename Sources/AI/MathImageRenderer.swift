import AppKit
import WebKit

/// 把 LaTeX 公式渲染成 PNG（data URL），供正文与 Apple Notes 使用。
///
/// 为什么不用 KaTeX 的 HTML 输出：它是一棵几十层嵌套的 `<span>` 树，
/// Apple Notes 导入 HTML 时会重新解析一遍，这棵树几乎必然被打散——
/// 用户看到的就是「σ∫α」这类残缺字符。图片是唯一稳的形态。
enum MathImageRenderer {

    /// 渲染一个公式。失败返回 nil，调用方保留原文。
    @MainActor
    static func renderPNG(_ latex: String, display: Bool) async -> String? {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let escaped = latex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let body = display ? "\\[\(escaped)\\]" : "\\(\(escaped)\\)"
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="katex/katex.min.css">
        <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        /* **中灰而不是黑。**
           截图是透明背景的 PNG，黑色文字在深色模式下等于隐形；
           纯白又在浅色模式下隐形。中灰是唯一两个模式都能读的颜色。 */
        body { display: inline-block; padding: 6px 10px; color: #8A8A8E; }
        .katex { font-size: \(display ? 18 : 15)px; color: inherit; }
        </style>
        <script src="katex/katex.min.js"></script>
        <script src="katex/auto-render.min.js"></script>
        <script>
        window.__ready = false;
        document.addEventListener('DOMContentLoaded', function() {
            try {
                renderMathInElement(document.body, {
                    delimiters: [
                        { left: '\\\\[', right: '\\\\]', display: true },
                        { left: '\\\\(', right: '\\\\)', display: false }
                    ],
                    throwOnError: false,
                    strict: false
                });
            } catch (e) {}
            window.__ready = true;
        });
        </script>
        </head><body>\(body)</body></html>
        """

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 400), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        _ = webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)

        // 等 KaTeX 完成（轮询 __ready，而不是死等固定时长）
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if let ready = try? await webView.evaluateJavaScript("window.__ready"),
               let flag = ready as? Bool, flag {
                break
            }
        }

        // 按内容实际尺寸截图
        let size: NSSize
        if let raw = try? await webView.evaluateJavaScript("""
            (function(){
                var r = document.body.getBoundingClientRect();
                return [Math.ceil(r.width), Math.ceil(r.height)];
            })()
            """) as? [NSNumber], raw.count == 2 {
            size = NSSize(width: max(1, raw[0].doubleValue), height: max(1, raw[1].doubleValue))
        } else {
            return nil
        }

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = NSRect(origin: .zero, size: size)
        snapshotConfig.snapshotWidth = NSNumber(value: Double(size.width))

        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: snapshotConfig) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// 扫描文本里成对的 `$$…$$`，渲染后替换成 `<img>`。
    ///
    /// 只处理块级公式（`$$`）。行内 `$` 太容易和金额、变量名撞车，
    /// 自动识别会误伤正文；行内公式保留原文，至少不会乱码。
    @MainActor
    static func replaceDisplayMath(in text: String) async -> String {
        var result = text
        while let start = result.range(of: "$$"),
              let end = result.range(of: "$$", range: start.upperBound..<result.endIndex) {
            let latex = String(result[start.upperBound..<end.lowerBound])
            guard let dataURL = await renderPNG(latex, display: true) else {
                // 渲染失败：跳过这一处，避免死循环
                let after = end.upperBound
                guard after < result.endIndex else { break }
                let rest = String(result[after...])
                let head = String(result[..<after]).replacingOccurrences(of: "$$", with: "")
                result = head + rest
                continue
            }
            let img = "<img src=\"\(dataURL)\" style=\"max-width:100%;max-height:140px;display:block;margin:8px 0;\">"
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: img)
        }
        return result
    }
}
