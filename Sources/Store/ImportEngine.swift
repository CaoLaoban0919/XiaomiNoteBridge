import Foundation
import Combine
import AppKit

/// 导入引擎：把**用户手动选中**的笔记写进 Apple 备忘录，并按文件夹建好结构。
///
/// 架构拆分的两半：
///   - 拉取（`PullEngine`）**只读**：把小米的笔记与图片拉进本地缓存，一个字都不碰备忘录；
///   - 导入（本类）**才写**：用户勾选 + 审批之后，才把选中的笔记写进备忘录。
///
/// 数据来源是**本地缓存**（`NoteCacheProtocol`），整条流程不联网——
/// 正文与图片在拉取阶段就已经下载好了，这里只负责组装与写入。
///
/// ## 变更审批（红绿灯）
///
/// 写入分两条通道，按**可逆性**分档（对应契约里的 `ChangeKind` / `ChangeRisk`）：
///
/// | 通道 | 触发条件 | 实现 | 风险 |
/// |---|---|---|---|
/// | 新建 | 没导入过的笔记 | 组装 ENEX 交给「备忘录」导入 | 低危：用户自己能删，批量通过 |
/// | 覆盖 | 已导入过的笔记 | `NotesImporter.setBody` 原地改写正文 | **高危：写掉找不回来，逐条审批** |
///
/// 先 `plan(noteIds:)` **只算不写**给出 `ChangePlan`，用户在界面上逐条点头；执行时
/// `start(noteIds:approvedOverwrites:)` 的 `approvedOverwrites` 是覆盖通道的**唯一凭据**——
/// 不在集合里的一条都不写（闸门在 `runImport` 的分类循环里，见那里的注释）。
/// `plan` 与 `start` 共用同一套判断（`evaluate`），保证「审批时看到的」和「真正执行的」
/// 永远是同一个东西——两边各写一套是比不做审批更糟的事。
///
/// 纯逻辑层，不 import SwiftUI；用 `ObservableObject` + `@Published` 让 UI 观察，
/// 同时满足 `Store/StoreContract.swift` 里定义的 `ImportEngineProtocol`。
@MainActor
final class ImportEngine: ObservableObject, ImportEngineProtocol {

    // MARK: - 可观察状态（满足 ImportEngineProtocol）

    @Published private(set) var progress = ImportProgress()
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isRunning = false

    /// 最近一次导入里**真正写成功**的笔记 id。
    ///
    /// 界面用它决定"哪些勾选可以清掉"：失败的、跳过的、被拦下的一律保留，
    /// 用户回头才能直接重试。不能用 `imported` 标记判断——
    /// 覆盖型笔记本来 `imported == true`，失败了也还是 true，从标记上看不出区别。
    @Published private(set) var lastAppliedNoteIds: Set<String> = []

    // MARK: - 内部状态

    /// 本地笔记缓存。读正文与图片；导入结果（`imported` / `appleId`）写回它的索引。
    private let cache: NoteCacheProtocol

    /// 开始导入时缓存索引的快照。只读用途：挑笔记、算「已知的 appleId」。
    /// **不要拿它做整表写回**——写回前会重新 load 一次，见 `writeBackPairings`。
    private var cachedNotes: [CachedNote] = []

    /// `state.json` 的内存副本。
    ///
    /// 导入结果的**主记录**在缓存索引；state.json 这里继续维护一份对应记录，因为既有两条链路读的是它：
    ///   - `NoteAI.applyResult` 用 `state.notes[noteId].appleId` 定位写回目标；
    ///   - `recoverPendingBatchIfNeeded` 用 `state.pendingBatch` 做崩溃恢复。
    private var state: SyncState = SyncState()

    /// 本批 noteId -> 备忘录内部 id。配对成功后填上，文件夹归位时用它定位笔记。
    private var pairedAppleIds: [String: String] = [:]

    /// 用户请求取消。在安全点检查，不打断正在写的文件。
    private var cancelled = false

    /// ENEX 交给备忘录后，等笔记数涨够的超时（秒）
    private let importTimeout: TimeInterval = 90
    /// 导入轮询间隔（纳秒，1 秒）
    private let pollInterval: UInt64 = 1_000_000_000

    /// ENEX 导入的落点：没有小米文件夹归属的笔记留在这里。
    private static let inboxFolderName = "导入的备忘录"

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(cache: NoteCacheProtocol = NoteCache()) {
        self.cache = cache
    }

    // MARK: - 对外 API

    /// **只算不写**：把每条选中的笔记归到一个 `PlannedChange`。
    ///
    /// 分档规则（依据是可逆性，不是"写了多少"）：
    ///   - 没导入过 → `.create` + `.low`（走 ENEX 新建，用户自己能删）；
    ///   - 已导入过（有 appleId）→ `.overwrite` + `.high`（走 `set body` 原地覆盖，写掉找不回来）；
    ///   - 执行不了的填 `blockedReason`：含图片（覆盖会丢图）/ 正文被 AI 重构过 / 正文不在本地。
    ///     这些会出现在 `ChangePlan.blocked` 里如实展示，但**不进审批列表**（见 `needsApproval`）。
    ///
    /// `moves` 恒为空，理由：本方法是**同步**的（契约如此），没有机会去「备忘录」里回读
    /// 每条笔记当前落在哪个文件夹，凭猜写一份"哪些笔记需要移动"的清单，
    /// 恰恰违背审批机制赖以成立的"所见即所执行"。新建笔记的归位是新建动作的一部分
    /// （ENEX 导入后按 `folderName` 从「导入的备忘录」挪出），不单列成一条变更。
    func plan(noteIds: [String]) -> ChangePlan {
        var plan = ChangePlan()
        guard !noteIds.isEmpty else { return plan }

        // 只读快照：缓存索引 + state.json 各读一次。不落盘、不碰备忘录、不改内存状态。
        let stateSnapshot = SyncStateStore.load()
        let evaluations = evaluate(noteIds: noteIds,
                                   notes: cache.loadIndex().notes,
                                   state: stateSnapshot)

        for item in evaluations {
            switch item {
            case .create(let note, let content):
                plan.creates.append(Self.makeChange(note: note, kind: .create,
                                                    content: content, reason: nil))
            case .overwrite(let note, let content, _):
                plan.overwrites.append(Self.makeChange(note: note, kind: .overwrite,
                                                       content: content, reason: nil))
            case .blocked(let change):
                if change.kind == .overwrite {
                    plan.overwrites.append(change)
                } else {
                    plan.creates.append(change)
                }
            case .unknown:
                // 缓存索引里已经没有这条笔记（例如刚被下拉刷新移除）。它不会产生任何变更，
                // 就不占用 ChangePlan 的位；`start` 里同样跳过，两边行为一致。
                break
            }
        }
        return plan
    }

    func start(noteIds: [String], approvedOverwrites: Set<String>) async {
        // 空数组 = 用户在确认框里点了取消。**一个字节都不要写**，直接返回。
        guard !noteIds.isEmpty else { return }
        guard !isRunning else { return }

        isRunning = true
        cancelled = false
        logLines = []
        pairedAppleIds = [:]
        progress = ImportProgress(total: noteIds.count)
        state = SyncStateStore.load()

        do {
            try await runImport(noteIds: noteIds, approvedOverwrites: approvedOverwrites)
        } catch ImportEngineError.cancelled {
            log("导入已取消。")
            progress.phase = .idle
            progress.currentTitle = nil
        } catch {
            log("导入失败：\(error.localizedDescription)")
            progress.phase = .failed(error.localizedDescription)
            progress.currentTitle = nil
        }
        isRunning = false
    }

    func cancel() {
        cancelled = true
        log("收到取消请求，将在安全点停止…")
    }

    // MARK: - 主流程

    private func runImport(noteIds: [String], approvedOverwrites: Set<String>) async throws {
        recoverPendingBatchIfNeeded()

        // 每轮重算：上一轮写成功的 id 不该留到这一轮
        lastAppliedNoteIds = []

        // 1. 从缓存里取选中的笔记并分类。**不联网。**
        let index = cache.loadIndex()
        cachedNotes = index.notes
        let evaluations = evaluate(noteIds: noteIds, notes: index.notes, state: state)

        var batch: [PendingImport] = []        // 新建：走 ENEX 通道
        var overwrites: [OverwriteTask] = []   // 覆盖：走 set body 通道（**只收已授权的**）
        var unauthorized = 0
        var blockedCount = 0
        var unknownCount = 0

        for item in evaluations {
            switch item {
            case .create(let note, let content):
                batch.append(PendingImport(note: note, content: content))

            case .overwrite(let note, let content, let appleId):
                // ═══ 红绿灯机制的**唯一闸门** ═══
                // 覆盖是不可逆的写，只有用户逐条点过头的（noteId 在 approvedOverwrites 里）
                // 才允许进入执行队列。不在集合里的一条都不写——注意这里不是"执行时再筛"，
                // 而是未授权的那条**根本进不了 `overwrites`**，后面的执行循环因此不可能
                // 出现"顺手把没授权的一起做了"。
                guard approvedOverwrites.contains(note.id) else {
                    unauthorized += 1
                    log("笔记「\(note.title)」的正文覆盖未获授权，跳过（不写入任何内容）。")
                    continue
                }
                overwrites.append(OverwriteTask(note: note, content: content, appleId: appleId))

            case .blocked(let change):
                blockedCount += 1
                log("无法执行「\(change.title)」：\(change.blockedReason ?? "未知原因")。")

            case .unknown(let id):
                unknownCount += 1
                log("缓存里找不到笔记 \(id)，跳过。")
            }
        }

        // 进度分母 = 真正会执行的变更数（新建 + 已授权覆盖），跳过的不计。
        progress.total = batch.count + overwrites.count
        log("选中 \(noteIds.count) 条：新建 \(batch.count)，已授权覆盖 \(overwrites.count)，"
            + "未授权覆盖 \(unauthorized)，无法执行 \(blockedCount)，缓存中不存在 \(unknownCount)。")

        guard !batch.isEmpty || !overwrites.isEmpty else {
            log("没有可执行的变更，本次不写任何内容。")
            finish(created: 0, unpaired: 0, overwritten: 0, overwriteFailed: 0,
                   unauthorized: unauthorized, blocked: blockedCount, unknown: unknownCount)
            return
        }

        // 2. 组装 ENEX（只服务新建通道；覆盖通道不走 ENEX）。
        var enexNotes: [EnexNote] = []
        if !batch.isEmpty {
            progress.phase = .preparing
            enexNotes = try buildEnexNotes(batch)
        }

        // 3. 覆盖通道：原地改写已授权笔记的正文。
        //    排在 ENEX 之前执行，免得用户逐条审批过的高危写操作被后面
        //    「等备忘录导入完成」的漫长等待拖住（注释见下方各步骤）。
        progress.phase = .writing
        progress.currentTitle = nil
        var overwritten = 0
        var overwriteFailed = 0
        if !overwrites.isEmpty {
            let result = try await runOverwrites(overwrites)
            overwritten = result.done
            overwriteFailed = result.failed
        }

        // 4. 新建通道：写 ENEX 文件 → 交给备忘录 → 轮询确认
        if !batch.isEmpty {
            let enexURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiNoteBridge-\(UUID().uuidString).enex")
            try EnexWriter.write(notes: enexNotes, to: enexURL)
            let problems = EnexWriter.validate(EnexWriter.render(notes: enexNotes), expectedNotes: enexNotes.count)
            for p in problems { log("ENEX 校验警告：\(p)") }
            log("已生成 ENEX 文件（\(enexNotes.count) 条）：\(enexURL.path)")
            try guardCancelled()

            let beforeCount = try await NotesImporter.countNotes(inFolder: nil)
            log("导入前备忘录共有 \(beforeCount) 条笔记。")

            // 挂起批次。中途崩溃时，未配对成功的笔记下次会被重新导入，不会永远漏掉。
            state.pendingBatch = PendingBatch(file: enexURL.path,
                                              noteIds: batch.map { $0.note.id },
                                              expectedCount: enexNotes.count,
                                              createdAt: Date())
            saveState()

            progress.phase = .awaitingImport
            log("已把 ENEX 交给「备忘录」导入，等待导入完成…")
            if !NSWorkspace.shared.open(enexURL) {
                log("警告：未能自动打开 ENEX 文件，请在 Finder 中手动双击导入。")
            }

            // 轮询确认笔记数涨够
            let expected = beforeCount + enexNotes.count
            let deadline = Date().addingTimeInterval(importTimeout)
            var current = beforeCount
            while Date() < deadline {
                try guardCancelled()
                try? await Task.sleep(nanoseconds: pollInterval)
                do {
                    current = try await NotesImporter.countNotes(inFolder: nil)
                } catch {
                    log("统计笔记数失败：\(error.localizedDescription)")
                    break
                }
                if current >= expected { break }
            }
            if current >= expected {
                log("导入确认：笔记数 \(beforeCount) → \(current)。")
            } else {
                log("导入未在 \(Int(importTimeout)) 秒内确认（预期 \(expected)，当前 \(current)），仍将尝试配对。")
            }

            // 5. 回读配对 + 按文件夹归位
            //
            // 这里**不再检查取消**：笔记此刻已经进了用户的备忘录，配对是只读回读 + 写索引，
            // 不做的话下次会把这批笔记再导一遍、变成重复。取消从「文件夹归位」才开始生效。
            progress.phase = .organizingFolders
            try await pairImportedNotes(batch.map { $0.note })
            try await organizeImportedNotes(batch.map { $0.note })
        }

        finish(created: pairedAppleIds.count,
               unpaired: batch.count - pairedAppleIds.count,
               overwritten: overwritten,
               overwriteFailed: overwriteFailed,
               unauthorized: unauthorized,
               blocked: blockedCount,
               unknown: unknownCount)
    }

    // MARK: - 变更分类（plan 与 start 共用）

    /// 对一条选中笔记的判定结果。
    ///
    /// `plan` 与 `start` 都**只经由 `evaluate` 产生**——这是契约里
    /// 「审批时看到的和真正执行的是同一个东西」的落点，两边不允许各写一套逻辑。
    private enum NoteEvaluation {
        /// 没导入过 → 走 ENEX 新建（低危）
        case create(note: CachedNote, content: CachedNoteContent)
        /// 已导入过 → 走 `set body` 覆盖（高危，仍需逐条授权才能执行）
        case overwrite(note: CachedNote, content: CachedNoteContent, appleId: String)
        /// 判定为不可执行，附完整变更描述（`blockedReason` 已填）
        case blocked(PlannedChange)
        /// 缓存索引里已经没有这条笔记
        case unknown(id: String)
    }

    /// 逐条判定选中的笔记。**纯计算**：只读缓存与 state，不写任何东西。
    private func evaluate(noteIds: [String], notes: [CachedNote], state: SyncState) -> [NoteEvaluation] {
        let byId = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return noteIds.map { id in
            guard let note = byId[id] else { return .unknown(id: id) }
            let appleId = Self.importedAppleId(for: note, in: state)
            let content = cache.content(for: id)
            let kind: ChangeKind = appleId == nil ? .create : .overwrite

            // 「做了会坏事」的情况按严重度从高到低挡：
            // 1. AI 重构过——覆盖会冲掉用户花时间做的成果，**这条最不能漏**；
            // 2. 含图片——`set body` 写不进图片，覆盖一次丢一次图（只对覆盖成立：
            //    新建走 ENEX，图片由 ENEX 资源带着走，不受影响）；
            // 3. 正文不在本地——没有可写的内容。
            if Self.isAIModified(note, in: state) {
                return .blocked(Self.makeChange(note: note, kind: kind, content: content,
                                                reason: "正文被 AI 重构过，写回会冲掉重构成果，已跳过"))
            }
            guard note.hasBody, let content else {
                return .blocked(Self.makeChange(note: note, kind: kind, content: content,
                                                reason: "正文不在本地（还没拉取过），没有可写的内容"))
            }
            if appleId != nil, Self.containsImages(note: note, content: content) {
                return .blocked(Self.makeChange(note: note, kind: .overwrite, content: content,
                                                reason: "含图片，覆盖会丢图，已跳过"))
            }
            if let appleId {
                return .overwrite(note: note, content: content, appleId: appleId)
            }
            return .create(note: note, content: content)
        }
    }

    /// 组装一条 `PlannedChange`。风险等级由 kind 推出，不散在调用点上。
    private static func makeChange(note: CachedNote, kind: ChangeKind,
                                   content: CachedNoteContent?, reason: String?) -> PlannedChange {
        PlannedChange(noteId: note.id,
                      title: note.title,
                      kind: kind,
                      risk: kind == .overwrite ? .high : .low,
                      targetFolder: note.folderName,
                      preview: previewText(from: content?.html ?? ""),
                      blockedReason: reason)
    }

    /// 正文 HTML → 供审批阅读的纯文本摘要：去标签、还原实体、空白折叠，截前 120 字。
    /// 用户靠它判断「这条值不值得覆盖」。
    private static func previewText(from html: String, limit: Int = 120) -> String {
        guard !html.isEmpty else { return "" }
        var text = XiaomiConvert.replaceRegex("<[^>]+>", in: html) { _ in " " }
        text = XiaomiConvert.decodeEntities(text)
        text = XiaomiConvert.replaceRegex("\\s+", in: text) { _ in " " }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// 这条笔记在本地是否带着图片。三种来源取或：索引里的图片清单、缓存里真正存到的字节、
    /// 正文里的 `<img fileid="…"/>` 标记。
    /// **宁可误判成「有图」（挡下一次覆盖），也不能漏判**——漏判的后果是覆盖一次丢一次图。
    private static func containsImages(note: CachedNote, content: CachedNoteContent) -> Bool {
        if !note.imageFileIds.isEmpty { return true }
        if !content.images.isEmpty { return true }
        return content.html.contains("fileid=")
    }

    // MARK: - 覆盖通道（set body）

    /// 一条获授权、且判定为可执行的正文覆盖任务。
    private struct OverwriteTask {
        var note: CachedNote
        var content: CachedNoteContent
        /// 备忘录内部 id（`importedAppleId` 的结果；非空才可能走到这里）
        var appleId: String
    }

    /// 逐条执行覆盖。**入参只可能包含已授权的任务**（闸门在 `runImport` 的分类循环里）。
    /// 单条失败不抛出、只记日志——一条写不进去不该拖垮整批；返回成功/失败数供汇总。
    private func runOverwrites(_ tasks: [OverwriteTask]) async throws -> (done: Int, failed: Int) {
        var done = 0
        var failed = 0

        for task in tasks {
            try guardCancelled()
            progress.currentTitle = task.note.title
            do {
                try await NotesImporter.setBody(id: task.appleId,
                                                html: Self.overwriteBody(title: task.note.title,
                                                                         contentHTML: task.content.html))
                done += 1
                recordOverwrite(task)
                // 只有真正写完的才记进来：界面据此清勾选，
                // 失败的那条必须留在勾选里让用户重试
                lastAppliedNoteIds.insert(task.note.id)
                log("已覆盖「\(task.note.title)」的正文。")
            } catch {
                failed += 1
                log("覆盖「\(task.note.title)」失败：\(error.localizedDescription)")
            }
            progress.completed += 1
        }

        progress.currentTitle = nil
        log("覆盖通道完成：成功 \(done)/\(tasks.count) 条。")
        return (done, failed)
    }

    /// 覆盖成功后的落账：把 state.json 里这条的 `modifyDate` 推到刚写入的版本并标 synced。
    /// **不能省**：不落的话下次还会被当成「小米侧有改动」重新提案覆盖。
    private func recordOverwrite(_ task: OverwriteTask) {
        var record = state.notes[task.note.id] ?? NoteRecord(noteId: task.note.id,
                                                            modifyDate: task.note.modifyDate,
                                                            appleId: task.appleId,
                                                            bodyHash: nil,
                                                            title: task.note.title,
                                                            snippet: task.note.snippet,
                                                            aiModified: task.note.aiModified,
                                                            status: .synced)
        record.appleId = task.appleId
        record.modifyDate = task.note.modifyDate
        record.title = task.note.title
        record.snippet = task.note.snippet
        record.status = .synced
        state.notes[task.note.id] = record
        saveState()
    }

    /// 缓存正文（`toDisplayHTML` 的产物，为界面渲染准备）→ 可以交给 `set body` 的 HTML。
    ///
    /// **形态选择**：先过一遍与 ENEX 通道**同一条 ENML 清洗流水线**（`sanitizeToENML`，
    /// 图片元数据传空）。理由：
    ///   - 输出的标签集合与刚导入的笔记一模一样，都是「备忘录」在 ENEX 导入时已经接受的那一套；
    ///   - 缓存正文里的列表项是**裸 `<li>`**（小米输出没有 `<ul>` 外壳），清洗后会被补上外壳，
    ///     成为合法列表结构；
    ///   - 文本先解码实体再转义，输出一定是合法 HTML（缓存正文本身没做实体转义）；
    ///   - `imageMeta` 传空 → 万一正文里残留 `<img fileid>`，会被**整枚丢弃**而不是写出破损图片
    ///     （`set body` 写图片会变成 `base64,(null)`；含图笔记在分类阶段已被挡下，这是第二道闸门）。
    /// 已知取舍：列表的 `list-style-type` / 缩进样式不在 ENML 白名单里，会退化成普通项目，
    /// 表现与新导入的笔记一致（同一条流水线）。
    ///
    /// **标题补成正文第一行**：Apple 备忘录没有独立标题字段，标题就是正文的第一行
    /// （回读配对正是靠 `name` = 第一行来匹配的），而缓存正文里并不含标题。
    /// 不补的话，覆盖之后笔记会被重命名成正文首行、标题从笔记里消失。
    /// 正文自己已经以标题开头时不再重复补（小米的标题常常就是从正文首行推导出来的）。
    private static func overwriteBody(title: String, contentHTML: String) -> String {
        let body = XiaomiConvert.sanitizeToENML(contentHTML, imageMeta: [:])
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        if firstLine(of: body) == trimmed { return body }
        return "<h1>\(XiaomiConvert.escapeXML(trimmed))</h1>" + body
    }

    /// 取纯文本的第一行（判断正文是不是已经以标题开头时用）。
    /// 块级闭合标签先换成换行，再剥剩余标签——这样 `<div>a</div><div>b</div>` 的第一行是 `a` 而不是 `a b`。
    private static func firstLine(of html: String) -> String {
        let withBreaks = XiaomiConvert.replaceRegex("</(div|p|h1|h2|h3|li|blockquote|pre|tr|table)>",
                                                    in: html) { _ in "\n" }
        let text = XiaomiConvert.replaceRegex("<[^>]+>", in: withBreaks) { _ in "" }
        return XiaomiConvert.decodeEntities(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    // MARK: - 从缓存组装 ENEX

    /// 一条待导入的笔记：缓存里的元数据 + 已落盘的正文与图片。
    private struct PendingImport {
        var note: CachedNote
        var content: CachedNoteContent
    }

    /// 把缓存里的笔记组装成 `EnexNote`（**不联网**）。
    ///
    /// 转换链路：
    /// - 正文：缓存里存的是转换第一阶段的产物（`toHtmlFragment` / `toDisplayHTML` 的输出，
    ///   带 `<img fileid="…"/>` 标记），这里跑第二阶段的 `sanitizeToENML` 清洗成 ENML，
    ///   等价于原来的 `XiaomiConvert.toENMLBody`；
    /// - 图片：直接取缓存里的字节，md5 用于和正文里的 `<en-media>` 配对；
    /// - 标签：小米文件夹名，保持原语义。
    private func buildEnexNotes(_ batch: [PendingImport]) throws -> [EnexNote] {
        var notes: [EnexNote] = []
        for item in batch {
            try guardCancelled()
            progress.currentTitle = item.note.title

            var imageMeta: [String: (mime: String, hash: String)] = [:]
            var resources: [EnexResource] = []
            for fileId in item.note.imageFileIds {
                guard let data = item.content.images[fileId] else {
                    log("图片 \(fileId) 在缓存里缺失，正文中将显示占位。")
                    continue
                }
                let mime = Self.imageMIME(data)
                let res = EnexResource(data: data, mime: mime, filename: "\(fileId).\(Self.imageExt(mime))")
                resources.append(res)
                imageMeta[fileId] = (mime: mime, hash: res.md5)
            }

            let body = XiaomiConvert.sanitizeToENML(item.content.html, imageMeta: imageMeta)
            notes.append(EnexNote(
                title: item.note.title,
                body: body,
                created: Date(timeIntervalSince1970: item.note.createDate / 1000),
                updated: Date(timeIntervalSince1970: item.note.modifyDate / 1000),
                tags: item.note.folderName.isEmpty ? [] : [item.note.folderName],
                resources: resources
            ))
            progress.completed += 1
        }
        return notes
    }

    /// 从字节头判断图片类型。缓存里只存字节、不存 MIME，而 ENEX 的资源必须声明类型，所以在这里认。
    /// 认不出来时回落 PNG——和界面侧 `imageMimeType` 的约定一致。
    private static func imageMIME(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            return "image/webp"
        }
        return "image/png"
    }

    private static func imageExt(_ mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "png"
        }
    }

    // MARK: - 回读配对

    /// 导入是异步的，程序无法立刻知道 ENEX 里的哪条笔记对应哪条备忘录。
    /// 所以在「导入的备忘录」里回读一遍，用标题 / 创建时间把两边配对，
    /// 把 `imported` 与 `appleId` 写回缓存索引（并同步一份到 state.json）。
    ///
    /// 只服务于**新建通道**：覆盖通道的 appleId 早就有了，不参与、也不该重复配对。
    private func pairImportedNotes(_ imported: [CachedNote]) async throws {
        let appleNotes = try await NotesImporter.listNotes(inFolder: Self.inboxFolderName)
        var knownIds = Set(cachedNotes.compactMap { $0.appleId }.filter { !$0.isEmpty })
        knownIds.formUnion(state.notes.values.compactMap { $0.appleId })
        var fresh = appleNotes.filter { !knownIds.contains($0.id) }
        log("回读到「导入的备忘录」共 \(appleNotes.count) 条，其中新出现 \(fresh.count) 条待配对。")

        var paired = 0
        for note in imported {
            try guardCancelled()
            let miCreated = Date(timeIntervalSince1970: note.createDate / 1000)
            guard let matched = bestMatch(for: note, miCreated: miCreated, in: fresh) else {
                log("未能配对笔记「\(note.title)」（标题+创建时间都不匹配），保留为待确认。")
                continue
            }
            fresh.removeAll { $0.id == matched.id }
            pairedAppleIds[note.id] = matched.id

            state.notes[note.id] = NoteRecord(noteId: note.id, modifyDate: note.modifyDate,
                                              appleId: matched.id, bodyHash: nil,
                                              title: note.title, snippet: note.snippet,
                                              aiModified: note.aiModified, status: .synced)
            paired += 1
        }
        log("配对完成：成功 \(paired)/\(imported.count)。")

        // 立刻落盘：后面即使文件夹归位失败、或用户取消，配对结果也不会丢——
        // 丢了的话下次会把已导入的笔记再导一遍，变成重复。
        writeBackPairings()
        saveState()
    }

    /// 标题精确匹配优先；同名多条时按创建时间就近挑；标题无匹配时按创建时间兜底（容差 10 分钟）。
    private func bestMatch(for note: CachedNote, miCreated: Date, in pool: [AppleNote]) -> AppleNote? {
        let titleMatches = pool.filter { $0.name == note.title }
        if titleMatches.count == 1 { return titleMatches[0] }
        if titleMatches.count > 1 {
            return titleMatches.min { createdDistance($0.created, to: miCreated) < createdDistance($1.created, to: miCreated) }
        }
        let tolerance: TimeInterval = 10 * 60
        return pool
            .filter { apple in apple.created.map { abs($0.timeIntervalSince(miCreated)) < tolerance } ?? false }
            .min { createdDistance($0.created, to: miCreated) < createdDistance($1.created, to: miCreated) }
    }

    private func createdDistance(_ date: Date?, to target: Date) -> TimeInterval {
        date.map { abs($0.timeIntervalSince(target)) } ?? .greatestFiniteMagnitude
    }

    // MARK: - 按文件夹归位

    /// 把刚导入并配对成功的笔记，从「导入的备忘录」挪进小米文件夹名对应的文件夹。
    ///
    /// 流程：
    /// 1. 收集这批里「有小米文件夹归属」的笔记（没有归属的留在「导入的备忘录」）；
    /// 2. `ensureFolders` 确保每个目标文件夹都存在（同名复用、缺则新建）；
    /// 3. 逐条 `moveNote` 按笔记 id 移动。
    ///
    /// **必须在配对之后做**：配对是从「导入的备忘录」里回读的，先移动会让它找不到笔记。
    /// 单条移动失败不抛出，只记日志——文件夹结构属于锦上添花，不该拖垮整次导入。
    ///
    /// 入参是**实际执行了新建的集合**（已授权覆盖不在这里：覆盖只改正文，不挪位置——
    /// 那条笔记是用户此前导入的，可能已经被他手动归置过，替用户"归位"是越权）。
    private func organizeImportedNotes(_ imported: [CachedNote]) async throws {
        var targets: [String: String] = [:]   // noteId -> 目标文件夹名
        for note in imported {
            guard pairedAppleIds[note.id] != nil else { continue }
            if !note.folderName.isEmpty { targets[note.id] = note.folderName }
        }
        guard !targets.isEmpty else {
            log("这批新笔记没有归属文件夹，跳过文件夹归位。")
            return
        }

        let folderNames = Set(targets.values)
        log("开始建立文件夹结构：涉及 \(folderNames.count) 个文件夹。")
        let ready = try await ensureFolders(named: folderNames)

        var moved = 0
        for note in imported {
            try guardCancelled()
            guard let folderName = targets[note.id],
                  let appleId = pairedAppleIds[note.id] else { continue }
            guard ready.contains(folderName) else {
                log("文件夹「\(folderName)」未能就绪，笔记「\(note.title)」留在原处。")
                continue
            }
            progress.currentTitle = note.title
            do {
                try await NotesImporter.moveNote(id: appleId, toFolder: folderName)
                moved += 1
            } catch {
                log("移动笔记「\(note.title)」到「\(folderName)」失败：\(error.localizedDescription)")
            }
        }
        progress.currentTitle = nil
        log("文件夹归位完成：\(moved)/\(targets.count) 条已移动。")
    }

    /// 确保这些文件夹在「备忘录」里都已存在，返回「已就绪的文件夹名集合」。
    ///
    /// 先列出全部文件夹，**同名即复用**，只有确实缺失才新建，
    /// 避免反复导入把同名文件夹越建越多（`createFolder(named:)` 自身也做了同名兜底）。
    private func ensureFolders(named names: Set<String>) async throws -> Set<String> {
        var existing = Set<String>()
        for folder in try await NotesImporter.listFoldersWithIDs() {
            existing.insert(folder.name)
        }
        var ready = Set<String>()
        for name in names {
            if existing.contains(name) {
                ready.insert(name)
                continue
            }
            do {
                _ = try await NotesImporter.createFolder(named: name)
                ready.insert(name)
                log("已在「备忘录」中创建文件夹「\(name)」。")
            } catch {
                log("创建文件夹「\(name)」失败：\(error.localizedDescription)")
            }
        }
        return ready
    }

    // MARK: - 收尾与辅助

    /// 收尾。
    ///
    /// 结尾这句汇总**要把各档数量都带上**：界面上只显示最后一行日志，
    /// 逐条的「已跳过…」会被后续行顶掉，不汇总的话用户看不到「为什么少了 N 条」。
    /// 尤其是「未授权覆盖 N 条」——用户必须能在结果里确认"没点头的确实一条都没写"。
    private func finish(created: Int, unpaired: Int, overwritten: Int, overwriteFailed: Int,
                        unauthorized: Int, blocked: Int, unknown: Int) {
        state.lastSyncAt = Date()
        state.pendingBatch = nil
        saveState()
        progress.completed = progress.total
        progress.phase = .finished
        progress.currentTitle = nil

        var groups: [String] = []
        var skipParts: [String] = []
        if unauthorized > 0 { skipParts.append("未授权覆盖 \(unauthorized)") }
        if blocked > 0 { skipParts.append("无法执行 \(blocked)") }
        if unknown > 0 { skipParts.append("缓存中不存在 \(unknown)") }
        let skippedTotal = unauthorized + blocked + unknown
        if skippedTotal > 0 { groups.append("跳过 \(skippedTotal) 条：" + skipParts.joined(separator: "、")) }
        if overwriteFailed > 0 { groups.append("覆盖失败 \(overwriteFailed) 条，可重试") }
        if unpaired > 0 { groups.append("另有 \(unpaired) 条未能配对，可重试") }
        let suffix = groups.isEmpty ? "" : "（" + groups.joined(separator: "；") + "）"
        log("导入完成：新建 \(created) 条、覆盖 \(overwritten) 条\(suffix)。")
    }

    /// 上次运行若在「交给备忘录导入 → 配对确认」之间崩溃，会留下一个挂起批次。
    /// 未确认（没有 appleId）的笔记从状态里移除，让它们下次重新导入，避免永远漏掉。
    private func recoverPendingBatchIfNeeded() {
        guard let batch = state.pendingBatch else { return }
        log("检测到上次未完成的导入批次（\(batch.noteIds.count) 条），未确认的笔记将重新导入。")
        for id in batch.noteIds where state.notes[id]?.appleId == nil {
            state.notes.removeValue(forKey: id)
        }
        state.pendingBatch = nil
    }

    /// 这条笔记在「备忘录」里的 id（若已导入过）。
    ///
    /// 两个账本都查：缓存索引是主账本；state.json 是副账本——
    /// 小米侧被删掉/移出的笔记会从缓存索引里消失（拉取以远端列表为准重建），
    /// 但 state.json 里还留着记录。只查缓存的话，这种笔记之后再出现就会被重复导入。
    ///
    /// 返回非空即意味着这条笔记会走**覆盖通道**（需要逐条授权）。
    private static func importedAppleId(for note: CachedNote, in state: SyncState) -> String? {
        if note.imported, let appleId = note.appleId, !appleId.isEmpty { return appleId }
        if let appleId = state.notes[note.id]?.appleId, !appleId.isEmpty { return appleId }
        return nil
    }

    /// 这条笔记的正文是否被 AI 重构过。
    ///
    /// 两个来源都查：AI 重构的标记记在 `state.json`（`NoteAI.applyResult` 写的），
    /// 缓存索引里也有一份 `aiModified`。任一处为 true 都按「不可写」处理——
    /// 宁可漏导一条，也不能冲掉用户花时间做的重构成果。
    private static func isAIModified(_ note: CachedNote, in state: SyncState) -> Bool {
        note.aiModified || (state.notes[note.id]?.aiModified ?? false)
    }

    /// 把本批配对成功的 `imported` / `appleId` 写回缓存索引。
    ///
    /// **写回前重新 load 一次索引，只为配上的这几条打补丁**：
    /// 索引是拉取侧也在写的共享账本，拿开始时的旧快照整表覆盖，
    /// 会把期间拉取新写入的笔记冲掉（lost update）。
    private func writeBackPairings() {
        let latest = cache.loadIndex()
        var notes = latest.notes
        for i in notes.indices {
            if let appleId = pairedAppleIds[notes[i].id] {
                notes[i].imported = true
                notes[i].appleId = appleId
            }
        }
        do {
            try cache.saveIndex(notes: notes, folders: latest.folders)
        } catch {
            log("保存缓存索引失败：\(error.localizedDescription)")
        }
    }

    private func saveState() {
        do {
            try SyncStateStore.save(state)
        } catch {
            log("保存同步状态失败：\(error.localizedDescription)")
        }
    }

    private func guardCancelled() throws {
        if cancelled { throw ImportEngineError.cancelled }
    }

    private func log(_ message: String) {
        let line = "[\(Self.logTimeFormatter.string(from: Date()))] \(message)"
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }
}

/// 引擎内部错误：把「用户取消」和真正的失败区分开，取消不该被当成异常展示给用户。
enum ImportEngineError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled: return "导入已取消。"
        }
    }
}
