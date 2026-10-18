import Foundation

final class NoteCache: NoteCacheProtocol {

    static let folderName = "notes-cache"

    let root: URL

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var bodiesURL: URL { root.appendingPathComponent("bodies", isDirectory: true) }
    private var imagesURL: URL { root.appendingPathComponent("images", isDirectory: true) }

    init(root: URL? = nil) {
        self.root = root ?? CredentialsStore.directory
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }

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

    func removeNote(id noteId: String) throws {
        let (notes, folders) = loadIndex()
        try saveIndex(notes: notes.filter { $0.id != noteId }, folders: folders)

        let base = Self.fileName(noteId)
        for suffix in [".html", ".original.html"] {
            try? FileManager.default.removeItem(
                at: bodiesURL.appendingPathComponent(base + suffix)
            )
        }
    }

    func content(for noteId: String) -> CachedNoteContent? {
        let url = bodiesURL.appendingPathComponent(Self.fileName(noteId) + ".html")
        guard let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8) else { return nil }

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
        try saveHTML(content.html, for: noteId)
        for (fileId, bytes) in content.images {
            try writeFile(bytes, to: imagesURL.appendingPathComponent(Self.fileName(fileId)))
        }
    }

    func saveHTML(_ html: String, for noteId: String) throws {
        try writeFile(Data(html.utf8),
                      to: bodiesURL.appendingPathComponent(Self.fileName(noteId) + ".html"))
    }

    func saveOriginalIfAbsent(_ content: CachedNoteContent, for noteId: String) throws {
        let url = bodiesURL.appendingPathComponent(Self.fileName(noteId) + ".original.html")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try writeFile(Data(content.html.utf8), to: url)
    }

    func originalContent(for noteId: String) -> String? {
        let url = bodiesURL.appendingPathComponent(Self.fileName(noteId) + ".original.html")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func imageData(fileId: String) -> Data? {
        try? Data(contentsOf: imagesURL.appendingPathComponent(Self.fileName(fileId)))
    }

    func hasImage(fileId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: imagesURL.appendingPathComponent(Self.fileName(fileId)).path)
    }

    func saveImage(_ data: Data, fileId: String) throws {
        try writeFile(data, to: imagesURL.appendingPathComponent(Self.fileName(fileId)))
    }

    func clearAll() throws {
        let fm = FileManager.default
        for url in [bodiesURL, imagesURL, indexURL] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    private func ensureDirectories() throws {

        _ = CredentialsStore.ensureDirectory()
        let fm = FileManager.default
        for dir in [root, bodiesURL, imagesURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])

            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    private func writeFile(_ data: Data, to url: URL) throws {
        try ensureDirectories()
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    private static func imageIds(inHTML html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "fileid=\"([^\"]+)\"") else { return [] }
        let ns = html as NSString
        return re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func fileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return encoded.isEmpty ? "unnamed" : encoded
    }
}
