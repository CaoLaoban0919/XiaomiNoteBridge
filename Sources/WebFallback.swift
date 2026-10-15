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
        cfg.websiteDataStore = .default()
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
    /// 这个判断放在这里而不是散在视图里，是为了只存在一份逻辑。
    static func hasUsableCredential(_ cookieHeader: String) -> Bool {
        cookieHeader.contains("serviceToken=") || cookieHeader.contains("passToken=")
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
