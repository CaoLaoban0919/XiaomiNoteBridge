import Foundation

// 「拉取」与「导入」分离后的**共享契约**。
//
// 这次拆分的核心原则：
//
//   拉取（Pull）  **只读**。从小米把笔记和图片拉到本地缓存，
//                不碰 Apple 备忘录一个字。用户在软件里就能看。
//   导入（Import）**才写**。用户手动勾选 + 确认之后，
//                才把选中的笔记写进备忘录，并按文件夹建好结构。
//
// 这么拆的好处：看笔记这件事完全无副作用；要写什么东西，必须用户亲自点。

// MARK: - 缓存里的数据

/// 缓存里的一条笔记。**本地为准，不联网也能看。**
struct CachedNote: Identifiable, Codable, Equatable {
    /// 小米侧 noteId
    var id: String
    var title: String
    var snippet: String
    var folderId: String
    var folderName: String
    /// 毫秒时间戳
    var createDate: Double
    var modifyDate: Double
    /// 附件（图片 + 其它）
    var fileIds: [String]
    /// 其中属于图片的那些（决定详情能不能预览）
    var imageFileIds: [String]
    /// 正文是否已经拉到本地。没拉到的笔记在界面上要区分出来，别让用户点开是空的。
    var hasBody: Bool
    /// 是否已导入备忘录
    var imported: Bool
    /// 导入后在备忘录里的内部 id
    var appleId: String?
    /// 正文被 AI 重构过 —— 导入/覆盖时要跳过，别冲掉用户的成果
    var aiModified: Bool
}

/// 缓存里的一个文件夹（来自小米）
struct CachedFolder: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    /// 该文件夹下的笔记条数（拉取完就能算出来，用于列表展示）
    var noteCount: Int
}

/// 一条笔记的完整内容
extension CachedNote {
    /// 纯文本摘要，供列表与详情显示。
    ///
    /// `snippet` 存的是小米返回的**原始片段**，可能带 `<new-format>` / `<text indent>`
    /// 这类标签。列表直接显示它，于是满屏尖括号。
    /// 这里只在**显示前**剥标签、解实体，不改存储值——原始片段留着日后解析用。
    var plainSnippet: String {
        var s = snippet
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CachedNoteContent {
    var html: String
    /// fileId -> 图片字节
    var images: [String: Data]
}

// MARK: - 进度

/// 拉取进度
struct PullProgress {
    enum Phase: Equatable {
        case idle
        case fetchingList
        case fetchingBodies
        case downloadingImages
        case finished
        case failed(String)
    }
    var phase: Phase = .idle
    var currentTitle: String?
    var completed = 0
    var total = 0
    var notesPulled = 0
    var imagesDownloaded = 0
    var imagesFailed = 0
}

/// 导入进度
struct ImportProgress {
    enum Phase: Equatable {
        case idle
        case preparing        // 组装 ENEX
        case writing          // 写文件 + 交给备忘录
        case awaitingImport   // 等备忘录导入完成
        case organizingFolders// 按文件夹归位
        case finished
        case failed(String)
    }
    var phase: Phase = .idle
    var currentTitle: String?
    var completed = 0
    var total = 0
}

// MARK: - 缓存读写

/// 本地笔记缓存。
///
/// **拉取只写这里，一个字节都不碰备忘录。**
/// 存放位置沿用现有约定：`~/Library/Application Support/MiNoteBridge/`
/// （目录 0700、文件 0600）。正文与图片分文件存，索引单独一份 JSON。
protocol NoteCacheProtocol: AnyObject {
    /// 载入索引（笔记 + 文件夹）。没有缓存时返回空。
    func loadIndex() -> (notes: [CachedNote], folders: [CachedFolder])
    func saveIndex(notes: [CachedNote], folders: [CachedFolder]) throws

    /// 取一条笔记的正文与图片；没拉到时返回 nil
    func content(for noteId: String) -> CachedNoteContent?
    func saveContent(_ content: CachedNoteContent, for noteId: String) throws

    /// 只写正文，不动图片。
    ///
    /// 用户打字的落盘走这条：正文每 600ms 变一次，而图片在编辑过程中不会变。
    /// 用 `saveContent` 的话，一条带十张图的笔记每敲一下就要把几十兆字节重写一遍，
    /// 主线程会被磁盘 IO 拖住。
    func saveHTML(_ html: String, for noteId: String) throws

    /// 保存「AI 改写前的原文」，**只在没有备份时才写**。
    /// 每次改写都覆盖的话，"原文"会跟着往后漂，用户看到的就是上一次 AI 的版本了。
    func saveOriginalIfAbsent(_ content: CachedNoteContent, for noteId: String) throws
    /// 读取 AI 改写前的原文。没有备份时返回 nil。
    func originalContent(for noteId: String) -> String?

    /// 单独取一张图（列表缩略图之类会用到）
    func imageData(fileId: String) -> Data?

    /// 清空缓存（正文、图片、索引全清）
    func clearAll() throws
}

// MARK: - 拉取

/// 只读拉取。**实现里不允许出现任何写备忘录的调用。**
@MainActor
protocol PullEngineProtocol: AnyObject {
    var progress: PullProgress { get }
    var logLines: [String] { get }
    var notes: [CachedNote] { get }
    var folders: [CachedFolder] { get }
    var isRunning: Bool { get }

    /// 从缓存读，**不联网**。进入主界面时先调它，让用户马上看到上次拉到的内容。
    func reloadFromCache() async

    /// 联网拉取：列表 → 正文 → 图片，全部写进缓存。
    /// 已经在缓存里且 modifyDate 没变的笔记**不重复下载**。
    func pull() async

    func cancel()
}

// MARK: - 变更审批（红绿灯）

/// 一次变更会做什么。
///
/// 分档的依据是**可逆性**，不是"写了多少"：
/// 新建一条笔记用户自己能删，可逆；覆盖一条已有笔记的正文，写掉就找不回来了。
enum ChangeKind: String, Codable {
    /// 在备忘录里新建一条。可逆 → 低危
    case create
    /// 把已导入的笔记挪进文件夹。可逆 → 低危
    case moveToFolder
    /// **覆盖已导入笔记的正文。写掉就找不回来 → 高危，必须逐条审批。**
    case overwrite

    var label: String {
        switch self {
        case .create: return "新建"
        case .moveToFolder: return "归入文件夹"
        case .overwrite: return "覆盖正文"
        }
    }
}

/// 危险等级。**只有 `high` 需要用户逐条点头。**
///
/// 这不是随意分的：如果每条变更都弹卡片，几百条笔记就是几百次点击，
/// 用户只会养成"闭眼点同意"的习惯，审批就失去意义了。
/// Trae 的权限系统也是"例外驱动"——只有超出默认范围的操作才弹卡。
enum ChangeRisk: String, Codable {
    case low
    case high
}

/// 一条待执行的变更，供用户审批。
struct PlannedChange: Identifiable, Codable, Equatable {
    var id: String { noteId }
    /// 小米侧 noteId
    var noteId: String
    var title: String
    var kind: ChangeKind
    var risk: ChangeRisk
    /// 目标文件夹名。空表示留在「导入的备忘录」。
    var targetFolder: String
    /// 正文纯文本的前若干字符。**审批「覆盖」时要让用户看得见将要失去什么。**
    var preview: String
    /// 不能执行的原因（例如「含图片，覆盖会丢图」）。
    /// 非空时这一条会在界面上显示为「无法执行 + 原因」，且**不进入审批列表**。
    var blockedReason: String?
}

/// 一次导入会对备忘录做的**全部**变更。
///
/// 引擎先用它「只算不写」，用户在上面审批，然后才真正执行。
struct ChangePlan {
    /// 新建（低危，批量通过）
    var creates: [PlannedChange] = []
    /// 按文件夹归位（低危，批量通过）
    var moves: [PlannedChange] = []
    /// 覆盖已导入笔记的正文（**高危，逐条审批**）
    var overwrites: [PlannedChange] = []

    var total: Int { creates.count + moves.count + overwrites.count }
    var isEmpty: Bool { total == 0 }

    /// 需要用户逐条点头的那些（排除掉本来就执行不了的）
    var needsApproval: [PlannedChange] {
        overwrites.filter { $0.blockedReason == nil }
    }

    /// 执行不了的那些，用于在界面上如实告知
    var blocked: [PlannedChange] {
        (creates + moves + overwrites).filter { $0.blockedReason != nil }
    }
}

// MARK: - 导入

/// 把选中的笔记写进 Apple 备忘录。**只有用户点了确认才会走到这里。**
@MainActor
protocol ImportEngineProtocol: AnyObject {
    var progress: ImportProgress { get }
    var logLines: [String] { get }
    var isRunning: Bool { get }

    /// **只算不写**：列出这次会对备忘录做的全部变更，交给用户审批。
    ///
    /// 必须和 `start` 用同一套判断逻辑，否则会出现
    /// 「审批时看到的」和「真正执行的」不是一个东西——那比不做审批更糟。
    func plan(noteIds: [String]) -> ChangePlan

    /// 执行。
    /// - Parameters:
    ///   - noteIds: 用户勾选的小米 noteId
    ///   - approvedOverwrites: **用户逐条批准覆盖的 noteId 集合**。
    ///     不在这个集合里的 `overwrite` 一律不执行——这是红绿灯机制的核心，
    ///     不能在实现里"顺手全做了"。
    /// - 要求：**按每条笔记的 `folderName` 在备忘录里建好文件夹再放进去**，
    ///   同名文件夹复用而不是重复创建；没有归属文件夹的笔记留在「导入的备忘录」。
    func start(noteIds: [String], approvedOverwrites: Set<String>) async

    func cancel()
}
