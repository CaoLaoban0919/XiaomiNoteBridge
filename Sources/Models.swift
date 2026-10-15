import Foundation

/// 一个小米笔记在列表中返回的元数据
struct MiNoteMeta {
    var id: String
    var folderId: String
    /// 标题：优先 extraInfo.title，其次正文首行，最后回落 "未命名"
    var title: String
    var snippet: String
    /// 毫秒时间戳
    var createDate: Double
    var modifyDate: Double
    /// 笔记引用的附件（图片等）
    var files: [MiFileRef]
}

/// 附件引用。fileId 形如 `123456.NT0kr_xxxx`
struct MiFileRef {
    var fileId: String
    var mimeType: String
    var ext: String {
        let parts = mimeType.split(separator: "/")
        return parts.count == 2 ? String(parts[1]) : "bin"
    }
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// 笔记详情：元数据 + 正文（小米私有 XML）
struct MiNoteDetail {
    var meta: MiNoteMeta
    var content: String
}

/// 一次列表请求的结果
struct MiPage {
    var entries: [MiNoteMeta]
    /// 文件夹 id -> 名称
    var folders: [String: String]
    var lastPage: Bool
    var syncTag: String?
}

