import Foundation

struct MiNoteMeta {
    var id: String
    var folderId: String

    var title: String
    var snippet: String

    var createDate: Double
    var modifyDate: Double

    var files: [MiFileRef]
}

struct MiFileRef {
    var fileId: String
    var mimeType: String
    var ext: String {
        let parts = mimeType.split(separator: "/")
        return parts.count == 2 ? String(parts[1]) : "bin"
    }
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

struct MiNoteDetail {
    var meta: MiNoteMeta
    var content: String
}

struct MiPage {
    var entries: [MiNoteMeta]

    var folders: [String: String]
    var lastPage: Bool
    var syncTag: String?
}
