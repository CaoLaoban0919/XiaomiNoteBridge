import SwiftUI
import WebKit

@MainActor
final class WebFallbackSession: NSObject, ObservableObject {

    enum Phase: Equatable {
        case loading
        case ready
        case loggedIn
        case failed(String)

        var isBusy: Bool { self == .loading }
    }

    @Published private(set) var phase: Phase = .loading
    let webView: WKWebView

    private var sawLoginPage = false

    override init() {
        let cfg = WKWebViewConfiguration()

        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    func start() {
        guard let url = URL(string: "https://i.mi.com/note/h5") else { return }
        phase = .loading
        sawLoginPage = false
        webView.load(URLRequest(url: url))
    }

    func collectCookie() async -> String? {
        await withCheckedContinuation { cont in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let usable = cookies.filter { c in
                    let d = c.domain.lowercased()
                    return d.hasSuffix("mi.com") || d.hasSuffix("xiaomi.com")
                }
                guard !usable.isEmpty else { cont.resume(returning: nil); return }
                let header = usable
                    .sorted { $0.name < $1.name }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                cont.resume(returning: header.isEmpty ? nil : header)
            }
        }
    }

    static func hasUsableCredential(_ cookieHeader: String) -> Bool {
        MiLoginService.hasUsableCredential(cookieHeader)
    }
}

extension WebFallbackSession: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let host = webView.url?.host ?? ""
            if host.contains("xiaomi.com") {
                sawLoginPage = true
                phase = .ready
            } else if host.contains("mi.com") && sawLoginPage {
                phase = .loggedIn
            } else {
                phase = .ready
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                            didFailProvisionalNavigation navigation: WKNavigation!,
                            withError error: Error) {
        Task { @MainActor in
            phase = .failed(error.localizedDescription)
        }
    }
}

struct WebFallbackWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
struct WebFallbackSheet: View {
    let onFinish: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var web = WebFallbackSession()
    @State private var busy = false
    @State private var hint: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("在网页里登录小米账号").font(.headline)
                Spacer()
                Button("取消") { onCancel() }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)

            WebFallbackWebView(webView: web.webView)
                .frame(width: 560, height: 500)

            HStack(alignment: .center, spacing: DS.Space.m) {
                Text(hint ?? "扫码、密码、短信都可以。登录完成后点右边按钮。")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(hint == nil ? Color.secondary : DS.Status.bad)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.m)
                Button(busy ? "正在读取…" : "我已完成登录") {
                    busy = true
                    hint = nil
                    Task {
                        let cookie = await web.collectCookie() ?? ""
                        busy = false

                        guard MiLoginService.hasUsableCredential(cookie) else {
                            hint = "还没拿到能读取笔记的凭证。请确认网页里已经登录成功，再点一次。"
                            return
                        }
                        onFinish(cookie)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
        }
        .onAppear { web.start() }
    }
}
