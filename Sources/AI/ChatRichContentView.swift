import SwiftUI
import WebKit
import AppKit

struct ChatRichContentView: View {
    let text: String
    var bodySize: CGFloat = 13
    @State private var height: CGFloat = 28
    @State private var error: String?
    @State private var showError = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ChatContentWebView(text: text, bodySize: bodySize, dark: colorScheme == .dark, height: $height, error: $error)
                .frame(maxWidth: .infinity).frame(height: max(20, height))
            HStack {
                if error != nil {
                    Button("公式显示失败：查看原因") { showError = true }.foregroundStyle(.orange)
                }
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: {
                    Label("复制原文", systemImage: "doc.on.doc")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .alert("公式显示失败", isPresented: $showError) { Button("知道了", role: .cancel) {} } message: {
            Text((error ?? "未知错误") + "\n公式源码已保留，可复制原文检查；没有改写公式含义。")
        }
    }
}

private struct ChatContentWebView: NSViewRepresentable {
    let text: String
    let bodySize: CGFloat
    let dark: Bool
    @Binding var height: CGFloat
    @Binding var error: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let proxy = MessageProxy()
        proxy.target = context.coordinator
        config.userContentController.add(proxy, name: "chatHeight")
        config.userContentController.add(proxy, name: "mathError")
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        context.coordinator.load(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if context.coordinator.source != text || context.coordinator.bodySize != bodySize { context.coordinator.load(webView) }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chatHeight")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mathError")
        webView.navigationDelegate = nil
    }

    final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(userContentController, didReceive: message) }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ChatContentWebView
        var source = ""
        var bodySize: CGFloat = 0
        var token = ""
        init(_ parent: ChatContentWebView) { self.parent = parent }
        func load(_ webView: WKWebView) {
            source = parent.text; bodySize = parent.bodySize; token = UUID().uuidString
            let bodyHTML = AITextToHTML.render(source)
            (webView as? PassthroughWebView)?.containsSurface = bodyHTML.contains("data-surface=")
            let current = token
            DispatchQueue.main.async { [weak self] in if self?.token == current { self?.parent.error = nil } }
            let script = """
            (function(){
              const report = () => {
                const rect = document.body.getBoundingClientRect();
                window.webkit.messageHandlers.chatHeight.postMessage({token:'\(token)',height:Math.ceil(rect.height)});
              };
              document.addEventListener('DOMContentLoaded', () => {
                new ResizeObserver(report).observe(document.body);
                document.fonts.ready.then(report); report();
              });
              window.addEventListener('resize',report);
              window.addEventListener('load',report);
            })();
            """
            let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src data:;">
            <style>\(WebNoteHTMLBridge.documentCSS)
            html,body{min-height:0!important;height:auto!important;overflow-x:hidden;}
            body{display:flow-root;margin:0;padding:0;font-size:\(bodySize)px;}
            body>p:first-child{margin-top:0;}body>p:last-child{margin-bottom:0;}
            table{min-width:100%;}svg{max-width:100%;height:auto;}
            </style>\(MathWebDocument.head())<script>\(script)</script>
            </head><body>\(bodyHTML)</body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "chatHeight", let values = message.body as? [String: Any], values["token"] as? String == token, let raw = values["height"] as? Double, raw.isFinite, raw > 0 {
                let next = CGFloat(ceil(raw))
                if abs(next - parent.height) > 1 { parent.height = next }
            } else if message.name == "mathError" {
                parent.error = (message.body as? [String: Any])?["message"] as? String ?? "离线公式渲染器加载失败"
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel); return
            }
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.error = "内容显示进程已退出，请重新打开本条对话。" }
    }
}
