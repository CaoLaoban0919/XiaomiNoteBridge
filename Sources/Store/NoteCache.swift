import Foundation

/// 本地笔记缓存：只读拉取的落点。
///
/// **这里只写 `~/Library/Application Support/MiNoteBridge/notes-cache/`，
/// 不碰 Apple 备忘录一个字节。**
///
/// 目录结构：
/// ```
/// notes-cache/
///   index.json            索引（CachedNote + CachedFolder）
///   bodies/<noteId>.html  正文（toDisplayHTML 转好的、可直接显示的 HTML）
///   images/<fileId>       图片原始字节
/// ```
/// 权限沿用 `CredentialsStore` 的约定：目录 `0700`、文件 `0600`。
/// **注意 `createDirectory` 的 attributes 只在新建时生效**，已存在的目录不会因此被收紧，
/// 所以每次都要显式 `setAttributes` 再收一次。
final class NoteCache: NoteCacheProtocol {

    static let folderName = "notes-cache"

    /// 缓存根目录。默认 `CredentialsStore.directory/notes-cache/`。
    let root: URL

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var bodiesURL: URL { root.appendingPathComponent("bodies", isDirectory: true) }
    private var imagesURL: URL { root.appendingPathComponent("images", isDirectory: true) }

    init(root: URL? = nil) {
        self.root = root ?? CredentialsStore.directory
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }

    // MARK: - 索引

    private struct IndexPayload: Codable {
        var notes: [CachedNote]
        var folders: [CachedFolder]
    }

    func loadIndex() -> (notes: [CachedNote], folders: [CachedFolder]) {
        guard let data = try? Data(contentsOf: indexURL),
              let payload = try? JSONDecoder().decode(IndexPayload.self, from: data) else {
            return ([], [])
        }
        return (payload.notes, payload.folders)
    }

    func saveIndex(notes: [CachedNote], folders: [CachedFolder]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(IndexPayload(notes: notes, folders: folders))
        try writeFile(data, to: indexURL)
    }

    // MARK: - 正文与图片

    func content(for noteId: String) -> CachedNoteContent? {
        let url = bodiesURL.appendingPathComponent(Self.fileName(noteId) + ".html")
        guard let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8) else { return nil }

        // 取图要按 HTML 里真正引用的 fileId —— 磁盘上留的可能是**旧版本**正文，
        // 它引用的 fileId 与当前索引的 imageFileIds 可能不是同一组；只按索引取会
        // 让本地明明有图的那几张显示成「图片未下载」。这里两者取并集。
        var ids = loadIndex().notes.first { $0.id == noteId }?.imageFileIds ?? []
        for id in Self.imageIds(inHTML: html) where !ids.contains(id) {
            ids.append(id)
        }
        var images: [String: Data] = [:]
        for fileId in ids {
            if let bytes = imageData(fileId: fileId) {
                images[fileId] = bytes
            }
        }
        return CachedNoteContent(html: html, images: images)
    }

    func saveContent(_ content: CachedNoteContent, for noteId: String) throws {
        try writeFile(Data(content.html.utf8),
                      to: bodiesURL.appendingPathComponent(Self.fileName(noteId) + ".html"))
        for (fileId, bytes) in content.images {
            try writeFile(bytes, to: imagesURL.appendingPathComponent(Self.fileName(fileId)))
        }
    }

    /// 保存「AI 改写前的原文」，**只在不存在时写一次**。
    ///
    /// 不能每次改写都覆盖：那样"原文"会跟着一起往后漂，
    /// 用户点开看到的永远是上一次 AI 的版本，而不是最初的样子。
    func saveOriginalIfAbsent(_ content: CachedNoteContent, for noteId: String) throws {
        let url = bodiesURL.appendingPathComponent(Self.fileName(noteId) + ".original.html")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try writeFile(Data(content.html.utf8), to: url)
    }

    /// 读取 AI 改写前的原文。没有备份（历史数据、或从未被 AI 改过）时返回 nil。
    func originalContent(for noteId: String) -> String? {
        let url = bodiesURL.appendingPathComponent(Self.fileName(noteId) + ".original.html")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func imageData(fileId: String) -> Data? {
        try? Data(contentsOf: imagesURL.appendingPathComponent(Self.fileName(fileId)))
    }

    /// 某张图是否已在本地。增量判断用：只 stat 文件在不在，**不读字节**。
    func hasImage(fileId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: imagesURL.appendingPathComponent(Self.fileName(fileId)).path)
    }

    /// 单独落一张图（增量补图用），不重写正文和其它图片。
    func saveImage(_ data: Data, fileId: String) throws {
        try writeFile(data, to: imagesURL.appendingPathComponent(Self.fileName(fileId)))
    }

    func clearAll() throws {
        let fm = FileManager.default
        for url in [bodiesURL, imagesURL, indexURL] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: - 落盘细节

    /// 创建目录并收紧到 0700：本机其他用户连缓存文件名都不该看到。
    private func ensureDirectories() throws {
        // 父目录（MiNoteBridge/）是老约定管的，先确保它在并且是 0700。
        _ = CredentialsStore.ensureDirectory()
        let fm = FileManager.default
        for dir in [root, bodiesURL, imagesURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // attributes 只在新建目录时生效；已存在的老目录要再显式收紧一次。
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// 原子写 + 写完立刻把文件权限收紧到 0600。
    private func writeFile(_ data: Data, to url: URL) throws {
        try ensureDirectories()
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    /// 从存储的 HTML 里取出所有 `<img fileid="…"/>` 引用的 fileId。
    /// 正文是 `XiaomiConvert.toDisplayHTML` 的产物，图片引用就长这样；
    /// 思维导图正文没有 img，这条自然返回空。
    private static func imageIds(inHTML html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "fileid=\"([^\"]+)\"") else { return [] }
        let ns = html as NSString
        return re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// noteId / fileId → 安全文件名。
    /// fileId 来自远端响应，理论上可能带 `/`、`..` 之类的字符，直接拼进路径会跑到目录外面去。
    /// 允许集里刻意不含 `.` 和 `/`，因此不可能构造出 `..` 这种名字。
    private static func fileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return encoded.isEmpty ? "unnamed" : encoded
    }
}
