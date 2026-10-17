import SwiftUI
import WebKit

/// 网页登录兜底。
///
/// **这是异常分支，不是主路径。** 正常登录完全走原生界面，一个网页都不会出现。
/// 只有在原生路子确实走不通时才启用它，例如：
/// - 小米要求的人机验证是**滑块**（原生弹窗里的图形验证码处理不了滑块）；
/// - 密码登录被反复拒绝，但换个环境（浏览器）就能过。
///
/// 此时把小米官方登录页原样呈现，让用户在那里用任何方式完成登录
/// （扫码、密码、短信、滑块都可以），我们再从这次会话里取回 Cookie。
///
/// 之所以敢这么做：这一步的用户目标已经从"用我们的界面登录"退化成
/// "无论如何先登进去"，此时可用性优先于视觉一致性。
@MainActor
final class WebFallbackSession: NSObject, ObservableObject {

    enum Phase: Equatable {
        case loading
        case ready              // 页面已就绪，等用户操作
        case loggedIn           // 已检测到回到 i.mi.com，登录成功
        case failed(String)

        var isBusy: Bool { self == .loading }
    }

    @Published private(set) var phase: Phase = .loading
    let webView: WKWebView

    /// 是否已经见过小米登录页。用它区分"从 i.mi.com 被踢去登录"与"登录成功回到 i.mi.com"。
    private var sawLoginPage = false

    override init() {
        let cfg = WKWebViewConfiguration()
        // **必须用 nonPersistent。**
        // `.default()` 会把 Cookie 落盘并跨启动保留，而「清除登录凭证」
        // （`CredentialsStore.clearCookie()`）只删 credentials.json，删不掉 WKWebView 里那份。
        // 后果：用户退出登录、换另一个账号再走网页兜底时，`collectCookie()` 会把
        // **上一个账号**的 serviceToken 取回来 —— 于是拉到别人的笔记，
        // 界面上完全看不出异常。
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    /// 从 i.mi.com 的笔记页进入，让小米自己决定要不要跳登录、跳到哪个登录页。
    func start() {
        guard let url = URL(string: "https://i.mi.com/note/h5") else { return }
        phase = .loading
        sawLoginPage = false
        webView.load(URLRequest(url: url))
    }

    /// 取回可用于 `MiAPI` 的 Cookie 请求头。
    ///
    /// 不依赖"检测到登录成功"——用户也可以自己点「我已完成登录」，
    /// 因为页面跳转的判定条件随小米改版会变，不该把成败押在它上面。
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

    /// 判断取回的 Cookie 里是否真的带上了可用凭证。
    ///
    /// 只看"有没有小米域的 Cookie"是不够的——被踢到登录页时也会有一堆账号域 Cookie。
    /// 真正能用的标志是出现 `serviceToken`（登录成功后才种下）。
    ///
    /// **逻辑本体已挪到 `MiLoginService`**：扫码与密码登录现在也要做同一判断，
    /// 方法留在本类只会变成第二份实现。这里只做转发，调用点不用改。
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

/// 内嵌 WKWebView。只在兜底弹窗里用。
struct WebFallbackWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 网页登录兜底面板。
///
/// **为什么需要它**：扫码登录最后一步是把服务端下发的签名 URL（`i.mi.com/sts?..._ssign`）
/// 原样请求来换 `serviceToken`。那个签名由服务端生成、且很可能绑定了我们看不到的因素，
/// 客户端一旦拿不到有效凭证就完全无解（实测原样请求仍回 401）。
/// 而 WKWebView 里是**真实浏览器会话**，小米自己的 JS 会完成包括签名在内的全部流程，
/// 我们只负责把这次会话里的 Cookie 取回来。
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
                        // 只认 serviceToken：被踢到登录页时也会有一堆账号域 Cookie，
                        // 那些看着"有 Cookie"但读不了笔记，放过去就是一次假登录。
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
