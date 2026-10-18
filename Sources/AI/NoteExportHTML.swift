import Foundation

enum NoteExportHTML {
    /// A copy must not silently turn unresolved images into text placeholders.
    static func validateCopyImages(_ html: String, imageMeta: [String: (mime: String, hash: String)]) throws {
        let tags = try NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
        let ids = try NSRegularExpression(pattern: #"\bfileid\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s/>]+))"#, options: .caseInsensitive)
        let source = html as NSString
        for match in tags.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: match.range) as NSString
            let idMatch = ids.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length))
            let id = idMatch.flatMap { match in
                (1...3).first(where: { match.range(at: $0).location != NSNotFound }).map { tag.substring(with: match.range(at: $0)) }
            }
            guard let id, imageMeta[id] != nil else {
                throw NSError(domain: "NoteExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "有图片尚未下载或无法导出，未保存不完整的副本。请先拉取完整正文和图片。"])
            }
        }
    }

    struct Result {
        var html: String
        var resources: [EnexResource]
        var imageMeta: [String: (mime: String, hash: String)]
    }

    static func attachInlineImages(_ html: String) throws -> Result {
        let regex = try NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
        let source = html as NSString
        let output = NSMutableString(string: html)
        var resources: [EnexResource] = [], metadata: [String: (mime: String, hash: String)] = [:]
        func attribute(_ name: String, _ tag: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: "\\s" + name + #"\s*=\s*["']([^"']*)["']"#, options: .caseInsensitive),
                  let match = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), let range = Range(match.range(at: 1), in: tag) else { return nil }
            return String(tag[range])
        }
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let tag = source.substring(with: match.range)
            guard let uri = attribute("src", tag), uri.lowercased().hasPrefix("data:image/") else { continue }
            guard let comma = uri.firstIndex(of: ","), uri[..<comma].lowercased().hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])), !data.isEmpty else {
                throw NSError(domain: "NoteExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "内嵌图片数据无效，已停止导出以免丢图。"])
            }
            let mime = String(uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]).components(separatedBy: ";")[0].lowercased()
            guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) else {
                throw NSError(domain: "NoteExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "内嵌图片格式暂不支持：\(mime)。原笔记未修改。"])
            }
            let ext = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"][mime]!
            var resource = EnexResource(data: data, mime: mime, filename: "inline.\(ext)")
            let id = "mn-inline-" + resource.md5
            resource.filename = id + "." + ext
            if metadata[id] == nil { resources.append(resource); metadata[id] = (mime, resource.md5) }
            var dimensions = ""
            for name in ["width", "height"] {
                if let value = attribute(name, tag), let number = Int(value), number > 0, number <= 32768 { dimensions += " \(name)=\"\(number)\"" }
            }
            output.replaceCharacters(in: match.range, with: "<img fileid=\"\(id)\"\(dimensions)/>")
        }
        return Result(html: output as String, resources: resources, imageMeta: metadata)
    }
}
