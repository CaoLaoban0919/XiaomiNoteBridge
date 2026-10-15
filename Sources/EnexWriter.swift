import Foundation
import CryptoKit

/// ENEX 里的一个附件（图片）
struct EnexResource {
    var data: Data
    var mime: String
    var filename: String
    /// 附件原始字节的 MD5（小写十六进制），ENEX 用它把正文里的 en-media 和资源对应起来
    var md5: String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// ENEX 里的一条笔记
struct EnexNote {
    var title: String
    var body: String
    var created: Date
    var updated: Date
    /// 用小米的文件夹名当标签
    var tags: [String] = []
    var resources: [EnexResource] = []
}

/// 生成 Apple 备忘录 / Evernote 可导入的 ENEX 文件。
/// 结构参照 aerragha/xiaomi-notes-to-apple-notes（MIT）。
enum EnexWriter {

    private static let appName = "MiNoteBridge"

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func render(notes: [EnexNote], exportDate: Date = Date()) -> String {
        var xml = ""
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<!DOCTYPE en-export SYSTEM \"http://xml.evernote.com/pub/evernote-export4.dtd\">\n"
        xml += "<en-export export-date=\"\(timestamp(exportDate))\" application=\"\(appName)\" version=\"1.0\">\n"

        for note in notes {
            xml += "<note>\n"
            xml += "<title>\(XiaomiConvert.escapeXML(note.title))</title>\n"

            // en-note 包一层，再整体塞进 CDATA
            var enml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
            enml += "<!DOCTYPE en-note SYSTEM \"http://xml.evernote.com/pub/enml2.dtd\">\n"
            enml += "<en-note>\(note.body)</en-note>"
            xml += "<content><![CDATA[\(enml)]]></content>\n"

            xml += "<created>\(timestamp(note.created))</created>\n"
            xml += "<updated>\(timestamp(note.updated))</updated>\n"

            for tag in note.tags where !tag.isEmpty {
                xml += "<tag>\(XiaomiConvert.escapeXML(tag))</tag>\n"
            }

            for res in note.resources {
                xml += "<resource>\n"
                xml += "<data encoding=\"base64\">\(res.data.base64EncodedString())</data>\n"
                xml += "<mime>\(XiaomiConvert.escapeXML(res.mime))</mime>\n"
                xml += "<resource-attributes>\n"
                xml += "<file-name>\(XiaomiConvert.escapeXML(res.filename))</file-name>\n"
                xml += "</resource-attributes>\n"
                xml += "</resource>\n"
            }

            xml += "</note>\n"
        }

        xml += "</en-export>\n"
        return xml
    }

    static func write(notes: [EnexNote], to url: URL) throws {
        let text = render(notes: notes)
        // 原子写入，避免导入到半个文件
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".enex-\(UUID().uuidString).tmp")
        try text.data(using: .utf8)?.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// 做一次基本的自检：根元素、笔记数量、每个 en-media 都有对应资源
    static func validate(_ xml: String, expectedNotes: Int) -> [String] {
        var problems: [String] = []
        if !xml.contains("<en-export ") { problems.append("根元素不是 en-export") }
        let noteCount = xml.components(separatedBy: "<note>").count - 1
        if noteCount != expectedNotes {
            problems.append("笔记数量不符：实际 \(noteCount)，预期 \(expectedNotes)")
        }
        if xml.contains("<en-media") && !xml.contains("<resource>") {
            problems.append("有 en-media 但没有 resource")
        }
        return problems
    }
}
