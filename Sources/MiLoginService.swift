import Foundation
import AppKit
import CryptoKit
import CoreImage
import CoreImage.CIFilterBuiltins

// 小米账号登录。**全程不使用浏览器**——这是刻意的设计约束。
//
// 之所以能做到：小米的扫码登录走的是独立 HTTP 接口，不是页面内嵌逻辑。
// 实测（2026-10-14）：
//   GET https://account.xiaomi.com/longPolling/loginUrl?sid=i.mi.com&_qrsize=240&_json=true
//   → {"qr":"https://account.xiaomi.com/pass/qr/login?ticket=…",     ← 二维码内容
//      "lp":"https://ak.lp.account.xiaomi.com/lp/s?k=lp_…",           ← 长轮询地址
//      "timeout":300}
// 拿到 qr 内容后用 CoreImage 原生生成二维码，拿到 lp 后长轮询等用户扫码。
// 整个过程中应用内不出现任何网页，视觉风格完全统一。

enum MiLoginError: LocalizedError {
    case requestFailed(String)
    case badResponse(String)
    case expired
    case cancelled
    case unsupported(String)
    /// 小米要求先完成人机验证。
    ///
    /// 关联值是验证码图片的地址。**必须用同一次登录会话去取这张图**——
    /// 验证码是绑定在会话上的，换个会话取到的图对不上。
    case captchaRequired(URL)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let m): return "无法连接小米登录服务：\(m)"
        case .badResponse(let m): return "小米登录服务返回了无法解析的内容：\(m)"
        case .expired: return "二维码已过期，请刷新后重试。"
        case .cancelled: return "登录已取消。"
        case .unsupported(let m): return m
        case .captchaRequired: return "小米要求先完成人机验证。"
        }
    }
}

/// 一次扫码会话
struct MiQRSession: Equatable {
    /// 二维码里编码的内容
    var content: String
    /// 长轮询地址
    var pollURL: URL
    /// 服务端给的超时秒数
    var expiresIn: Int
    var createdAt: Date

    var age: TimeInterval { Date().timeIntervalSince(createdAt) }
    var remaining: Int { max(0, expiresIn - Int(age)) }
    var isExpired: Bool { remaining <= 0 }
}

enum MiLoginOutcome: Equatable {
    /// 尚未扫码
    case waiting
    /// 已扫码，等待手机上确认
    case scanned
    /// 登录成功
    case succeeded(cookie: String)
}

enum MiLoginService {

    /// 小米云服务的 sid
    private static let sid = "i.mi.com"

    /// 小米官方的用户协议与隐私政策。
    ///
    /// 这两个地址是从小米登录页的 `<a href>` 里原样取出来的（2026-10-14），
    /// **我们不在本地复制或改写协议内容**，只提供链接，点开由系统浏览器打开小米官网原文。
    /// 这样既尊重小米的用户须知，也不会因为转述而产生偏差。
    static let agreementURL = URL(string: "https://account.xiaomi.com/about/protocol/agreement?_locale=zh_CN")!
    static let privacyURL = URL(string: "https://account.xiaomi.com/about/protocol/privacy?_locale=zh_CN")!

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// 每个会话一套独立的 Cookie 存储，不污染系统共享 Cookie
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }

    private static func request(_ url: URL, session: URLSession) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("https://account.xiaomi.com/", forHTTPHeaderField: "Referer")
        return r
    }

    /// 小米的 JSON 接口常带 `&&&START&&&` 前缀
    private static func stripPrefix(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) else { return data }
        if let r = s.range(of: "&&&START&&&") {
            let json = String(s[r.upperBound...])
            return Data(json.utf8)
        }
        return data
    }

    // MARK: - 密码登录

    /// `serviceLogin` 返回的登录凭据参数，后续所有登录请求都要原样带上。
    /// 它们由小米服务端签发，我们只做透传，不解析也不改。
    struct LoginParams {
        var qs: String
        var sign: String
        var callback: String
        var sid: String
    }

    /// 取一次登录凭据参数。密码登录与扫码登录都要先走这一步。
    static func fetchLoginParams(session: URLSession = makeSession()) async throws -> (LoginParams, URLSession) {
        var comps = URLComponents(string: "https://account.xiaomi.com/pass/serviceLogin")!
        comps.queryItems = [
            .init(name: "sid", value: sid),
            .init(name: "_json", value: "true"),
        ]
        do {
            let (data, _) = try await session.data(for: request(comps.url!, session: session))
            let jsonData = stripPrefix(data)
            guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw MiLoginError.badResponse("serviceLogin 不是合法 JSON")
            }
            guard let qsVal = obj["qs"] as? String,
                  let signVal = obj["_sign"] as? String,
                  let cbVal = obj["callback"] as? String
            else {
                throw MiLoginError.badResponse("serviceLogin 缺少必需参数")
            }
            let params = LoginParams(qs: qsVal, sign: signVal,
                                     callback: cbVal, sid: (obj["sid"] as? String) ?? sid)
            return (params, session)
        } catch let e as MiLoginError {
            throw e
        } catch {
            throw MiLoginError.requestFailed(error.localizedDescription)
        }
    }

    /// 密码登录。
    ///
    /// **密码本身不会被保存，也不会离开这个函数。** 小米要求提交的是
    /// `MD5(密码)` 的大写十六进制，所以密码只在内存里存在到算完哈希为止；
    /// 调用方（界面）在登录结束后应立即清空输入框。
    ///
    /// - Parameter captchaCode: 上一次返回 `captchaRequired` 时，用户看图填的字符。
    ///   首次尝试传 nil。**重试必须复用同一个 `session` 与 `params`**，
    ///   否则验证码对不上。
    /// - Returns: 可直接用于 `MiAPI` 的 Cookie 请求头
    static func loginWithPassword(user: String,
                                  password: String,
                                  params: LoginParams,
                                  session: URLSession,
                                  captchaCode: String? = nil) async throws -> String {
        let hash = Insecure.MD5.hash(data: Data(password.utf8))
            .map { String(format: "%02X", $0) }.joined()

        var fields = [
            "user=" + formEncode(user),
            "hash=" + hash,
            "sid=" + formEncode(params.sid),
            "_sign=" + formEncode(params.sign),
            "qs=" + formEncode(params.qs),
            "callback=" + formEncode(params.callback),
            "_json=true",
        ]
        if let captchaCode, !captchaCode.isEmpty {
            fields.append("captchaCode=" + formEncode(captchaCode))
        }
        let body = fields.joined(separator: "&")

        var req = URLRequest(url: URL(string: "https://account.xiaomi.com/pass/serviceLoginAuth2")!)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://account.xiaomi.com", forHTTPHeaderField: "Origin")
        req.setValue("https://account.xiaomi.com/", forHTTPHeaderField: "Referer")

        do {
            let (data, _) = try await session.data(for: req)
            let jsonData = stripPrefix(data)
            guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw MiLoginError.badResponse("登录响应不是合法 JSON")
            }

            // 出现 location 就代表凭据通过，跟着走一步把 serviceToken 种进 Cookie
            if let location = obj["location"] as? String, !location.isEmpty,
               let locURL = URL(string: location) {
                _ = try? await session.data(for: request(locURL, session: session))
                let cookie = collectCookies(session: session)
                guard !cookie.isEmpty else {
                    throw MiLoginError.badResponse("凭据通过但没有拿到 Cookie")
                }
                return cookie
            }

            // 没有 location 就是失败：把小米给的说明原样带出来，不要自己编
            let desc = (obj["desc"] as? String) ?? (obj["description"] as? String) ?? "登录失败"
            let code = (obj["code"] as? Int) ?? -1

            // 小米要求人机验证：把验证码图片地址带出去，由界面弹窗让用户看图填写
            if let captcha = obj["captchaUrl"] as? String, !captcha.isEmpty,
               let captchaURL = URL(string: captcha) {
                throw MiLoginError.captchaRequired(captchaURL)
            }

            switch code {
            case 70016:
                throw MiLoginError.unsupported("账号或密码不正确。")
            case 70003, 70005:
                throw MiLoginError.unsupported("小米要求进行安全验证，请在小米官网登录后再重试。")
            default:
                throw MiLoginError.unsupported("登录失败（\(code)）：\(desc)")
            }
        } catch let e as MiLoginError {
            throw e
        } catch {
            throw MiLoginError.requestFailed(error.localizedDescription)
        }
    }

    /// 取人机验证的图片。
    ///
    /// 必须复用**同一次登录会话**的 `session`：验证码是绑定在会话上的，
    /// 换一个 session 取回来的图，填对了服务端也不认。
    static func fetchCaptchaImage(_ url: URL, session: URLSession) async -> NSImage? {
        guard let (data, _) = try? await session.data(for: request(url, session: session)) else {
            return nil
        }
        return NSImage(data: data)
    }

    /// 表单值编码。
    /// 注意 `qs` 与 `_sign` 本身已经是百分号编码过的字符串，**仍然要再编一次**——
    /// 小米的接口接受这种双重编码（已实测），原样透传反而会因其中的 `=` 与 `&` 破坏表单结构。
    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - 申请二维码

    static func requestQRCode(session: URLSession = makeSession()) async throws -> (MiQRSession, URLSession) {
        var comps = URLComponents(string: "https://account.xiaomi.com/longPolling/loginUrl")!
        comps.queryItems = [
            .init(name: "sid", value: sid),
            .init(name: "_qrsize", value: "240"),
            .init(name: "_json", value: "true"),
            .init(name: "_locale", value: "zh_CN"),
        ]
        do {
            let (data, resp) = try await session.data(for: request(comps.url!, session: session))
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw MiLoginError.requestFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let jsonData = stripPrefix(data)
            guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw MiLoginError.badResponse("不是合法 JSON")
            }
            guard let qr = obj["qr"] as? String, !qr.isEmpty else {
                throw MiLoginError.badResponse("缺少 qr 字段（\(obj["description"] as? String ?? "无说明")）")
            }
            guard let lp = obj["lp"] as? String, let lpURL = URL(string: lp) else {
                throw MiLoginError.badResponse("缺少 lp 字段")
            }
            let timeout = (obj["timeout"] as? Int) ?? 300
            return (MiQRSession(content: qr, pollURL: lpURL,
                                expiresIn: timeout, createdAt: Date()), session)
        } catch let e as MiLoginError {
            throw e
        } catch {
            throw MiLoginError.requestFailed(error.localizedDescription)
        }
    }

    // MARK: - 长轮询

    /// 轮询一次。服务端会 hold 住连接直到状态变化或超时。
    /// 连接超时是**正常现象**，代表"还没人扫码"，返回 `.waiting` 让调用方继续轮询。
    static func pollOnce(_ qr: MiQRSession, session: URLSession) async throws -> MiLoginOutcome {
        do {
            let (data, resp) = try await session.data(for: request(qr.pollURL, session: session))
            guard let http = resp as? HTTPURLResponse else {
                throw MiLoginError.badResponse("无 HTTP 响应")
            }
            if http.statusCode == 408 || http.statusCode == 504 {
                return .waiting
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MiLoginError.requestFailed("HTTP \(http.statusCode)")
            }
            let jsonData = stripPrefix(data)
            guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return .waiting
            }

            // 已扫码但未确认：小米会给出非 0 的 code 且没有 location
            if let location = obj["location"] as? String, let locURL = URL(string: location), !location.isEmpty {
                // 跟着 location 走完最后一步，让它把 serviceToken 种进 Cookie
                _ = try? await session.data(for: request(locURL, session: session))
                let cookie = collectCookies(session: session)
                guard !cookie.isEmpty else {
                    throw MiLoginError.badResponse("登录成功但没有拿到 Cookie")
                }
                return .succeeded(cookie: cookie)
            }
            if let scanned = obj["scan"] as? Bool, scanned {
                return .scanned
            }
            return .scanned
        } catch let e as MiLoginError {
            throw e
        } catch {
            // 超时按"还没扫"处理，让上层继续轮询
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain,
               [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost]
                   .contains(ns.code) {
                return .waiting
            }
            throw MiLoginError.requestFailed(error.localizedDescription)
        }
    }

    /// 收集小米域的 Cookie，拼成请求头
    static func collectCookies(session: URLSession) -> String {
        guard let store = session.configuration.httpCookieStorage else { return "" }
        let usable = (store.cookies ?? []).filter { c in
            let d = c.domain.lowercased()
            return d.hasSuffix("mi.com") || d.hasSuffix("xiaomi.com")
        }
        return usable
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    // MARK: - 原生二维码

    /// 用 CoreImage 原生生成二维码图像。
    /// 不下载小米返回的那张 240×240 PNG，是为了清晰度——矢量式生成在 Retina 屏上不会发虚。
    static func qrImage(for content: String, scale: CGFloat = 12) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: transformed.extent.width,
                                                 height: transformed.extent.height))
    }
}
