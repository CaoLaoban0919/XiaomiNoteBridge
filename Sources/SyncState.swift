import Foundation

/// 一条笔记的同步记录。
struct NoteRecord: Codable {
    /// 小米侧的 noteId
    var noteId: String
    /// 小米侧的修改时间（毫秒）
    var modifyDate: Double
    /// 备忘录内部的 id（`x-coredata://...`）——「通道二」靠它定位笔记
    var appleId: String?
    /// 上次写入时正文的哈希，用于判断内容是否真的变了
    var bodyHash: String?
    /// 标题与摘要。用于应用重启后还原列表展示。
    /// **用可选字段**——早期版本的 state.json 没有这两项，可选才能兼容旧数据不回退成空。
    var title: String?
    var snippet: String?
    /// 这条笔记的正文是否被 AI 重构过。
    ///
    /// **同步时必须跳过它。** 否则小米侧下次有改动时，`set body` 覆盖会把
    /// 用户花时间做的 AI 重构直接冲掉。用可选字段兼容旧 state.json。
    var aiModified: Bool?
    /// 当前状态
    var status: Status

    enum Status: String, Codable {
        case synced          // 已确认同步完成
        case pending         // 已写入 ENEX，但还没确认导入成功
        case skipped         // 主动跳过（例如带图片的改动笔记）
        case userDeleted     // 用户在备忘录里删掉了，尊重他的选择，不再重建
    }
}

/// 一次尚未确认的导入批次。
///
/// 「写 ENEX → 等备忘录导入」是异步的，程序无法立刻知道是否成功。
/// 所以先把批次挂起，等数数确认通过了，才把批次里的笔记标成 synced。
/// 这样即使中途崩溃，下次重跑也只是重导这一批，不会丢笔记。
struct PendingBatch: Codable {
    var file: String
    var noteIds: [String]
    var expectedCount: Int
    var createdAt: Date
}

/// `state.json` 的完整结构
struct SyncState: Codable {
    var version: Int = 1
    var lastSyncAt: Date?
    var notes: [String: NoteRecord] = [:]
    var pendingBatch: PendingBatch?
    var userDeleted: [String] = []
}

/// `state.json` 的读写。
///
/// **权限同样收紧到 0600。**
///
/// 早先的注释写着"只是同步进度、不含笔记内容、权限可以宽松些"——
/// 那是**在 `NoteRecord` 加上 `title` / `snippet` 之前**的说法。
/// 现在这两个字段装着笔记的标题和摘要，属于用户内容，宽松就不成立了。
enum SyncStateStore {

    static var url: URL { CredentialsStore.directory.appendingPathComponent("state.json") }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return state
    }

    static func save(_ state: SyncState) throws {
        _ = CredentialsStore.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
        // 写完立刻收紧：里面含笔记标题与摘要，不该让同机其它账户读到
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    static func reset() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// 对一次同步结果的分类。增量判断的三条分支都落在这里。
enum NoteDecision {
    case new                            // 新笔记 → 走 ENEX 导入
    case updated(newModifyDate: Double) // 改过且有对应记录 → 走 AppleScript 覆盖
    case unchanged                      // 没变 → 跳过
    case knownDeleted                   // 用户删过 → 尊重删除，跳过
}

extension SyncState {

    /// 判断一条小米笔记该怎么处理。
    ///
    /// 注意这里刻意**不**把「带图片的改动笔记」也归到 .updated：
    /// `set body` 能否把本地图片写进备忘录尚未验证，若不能，覆盖一次就丢一次图，
    /// 比不更新更糟。所以在验证通过之前，这类笔记应当走 skipped。
    func decide(noteId: String, modifyDate: Double) -> NoteDecision {
        if userDeleted.contains(noteId) { return .knownDeleted }
        guard let record = notes[noteId] else { return .new }
        if record.modifyDate == modifyDate { return .unchanged }
        return .updated(newModifyDate: modifyDate)
    }
}
