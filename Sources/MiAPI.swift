import Foundation

enum MiError: LocalizedError {
    case notLoggedIn
    case cookieInvalid
    case http(Int, String)
    case badPayload(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "还没有填写小米账号的 Cookie。"
        case .cookieInvalid: return "Cookie 无效或已过期，请重新获取。"
        case .http(let code, let path): return "请求失败（HTTP \(code)）\(path)"
        case .badPayload(let why): return "返回内容无法解析：\(why)"
        case .network(let msg): return "网络异常：\(msg)"
        }
    }
}

/// 保留 Cookie 的跳转处理器。
/// 小米的文件接口会 302 到 `s010.i.mi.com` 这类 CDN 域名，
/// URLSession 默认不会把自定义请求头带过去，这里手动补上。
private final class RedirectKeeper: NSObject, URLSessionTaskDelegate {
    var headers: [String: String] = [:]

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var req = request
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        completionHandler(req)
    }
}

final class MiAPI {
    private let base = "https://i.mi.com"
    private let keeper = RedirectKeeper()
    private let session: URLSession
    private(set) var cookie: String

    init(cookie: String) {
        self.cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
        self.keeper.headers = self.defaultHeaders
    }

    private var defaultHeaders: [String: String] {
        [
            "Cookie": cookie,
            "Referer": "https://i.mi.com/note/h5",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) MiNoteBridge/1.0",
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9",
        ]
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        for (k, v) in defaultHeaders { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        guard !cookie.isEmpty else { throw MiError.notLoggedIn }
        do {
            let (data, resp) = try await session.data(for: request(url), delegate: keeper)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        } catch {
            throw MiError.network(error.localizedDescription)
        }
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, code) = try await get(url)
        guard (200..<300).contains(code) else {
            throw MiError.http(code, url.path)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiError.badPayload("不是合法 JSON")
        }
        return obj
    }

    // MARK: - 取值辅助

    private func str(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case .none: return ""
        case .some(let v): return String(describing: v)
        }
    }

    private func num(_ any: Any?) -> Double {
        switch any {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    /// extraInfo 有时是 JSON 字符串，有时已经是对象
    private func parseExtraInfo(_ any: Any?) -> [String: Any] {
        if let d = any as? [String: Any] { return d }
        if let s = any as? String, let data = s.data(using: .utf8),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return d
        }
        return [:]
    }

    private func parseFiles(_ entry: [String: Any]) -> [MiFileRef] {
        // 与 `parseExtraInfo` 一样，`setting` 也可能是 JSON **字符串**而不是对象。
        // 只认字典会让附件列表**静默变成空**：不报错、不告警，图片永远不下载，
        // 正文里的 <img fileid> 全部渲染成占位框，用户以为笔记本来就没图。
        let setting = parseExtraInfo(entry["setting"])
        guard let arr = setting["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            let fileId = str(item["fileId"])
            guard !fileId.isEmpty else { return nil }
            let mime = str(item["mimeType"])
            return MiFileRef(fileId: fileId, mimeType: mime.isEmpty ? "application/octet-stream" : mime)
        }
    }

    private func parseEntry(_ entry: [String: Any], folders: [String: String]) -> MiNoteMeta {
        let extra = parseExtraInfo(entry["extraInfo"])
        let rawContent = str(entry["content"]).isEmpty ? str(entry["snippet"]) : str(entry["content"])
        let mind = str(extra["mind_content"]).isEmpty ? rawContent : str(extra["mind_content"])
        let title = XiaomiConvert.deriveTitle(explicitTitle: str(extra["title"]), rawContent: mind)
        let folderId = str(entry["folderId"])
        return MiNoteMeta(
            id: str(entry["id"]),
            folderId: folderId,
            title: title,
            snippet: str(entry["snippet"]),
            createDate: num(entry["createDate"]),
            modifyDate: num(entry["modifyDate"]),
            files: parseFiles(entry)
        )
    }

    // MARK: - 接口

    /// 拉一页笔记列表。`syncTag` 为 nil 表示第一页。
    func fetchPage(syncTag: String?, limit: Int = 200) async throws -> MiPage {
        var comps = URLComponents(string: "\(base)/note/full/page/")!
        // 查询串**手拼**，不要用 `URLQueryItem`。两个坑会叠在一起：
        //   1. `URLQueryItem` 不转义 `+`（RFC 3986 里它是合法 sub-delim），
        //      而服务端按表单规则会把 `+` 解成空格；
        //   2. 若先手动 `addingPercentEncoding` 再交给 `queryItems`，`%` 会被
        //      再编一次（`%2B` → `%252B`），tag 彻底坏掉。
        // 实测三种写法，只有 `percentEncodedQuery` 是"只编一次"且能正确回环的：
        //   现状(双重编码) → syncTag=H4sIAB%252B%252Fabc%253D%253D
        //   不编码         → syncTag=H4sIAB+/abc%3D%3D   （+ 会被解成空格）
        //   percentEncoded → syncTag=H4sIAB%2B%2Fabc%3D%3D  ✓
        // 后果很隐蔽：第一页 `syncTag == nil` 不走这段，所以**第一页永远正常**；
        // 翻到第二页时服务端拿到非 base64 的 tag，返回没有 entries 的 JSON，
        // 于是 `getJSON` 之后抛 `cookieInvalid` —— 用户在**已经登录成功**的状态下
        // 被提示「Cookie 无效或已过期」，去重登一遍也没用。
        var items = [URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970 * 1000))),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let tag = syncTag, !tag.isEmpty {
            items.append(URLQueryItem(name: "syncTag", value: tag))
        }
        comps.queryItems = items
        // `URLComponents` 会编码 `=`（`%3D`）、保留 `/`，**唯独漏掉 `+`**
        // （RFC 3986 允许 `+` 原样出现在 query 里），而服务端按表单规则把 `+` 解成空格。
        // 所以只补 `+` 这一处，其余交给系统：这是"改动面最小"的写法，
        // 也避免自己把 `/` 编成 `%2F` 去试探服务端的宽容度。
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        let json = try await getJSON(comps.url!)
        guard let data = json["data"] as? [String: Any] else {
            throw MiError.cookieInvalid
        }
        guard let entries = data["entries"] as? [[String: Any]] else {
            throw MiError.cookieInvalid
        }

        var folderMap: [String: String] = [:]
        if let folders = data["folders"] as? [[String: Any]] {
            for f in folders {
                let id = str(f["id"])
                let subject = str(f["subject"])
                if !id.isEmpty { folderMap[id] = subject.isEmpty ? "未命名文件夹" : subject }
            }
        }

        let lastPage = (data["lastPage"] as? Bool) ?? false
        let rawTag = str(data["syncTag"])

        return MiPage(
            entries: entries.map { parseEntry($0, folders: folderMap) },
            folders: folderMap,
            lastPage: lastPage,
            syncTag: rawTag.isEmpty ? nil : rawTag
        )
    }

    /// 拉取笔记详情（含正文）
    func fetchDetail(id: String) async throws -> MiNoteDetail {
        var comps = URLComponents(string: "\(base)/note/note/\(id)/")!
        comps.queryItems = [URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        let json = try await getJSON(comps.url!)
        guard let data = json["data"] as? [String: Any],
              let entry = data["entry"] as? [String: Any] else {
            throw MiError.badPayload("缺少 entry（笔记 \(id)）")
        }
        let meta = parseEntry(entry, folders: [:])
        var content = str(entry["content"])
        let extra = parseExtraInfo(entry["extraInfo"])
        if XiaomiConvert.isMindMap(str(extra["mind_content"])) {
            content = str(extra["mind_content"])
        }
        if content.isEmpty { content = meta.snippet }
        return MiNoteDetail(meta: meta, content: content)
    }

    /// 下载附件原始字节
    func fetchFile(fileId: String) async throws -> Data {
        var comps = URLComponents(string: "\(base)/file/full")!
        comps.queryItems = [
            URLQueryItem(name: "fileid", value: fileId),
            URLQueryItem(name: "type", value: "note_img"),
        ]
        let (data, code) = try await get(comps.url!)
        guard (200..<300).contains(code) else { throw MiError.http(code, "/file/full") }
        guard !data.isEmpty else { throw MiError.badPayload("附件内容为空") }
        return data
    }

    /// 轻量连通性测试
    func testConnection() async throws -> Int {
        let page = try await fetchPage(syncTag: nil, limit: 1)
        return page.entries.count
    }
}
