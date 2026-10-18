import Foundation
import CryptoKit
import AppKit
import CryptoKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum MiLoginError: LocalizedError {
    case requestFailed(String)
    case badResponse(String)
    case expired
    case cancelled
    case unsupported(String)

    case captchaRequired(URL)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let m): return "无法连接小米登录服务：\(m)"

        case .badResponse(let m): return m
        case .expired: return "二维码已过期，请刷新后重试。"
        case .cancelled: return "登录已取消。"
        case .unsupported(let m): return m
        case .captchaRequired: return "小米要求先完成人机验证。"
        }
    }
}

struct MiQRSession: Equatable {

    var content: String

    var pollURL: URL

    var expiresIn: Int
    var createdAt: Date

    var age: TimeInterval { Date().timeIntervalSince(createdAt) }

    var remaining: Int { max(0, rawRemaining) }

    var rawRemaining: Int { expiresIn - Int(age) }

    var isExpired: Bool { rawRemaining < -15 }
}

enum MiLoginOutcome: Equatable {

    case waiting

    case succeeded(cookie: String)

    case unexpected(String)
}

enum MiLoginService {

    private static let sid = "i.mi.com"

    static let agreementURL = URL(string: "https://account.xiaomi.com/about/protocol/agreement?_locale=zh_CN")!
    static let privacyURL = URL(string: "https://account.xiaomi.com/about/protocol/privacy?_locale=zh_CN")!

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 45

        cfg.timeoutIntervalForResource = 420
        return URLSession(configuration: cfg)
    }

    private static func request(_ url: URL, session: URLSession) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let host = (url.host ?? "").lowercased()
        if host.hasSuffix("mi.com") && !host.hasPrefix("account.") && !host.contains(".account.") {
            r.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        } else {
            r.setValue("https://account.xiaomi.com/", forHTTPHeaderField: "Referer")
        }
        return r
    }

    private static func stripPrefix(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) else { return data }
        if let r = s.range(of: "&&&START&&&") {
            let json = String(s[r.upperBound...])
            return Data(json.utf8)
        }
        return data
    }

    struct LoginParams {
        var qs: String
        var sign: String
        var callback: String
        var sid: String
    }

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

            if let captcha = obj["captchaUrl"] as? String, !captcha.isEmpty,
               let captchaURL = URL(string: captcha) {
                throw MiLoginError.captchaRequired(captchaURL)
            }

            if let location = obj["location"] as? String, !location.isEmpty,
               let locURL = URL(string: location, relativeTo: URL(string: "https://account.xiaomi.com/")) {

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

            let desc = (obj["desc"] as? String) ?? (obj["description"] as? String) ?? "登录失败"
            let code = (obj["code"] as? Int) ?? -1

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

    static func fetchCaptchaImage(_ url: URL, session: URLSession) async -> NSImage? {
        guard let (data, _) = try? await session.data(for: request(url, session: session)) else {
            return nil
        }
        return NSImage(data: data)
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

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

    static func pollOnce(_ qr: MiQRSession, session: URLSession) async throws -> MiLoginOutcome {
        do {

            var pollRequest = request(qr.pollURL, session: session)

            pollRequest.timeoutInterval = TimeInterval(max(90, qr.expiresIn + 15))
            let (data, resp) = try await session.data(for: pollRequest)
            guard let http = resp as? HTTPURLResponse else {
                throw MiLoginError.badResponse("无 HTTP 响应")
            }

            if http.statusCode == 408 || http.statusCode == 504 {
                return .waiting
            }
            if http.statusCode == 403 || http.statusCode == 429 || (500..<600).contains(http.statusCode) {

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

                let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "?"

                let head = jsonData.prefix(32).map { String(format: "%02x", $0) }.joined()
                LoginTrace.log("LP 非 JSON 头 32 字节：\(head)")
                return .unexpected("非 JSON（ct=\(ct)，\(jsonData.count) 字节）")
            }

            LoginTrace.log("lp 响应字段：\(obj.keys.sorted().joined(separator: ","))")
            if let location = obj["location"] as? String, !location.isEmpty {

                var finalLocation = location

                if let nonce = obj["nonce"] as? String, !nonce.isEmpty,
                   let ssecurity = obj["ssecurity"] as? String, !ssecurity.isEmpty {
                    let raw = "nonce=\(nonce)&\(ssecurity)"
                    let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
                    let sign = Data(digest).base64EncodedString()

                    let encoded = sign.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sign
                    finalLocation += (location.contains("?") ? "&" : "?") + "clientSign=" + encoded
                    LoginTrace.log("location 已补 clientSign（nonce 长度 \(nonce.count)）")
                } else {
                    LoginTrace.log("location 未带 nonce/ssecurity，不补 clientSign")
                }

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

                let jar = (session.configuration.httpCookieStorage?.cookies ?? [])
                LoginTrace.log("换票前 cookie：" + jar.map { "\($0.name)@\($0.domain)" }
                    .sorted().joined(separator: ","))

                let comps = URLComponents(url: locURL, resolvingAgainstBaseURL: false)
                let keys = (comps?.queryItems ?? []).map(\.name).joined(separator: ",")
                let ticket = comps?.queryItems?.first(where: { $0.name == "ticket" })?.value ?? ""
                LoginTrace.log("location 结构：keys=[\(keys)] ticket长度=\(ticket.count) "
                               + "含加号=\(ticket.contains("+")) 前6=\(String(ticket.prefix(6)))")
                LoginTrace.log("LP 命中 location，host=\(locURL.host ?? "?") path=\(locURL.path)")

                let ticketRequest = request(locURL, session: session)

                do {
                    let (respData, resp) = try await session.data(for: ticketRequest)

                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {

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

                guard MiLoginService.hasUsableCredential(cookie) else {

                    throw MiLoginError.badResponse("登录已确认，但没拿到 serviceToken")
                }
                return .succeeded(cookie: cookie)
            }

            if let raw = obj["code"] {
                let code = (raw as? Int) ?? Int((raw as? String) ?? "") ?? 0
                if code != 0 {
                    let desc = (obj["desc"] as? String) ?? (obj["description"] as? String) ?? ""
                    LoginTrace.log("LP code=\(code) desc=\(desc) → 判为票据失效")
                    throw MiLoginError.expired
                }
            }

            return .waiting
        } catch let e as MiLoginError {
            throw e
        } catch {
            let ns = error as NSError

            if ns.domain == NSURLErrorDomain {
                LoginTrace.log("LP 网络错误（可重试）：\(ns.code) \(ns.localizedDescription)")
                return .waiting
            }
            throw MiLoginError.requestFailed(error.localizedDescription)
        }
    }

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

    static func hasUsableCredential(_ cookieHeader: String) -> Bool {
        credentialQuality(cookieHeader) != .none
    }

    enum CredentialQuality: Equatable {

        case serviceToken

        case passTokenOnly

        case none
    }

    static func credentialQuality(_ cookieHeader: String) -> CredentialQuality {
        var hasService = false
        var hasPass = false
        for part in cookieHeader.split(separator: ";") {

            guard let eq = part.firstIndex(of: "=") else { continue }
            let name = part[part.startIndex..<eq].trimmingCharacters(in: .whitespaces)

            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if name == "serviceToken" { hasService = true }
            if name == "passToken" { hasPass = true }
        }
        if hasService { return .serviceToken }
        if hasPass { return .passTokenOnly }
        return .none
    }

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
