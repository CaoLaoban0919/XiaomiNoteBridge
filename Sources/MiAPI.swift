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
        guard let setting = entry["setting"] as? [String: Any],
              let arr = setting["data"] as? [[String: Any]] else { return [] }
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
        var items = [URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970 * 1000))),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let tag = syncTag, !tag.isEmpty { items.append(URLQueryItem(name: "syncTag", value: tag)) }
        comps.queryItems = items

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
