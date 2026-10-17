import Foundation
import CryptoKit
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
        // 不再套一层"无法解析的内容"：这个错误类型承载的是**任何**服务端异常，
        // 包括 401 认证失败、400 参数错误。统一加"解析失败"会把用户和后来的排查者
        // 一起带偏——401 根本不是解析问题。
        case .badResponse(let m): return m
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

    /// 剩余秒数，**只供界面显示**，夹在 0 以上。
    var remaining: Int { max(0, rawRemaining) }

    /// 未夹钳的剩余秒数（过期后为负）。
    ///
    /// 判定必须用它。用 `remaining` 会和 `max(0, …)` 互相抵消 ——
    /// `remaining` 永远 ≥ 0，`remaining < -15` 就永远为 false，
    /// 二维码会**永不过期**，遮罩也永不出现。
    var rawRemaining: Int { expiresIn - Int(age) }

    /// 是否过期。
    ///
    /// **刻意留 15 秒宽容**：长轮询的单请求超时比服务端的 `expiresIn` 宽，
    /// 那 15 秒里请求还活着、此刻扫码仍然可能成功。若一到 300 秒就判过期，
    /// 界面会先弹出"已过期"遮罩，而底下那次请求还在跑——用户会把这段
    /// 描述成"提示过期了但还能扫"，正好和这次排查的现象混在一起。
    /// 让请求结果有最终裁决权：只有超过 15 秒仍无结果才算真的过期。
    var isExpired: Bool { rawRemaining < -15 }
}

enum MiLoginOutcome: Equatable {
    /// 没有可交付的结果：还没扫码、服务端 hold 住、超时、或连接抖动。
    case waiting
    /// 登录成功
    case succeeded(cookie: String)
    /// 拿到了响应，但**不是我们认识的形状**（非 JSON、缺关键字段等）。
    ///
    /// 与 `.waiting` 分开纯粹是为了**可诊断**：
    /// `.waiting` = 服务端还没给结果；`.unexpected` = 给了但我们没认出来。
    /// 两者在界面上表现一样，但日志里必须能区分，否则永远分不清
    /// "用户没扫"还是"我们解析错了"——这一轮排查就是卡在这里。
    ///
    /// 注：原 `.scanned` 已删除。官方前端 chunk 里 `scan` 字段出现 **0 次**，
    /// 那个状态是凭想象加的，从未被任何一次实测观测到。
    case unexpected(String)
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
        // resource 必须比长轮询的请求超时更宽，否则会被它先杀掉。
        // 单次请求的超时在 `pollOnce` 里按服务端给的 `expiresIn` 单独设定（见那里）。
        cfg.timeoutIntervalForResource = 420
        return URLSession(configuration: cfg)
    }

    private static func request(_ url: URL, session: URLSession) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // **Referer 必须和请求目标同源。**
        // 原来一律写成 `https://account.xiaomi.com/`，但换票是打到 `i.mi.com` 的，
        // 跨域 Referer 会被部分端点直接判成无效请求（表现为 401/403）。
        let host = (url.host ?? "").lowercased()
        if host.hasSuffix("mi.com") && !host.hasPrefix("account.") && !host.contains(".account.") {
            r.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        } else {
            r.setValue("https://account.xiaomi.com/", forHTTPHeaderField: "Referer")
        }
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

            // 人机验证要**先判**：小米返回 captchaUrl 时也可能同时带 location，
            // 先看 location 会把"要求验证码"吞掉，变成一直报登录失败。
            if let captcha = obj["captchaUrl"] as? String, !captcha.isEmpty,
               let captchaURL = URL(string: captcha) {
                throw MiLoginError.captchaRequired(captchaURL)
            }

            // 出现 location 就代表凭据通过，跟着走一步把 serviceToken 种进 Cookie
            if let location = obj["location"] as? String, !location.isEmpty,
               let locURL = URL(string: location, relativeTo: URL(string: "https://account.xiaomi.com/")) {
                // 与扫码分支同样的道理：这一步才是真正换凭证的地方，
                // 吞掉错误 + 只看"cookie 非空"会把失败当成功上交。
                do {
                    let (_, resp) = try await session.data(for: request(locURL, session: session))
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw MiLoginError.badResponse(
                            "换取凭证失败：HTTP \(http.statusCode)（\(resp.url?.host ?? "?")）")
                    }
                } catch let e as MiLoginError {
                    throw e
                } catch {
                    throw MiLoginError.requestFailed("换取凭证失败：\(error.localizedDescription)")
                }
                let cookie = collectCookies(session: session)
                guard MiLoginService.hasUsableCredential(cookie) else {
                    throw MiLoginError.badResponse("凭据通过，但没拿到 serviceToken")
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
            // ═══════════════════════════════════════════════════════════
            // 二维码内容必须用 `loginUrl`，**不能用 `qr`**。
            //
            // 实测（2026-10-18）：
            //   qr       = https://account.xiaomi.com/pass/qr/login?ticket=…&_qrsize=240&_hasLogo=false&ts=…
            //   loginUrl = https://c3.account.xiaomi.com/longPolling/login?ticket=…&dc=c3&sid=i.mi.com&ts=…
            //
            // `qr` 是**渲染二维码图片的端点**（看那两个 `_qrsize` / `_hasLogo` 参数就知道），
            // 把它编码成二维码，手机扫出来得到的是"那张图片的地址"——小米 App 不认这个地址，
            // 于是永远不会回报"已扫码"，长轮询一直 hold 到超时。
            // 用户看到的就是"二维码能显示，但扫了完全没反应"。
            //
            // 佐证（已复现）：把 `qr` 指向的 PNG 下载下来再解码其中的二维码，
            // 得到的字符串与 `loginUrl` 逐字节相同。
            // ═══════════════════════════════════════════════════════════
            guard let loginUrl = obj["loginUrl"] as? String, !loginUrl.isEmpty else {
                throw MiLoginError.badResponse(
                    "缺少 loginUrl 字段（\(obj["desc"] as? String ?? obj["description"] as? String ?? "无说明")）")
            }
            guard let lp = obj["lp"] as? String, let lpURL = URL(string: lp) else {
                throw MiLoginError.badResponse("缺少 lp 字段")
            }
            let timeout = (obj["timeout"] as? Int) ?? 300
            return (MiQRSession(content: loginUrl, pollURL: lpURL,
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
            // 长轮询的超时跟着**服务端给的 `expiresIn`** 走（实测 300 秒）。
            // 沿用 session 的 45 秒会让客户端在服务端还 hold 着的时候抢先掐断，
            // 然后重连——而"重连"是这条链路上最容易出事的动作：
            // 真机日志显示第一次 poll 在 45.97 秒断开后，轮询就再没起来过。
            // 扫码成功后服务端会立即返回，所以拉长超时不会拖慢成功路径。
            var pollRequest = request(qr.pollURL, session: session)
            // 官方长轮询是 315 秒（300 + 15）。用 315 而不是随意放大：
            // 比服务端宽一点即可，过宽会让"连接已死"这件事拖到几分钟后才发现。
            pollRequest.timeoutInterval = TimeInterval(max(90, qr.expiresIn + 15))
            let (data, resp) = try await session.data(for: pollRequest)
            guard let http = resp as? HTTPURLResponse else {
                throw MiLoginError.badResponse("无 HTTP 响应")
            }
            // 这些都是"服务端暂时没给结果"，不该当成登录失败：
            //   408 / 504 —— 长轮询超时；
            //   403 / 429 —— 限流（login-probe 实测：对同一 ticket 连打十几条就会触发）；
            //   5xx       —— 服务端抖动。
            // 一律回 `.waiting` 让上层退避重试，**连续多次**才判失败（计数在视图层）。
            // 早先这里直接抛错，于是 45s 强制断连后的第一次重连只要撞上任意一个
            // 非 2xx，整轮轮询就永久停摆 —— 而用户看到的现象只是"扫了没反应"。
            if http.statusCode == 408 || http.statusCode == 504 {
                return .waiting
            }
            if http.statusCode == 403 || http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                // **只在服务端明确给了 `Retry-After` 时才睡。**
                // 给默认值等于客户端自选节流，会和视图层那条"快速返回就退避"叠加成两层相加；
                // 没有这个头就不睡，交由视图层按本轮耗时判断。
                // 日期形式的 `Retry-After` 不解析（解析失败即视为没有），避免引入时区逻辑。
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                if let raw = retryAfter, let seconds = Double(raw) {
                    let clamped = min(max(seconds, 0.5), 5.0)
                    try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                }
                LoginTrace.log("LP 可重试状态码 \(http.statusCode) retry-after=\(retryAfter ?? "-")")
                return .waiting
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MiLoginError.requestFailed("HTTP \(http.statusCode)")
            }
            let jsonData = stripPrefix(data)
            guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                // 返回 `.unexpected` 而不是 `.waiting`：控制流上两者都继续轮询，
                // 但类型上把"给了但没认出来"标出来，日志才有区分度。
                let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
                // 正文摘要走**十六进制**，不走文本解码。
                // 代理/劫持页常是 GBK 或混合编码，按 UTF-8 解码会得到空串，
                // 而这行是 `.unexpected` 唯一的排查信息源。hex 对任何编码都成立，
                // 也不会把响应体里的明文写进日志文件。
                let head = jsonData.prefix(32).map { String(format: "%02x", $0) }.joined()
                LoginTrace.log("LP 非 JSON 头 32 字节：\(head)")
                return .unexpected("非 JSON（ct=\(ct)，\(jsonData.count) 字节）")
            }

            // **location 必须排在 code 之前判。**
            // `code` 是通用状态字段，长轮询成功时响应里也可能带非 0 值；
            // 先判 code 会把一次成功直接判成"票据失效"。
            //
            // 顺手把响应里有哪些 key 打出来（只打 key，不打值）：
            // 换票可能还需要 `pwd` / `child` 这类字段，而我们从没检查过它们是否存在。
            LoginTrace.log("lp 响应字段：\(obj.keys.sorted().joined(separator: ","))")
            if let location = obj["location"] as? String, !location.isEmpty {
                // **在原始字符串上追加参数，绝不用 URLComponents 重建整个 URL。**
                //
                // 重建会把所有 query 重新解析一遍再重编码：ticket 里的 `+`、`%2B`、
                // base64 补位 `=` 都可能被改写。服务端认不出 ticket 就回 401，
                // 而这看起来像"认证失败"，几乎不可能联想到是我们自己把 URL 弄坏了。
                // 上一版正是踩了这个坑。
                var finalLocation = location

                // 部分 sid 要求 `clientSign`：base64(sha1("nonce=<nonce>&<ssecurity>"))。
                // 两个字段都在长轮询成功响应里；没有就不加，保持 URL 原样。
                if let nonce = obj["nonce"] as? String, !nonce.isEmpty,
                   let ssecurity = obj["ssecurity"] as? String, !ssecurity.isEmpty {
                    let raw = "nonce=\(nonce)&\(ssecurity)"
                    let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
                    let sign = Data(digest).base64EncodedString()
                    // 只编码签名本身：base64 的 `+` `/` `=` 在 query 里必须转义
                    let encoded = sign.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sign
                    finalLocation += (location.contains("?") ? "&" : "?") + "clientSign=" + encoded
                    LoginTrace.log("location 已补 clientSign（nonce 长度 \(nonce.count)）")
                } else {
                    LoginTrace.log("location 未带 nonce/ssecurity，不补 clientSign")
                }

                // **把 query 里的裸 `+` 编码成 `%2B`，必须在解析 URL 之前做。**
                //
                // 这段 location 是服务端签好名的自包含 URL（`ticket=0` 只是占位，
                // 真正的认证靠 `nonce` + `_ssign`）。`_ssign` 是 base64，天然含 `+`；
                // 而 `+` 在 query 里会被按 form-urlencoded 解析成**空格**，
                // 签名一变形认证就失败——服务端回的是 **401**（认证层拒绝）而不是 400，
                // 所以从错误码完全看不出是编码问题。
                //
                // 已存在的 `%2B` 先占位保护，避免二次编码成 `%252B`。
                let rawQuery = location.split(separator: "?", maxSplits: 1).last.map(String.init) ?? ""
                if rawQuery.contains("+") {
                    var query = rawQuery
                    let marker = "\u{1}P\u{1}"
                    query = query.replacingOccurrences(of: "%2B", with: marker)
                    query = query.replacingOccurrences(of: "+", with: "%2B")
                    query = query.replacingOccurrences(of: marker, with: "%2B")
                    if let qMark = finalLocation.firstIndex(of: "?") {
                        finalLocation = String(finalLocation[..<qMark]) + "?" + query
                    }
                    LoginTrace.log("location 的 query 含裸加号，已按 %2B 重新编码")
                }

                let ssign = rawQuery.split(separator: "&")
                    .first { $0.hasPrefix("_ssign=") }
                    .map { String($0.dropFirst("_ssign=".count)) } ?? ""
                LoginTrace.log("query 诊断：裸加号=\(rawQuery.contains("+")) "
                               + "已编码=\(rawQuery.contains("%2B")) _ssign长度=\(ssign.count)")

                guard var locURL = URL(string: finalLocation,
                                       relativeTo: URL(string: "https://account.xiaomi.com/")) else {
                    throw MiLoginError.badResponse("登录已确认，但 location 无法解析")
                }

                // **诊断每个参数值的长度，并补齐空占位。**
                //
                // `ticket=0` 这个值不像真实票据，更像服务端下发的**模板占位**。
                // 如果 `pwd` / `auth` / `m` 这类参数是空的、需要客户端用 `lp` 响应里的
                // 同名字段填进去，那 `_ssign` 覆盖的就是一份缺参数的请求——
                // 验签必然失败，服务端只能回 401（而且空 body，因为是认证层拒绝）。
                if let comps0 = URLComponents(url: locURL, resolvingAgainstBaseURL: false) {
                    let summary = (comps0.queryItems ?? [])
                        .map { "\($0.name):\($0.value?.count ?? 0)" }
                        .joined(separator: ",")
                    LoginTrace.log("location 参数长度：\(summary)")

                    var items = comps0.queryItems ?? []
                    var filled: [String] = []
                    for i in items.indices where (items[i].value ?? "").isEmpty {
                        if let v = obj[items[i].name] as? String, !v.isEmpty {
                            items[i].value = v
                            filled.append("\(items[i].name)(\(v.count))")
                        }
                    }
                    if !filled.isEmpty {
                        var c = comps0
                        c.queryItems = items
                        if let fixed = c.url {
                            locURL = fixed
                            LoginTrace.log("location 空参数已用 lp 响应补齐：\(filled.joined(separator: ","))")
                        }
                    }
                }

                // **撤回"手动拼 Cookie"的尝试。**
                // 日志已证明 `passToken` 的域是 `account.xiaomi.com`（host-only），
                // 把它塞进发往 `i.mi.com` 的请求属于**越权发送**：
                // 服务端看到不属于该域的凭证，只会判 401。
                // cookie 该由 URLSession 按域自动决定带哪些，不该我们替它决定。
                let jar = (session.configuration.httpCookieStorage?.cookies ?? [])
                LoginTrace.log("换票前 cookie：" + jar.map { "\($0.name)@\($0.domain)" }
                    .sorted().joined(separator: ","))

                // **诊断 location 的结构**——这才是现在唯一没看清的东西：
                // ticket 到底在不在、有没有被编码搞坏（`+` 与 `%2B` 的差别足以让票作废）。
                // 只打 key 列表和 ticket 的长度/特征，不打 ticket 全文。
                let comps = URLComponents(url: locURL, resolvingAgainstBaseURL: false)
                let keys = (comps?.queryItems ?? []).map(\.name).joined(separator: ",")
                let ticket = comps?.queryItems?.first(where: { $0.name == "ticket" })?.value ?? ""
                LoginTrace.log("location 结构：keys=[\(keys)] ticket长度=\(ticket.count) "
                               + "含加号=\(ticket.contains("+")) 前6=\(String(ticket.prefix(6)))")
                LoginTrace.log("LP 命中 location，host=\(locURL.host ?? "?") path=\(locURL.path)")

                let ticketRequest = request(locURL, session: session)
                // **不能吞这个错误。** 跟随 location 那一步才是真正种 serviceToken 的地方；
                // 它失败时 Cookie 里只剩无关的账号域 cookie，`!cookie.isEmpty` 照样为真，
                // 于是一个"什么都没拿到"的结果会被当成登录成功往上送。
                do {
                    let (respData, resp) = try await session.data(for: ticketRequest)
                    // 必须校验状态码：实测 `i.mi.com/sts` 在参数不对时返回 **HTTP 400**，
                    // 不检查的话会被后面的凭证判定收口成"没拿到 serviceToken"，
                    // 把一次参数错误误诊成别的原因。
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // 把响应体开头也记下来（hex，对编码不敏感、不落明文）：
                        // 如果补了 clientSign 仍然 400，这行就是唯一的线索。
                        let bodyHead = respData.prefix(120).map { String(format: "%02x", $0) }.joined()
                        LoginTrace.log("换票失败：HTTP \(http.statusCode) host=\(locURL.host ?? "?") "
                                       + "path=\(locURL.path) body=\(bodyHead)")
                        throw MiLoginError.badResponse(
                            "登录已确认，但换取凭证失败：HTTP \(http.statusCode)（\(locURL.host ?? "?")）")
                    }
                } catch let e as MiLoginError {
                    throw e
                } catch {
                    throw MiLoginError.requestFailed("登录已确认，但换取凭证失败：\(error.localizedDescription)")
                }
                let cookie = collectCookies(session: session)
                // 用凭证判定收口，而不是 `!cookie.isEmpty`：后者对整个 account.xiaomi.com
                // 域的任何 cookie 都成立，包括登录页自己种下的那些
                guard MiLoginService.hasUsableCredential(cookie) else {
                    // 不写"可能被风控拦截"这类猜测：把一次普通的换票失败归因到风控，
                    // 会让用户去换网络、换设备，而真正该做的是重试或看状态码。
                    throw MiLoginError.badResponse("登录已确认，但没拿到 serviceToken")
                }
                return .succeeded(cookie: cookie)
            }

            // 没有 location 才轮到 code。官方长轮询对**任何** `code != 0` 都直接结束
            // （源码里 `C = 1`，`w++` 之后 `w < C` 恒为 false，那个"重试一次"的分支是死代码；
            // 70031 只是它点名的那一个）。照做，别带着作废的 ticket 干等到本地超时。
            // `code` 有时是数字、有时是字符串（`"70031"`），两种都收。
            if let raw = obj["code"] {
                let code = (raw as? Int) ?? Int((raw as? String) ?? "") ?? 0
                if code != 0 {
                    let desc = (obj["desc"] as? String) ?? (obj["description"] as? String) ?? ""
                    LoginTrace.log("LP code=\(code) desc=\(desc) → 判为票据失效")
                    throw MiLoginError.expired
                }
            }

            // 既没有 location、也没有非 0 的 code —— 服务端还没给结果。
            // 注意：这里**不再**判 `scan` 字段。官方前端 chunk 里 `scan` 出现 0 次，
            // 那个字段不存在；原来那段 `if let scanned ... return .scanned` 是凭想象写的。
            return .waiting
        } catch let e as MiLoginError {
            throw e
        } catch {
            let ns = error as NSError
            // **URL 层的错误一律可重试。**
            // 长轮询是一条持续五分钟的连接，中途瞬断、DNS 抖动、代理重置、
            // TLS 重协商失败都是常态。早先只白名单三种错误码，其余（-1009 断网、
            // DNS 失败、-999 取消等）会直接 throw，上层 catch 里把轮询 `return` 掉——
            // 一次抖动就永久停摆，用户看到的现象只是"扫了没反应"。
            // 现在全部回 `.waiting` 继续轮询；真正该放弃的是连续失败，由视图层计数。
            if ns.domain == NSURLErrorDomain {
                LoginTrace.log("LP 网络错误（可重试）：\(ns.code) \(ns.localizedDescription)")
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

    // MARK: - 凭证判定

    /// 判断 Cookie 请求头里是否真的带上了可用凭证。
    ///
    /// **这是三条登录路径（扫码 / 密码 / 网页兜底）共用的唯一一份判断逻辑。**
    ///
    /// 只看"有没有小米域的 Cookie"是不够的：被踢到登录页、或密码校验失败时，
    /// 浏览器同样会种下一堆 `account.xiaomi.com` 域的 Cookie，但那些读不了笔记。
    /// 真正可用的标志是出现 `serviceToken`（登录成功后由 `i.mi.com/sts` 种下）
    /// 或 `passToken`。
    ///
    /// 实现上有两处刻意避开"看着能用、实际不能用"的坑：
    /// - 按 Cookie 名逐段比对，而不是 `contains("serviceToken=")` 这种子串匹配——
    ///   后者会被 `xsrfToken=xserviceToken=foo` 这类值误命中；
    /// - **值也必须非空**。`serviceToken=`（值为空）同样读不到笔记，
    ///   只认名字会让这种残留凭证蒙混过关。
    static func hasUsableCredential(_ cookieHeader: String) -> Bool {
        credentialQuality(cookieHeader) != .none
    }

    /// 凭证的可用程度。只有 `.serviceToken` 能读笔记。
    ///
    /// 分三态而不是 Bool，是因为 `passToken` 与 `serviceToken` 的**含义完全不同**：
    /// 前者只代表"这台设备记住了账号"，后者才是"能读数据的通行证"。
    /// 把它们合并成一个 Bool，会让调用方在网络异常时无法区分"该放行"还是"该拒绝"——
    /// 这正是最后一条假成功路径的来源。
    enum CredentialQuality: Equatable {
        /// 带 serviceToken，可直接读笔记
        case serviceToken
        /// 只有 passToken：账号记住了，但还没换到读笔记的凭证
        case passTokenOnly
        /// 两样都没有
        case none
    }

    static func credentialQuality(_ cookieHeader: String) -> CredentialQuality {
        var hasService = false
        var hasPass = false
        for part in cookieHeader.split(separator: ";") {
            // Cookie 值本身可能含 `=`（base64 padding），所以只取**第一个**等号作分隔
            guard let eq = part.firstIndex(of: "=") else { continue }
            let name = part[part.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            // **值必须非空**：`serviceToken=` 同样读不到笔记
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if name == "serviceToken" { hasService = true }
            if name == "passToken" { hasPass = true }
        }
        if hasService { return .serviceToken }
        if hasPass { return .passTokenOnly }
        return .none
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
