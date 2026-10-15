import Foundation
import Combine

/// 只读拉取引擎：小米笔记 → 本地缓存。
///
/// **本文件里不允许出现任何写 Apple 备忘录的调用**——这是「拉取 / 导入」拆分后的核心约定：
/// 看笔记这件事必须完全无副作用。写备忘录的活全部归 ImportEngine（用户手动确认之后才做）。
///
/// 纯逻辑层，不 import SwiftUI；`ObservableObject` / `@Published` 来自 Combine，供界面观察。
@MainActor
final class PullEngine: ObservableObject, PullEngineProtocol {

    // MARK: - 可观察状态（满足 PullEngineProtocol）

    @Published private(set) var progress = PullProgress()
    @Published private(set) var logLines: [String] = []
    @Published private(set) var notes: [CachedNote] = []
    @Published private(set) var folders: [CachedFolder] = []
    @Published private(set) var isRunning = false

    // MARK: - 内部状态

    private let cache: NoteCacheProtocol
    private var cancelled = false

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(cache: NoteCacheProtocol = NoteCache()) {
        self.cache = cache
    }

    // MARK: - 只读缓存

    func reloadFromCache() async {
        // 拉取进行中不要用旧索引盖掉正在更新的列表
        guard !isRunning else { return }
        let (cachedNotes, cachedFolders) = cache.loadIndex()
        notes = cachedNotes.sorted { $0.modifyDate > $1.modifyDate }
        folders = cachedFolders.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        progress.total = notes.count
        progress.completed = notes.count
        log("已从本地缓存载入 \(notes.count) 条笔记、\(folders.count) 个文件夹（离线可看）。")
    }

    // MARK: - 对外 API

    func pull() async {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        logLines = []
        progress = PullProgress()

        do {
            try await runPull()
        } catch PullEngineError.cancelled {
            log("拉取已取消。")
            progress.phase = .idle
            progress.currentTitle = nil
        } catch {
            log("拉取失败：\(error.localizedDescription)")
            progress.phase = .failed(error.localizedDescription)
            progress.currentTitle = nil
        }
        isRunning = false
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        log("收到取消请求，将在安全点停止…")
    }

    // MARK: - 主流程

    private func runPull() async throws {
        guard let cookie = CredentialsStore.loadCookie(),
              !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            progress.phase = .failed("未登录")
            log("未找到小米账号 Cookie，无法拉取。")
            return
        }
        let api = MiAPI(cookie: cookie)

        // 1) 列表：分页拉全量
        progress.phase = .fetchingList
        log("开始拉取小米笔记列表…")
        let (metas, folderNames) = try await fetchAllPages(api: api)
        try guardCancelled()
        log("共拉取 \(metas.count) 条笔记，涉及 \(folderNames.count) 个文件夹。")

        // 2) 与缓存比对：没有变化的直接复用，不重复拉正文和图片；
        //    「正文没变但上一轮有图没下下来」的笔记单独走补图。
        var merge = mergeWithCache(metas: metas, folderNames: folderNames)
        log("增量比对完成：\(merge.reused) 条未变（复用本地），"
            + "\(merge.toFetch.count) 条需要拉取正文，\(merge.toPatch.count) 条只缺图片。")
        progress.completed = 0
        progress.total = merge.toFetch.count + merge.toPatch.count

        // 3) 正文 + 图片
        try await pullContents(api: api, merge: &merge)

        // 3.5) 只缺图的：单张补齐，已下好的不重下。
        // 注意 toPatch 只在 concreteCache 存在时才产生（见 mergeWithCache），所以这里不需要 else。
        if let noteCache = concreteCache {
            try await patchImages(api: api, patches: merge.toPatch, cache: noteCache)
        }

        try guardCancelled()

        // 4) 落索引。
        // 拉取要跑好几分钟，期间导入引擎可能已经写回了 imported/appleId。
        // 落盘前用磁盘上的最新值对齐一次，别把导入成果覆盖回旧快照。
        // 这里到 saveIndex 之间没有 await，窗口可以忽略。
        notes = reconcileImportState(merge.notes.sorted { $0.modifyDate > $1.modifyDate })
        folders = merge.folders
        try cache.saveIndex(notes: notes, folders: folders)
        log("索引已写入缓存。")

        progress.phase = .finished
        progress.completed = progress.total
        progress.currentTitle = nil
        log("拉取完成：正文 \(progress.notesPulled) 条、复用 \(merge.reused) 条、补图 \(merge.toPatch.count) 条、"
            + "图片成功 \(progress.imagesDownloaded) 张 / 失败 \(progress.imagesFailed) 张。")
    }

    // MARK: - 拉取列表

    private func fetchAllPages(api: MiAPI) async throws -> ([MiNoteMeta], [String: String]) {
        var metas: [MiNoteMeta] = []
        var folders: [String: String] = [:]
        var tag: String?
        var page = 0
        while true {
            try guardCancelled()
            let p = try await api.fetchPage(syncTag: tag, limit: 200)
            metas.append(contentsOf: p.entries)
            for (k, v) in p.folders { folders[k] = v }
            page += 1
            log("第 \(page) 页：\(p.entries.count) 条。")
            if p.lastPage { break }
            // syncTag 没往前走就停下——否则会拿着同一个 tag 无限翻页。
            guard let next = p.syncTag, !next.isEmpty, next != tag else { break }
            tag = next
        }
        return (metas, folders)
    }

    // MARK: - 增量比对

    private struct MergeResult {
        var notes: [CachedNote] = []
        var folders: [CachedFolder] = []
        /// 需要拉正文/图片的笔记（新增、改动过、或正文还没拉到的）
        var toFetch: [MiNoteMeta] = []
        /// 正文没变、但上一次有图片没下下来的笔记
        var toPatch: [ImagePatch] = []
        /// noteId -> notes 下标，正文拉完后回填 hasBody
        var indexById: [String: Int] = [:]
        /// 直接复用本地缓存的条数
        var reused = 0
    }

    /// 「正文没变，只缺这几张图」
    private struct ImagePatch {
        var meta: MiNoteMeta
        /// 本地缺失、需要补下的图片 fileId
        var missing: [String]
    }

    /// 把这次列表的结果与本地缓存合并：
    /// - 标题、文件夹、附件列表等元数据**以这次拉到的为准**；
    /// - `imported` / `appleId` / `aiModified` 这些本地状态**沿用缓存**，
    ///   不能被列表页数据冲掉——`imported`/`appleId` 是导入引擎的账本，
    ///   `aiModified` 是用户 AI 重构过的成果标记；
    /// - 增量判断：**已在缓存 + `modifyDate` 没变 + 正文已在本地 + 该有的图片都在本地**。
    ///   图片缺一张就要重新处理，否则上次下失败的图永远补不回来。
    /// - 小米侧删除的笔记**不做墓碑**：都删了就不需要再导入，账本丢了也只影响
    ///   「已导入」的显示，而它已经不在列表里了（不给 CachedNote 加字段）。
    private func mergeWithCache(metas: [MiNoteMeta], folderNames: [String: String]) -> MergeResult {
        let (cachedNotes, cachedFolders) = cache.loadIndex()
        var previous: [String: CachedNote] = [:]
        for n in cachedNotes { previous[n.id] = n }
        var previousFolderNames: [String: String] = [:]
        for f in cachedFolders { previousFolderNames[f.id] = f.name }

        var result = MergeResult()
        var seen = Set<String>()
        var counts: [String: Int] = [:]

        for meta in metas {
            // 分页偶发重复时只按第一条算，别让列表出现重复 id。
            guard seen.insert(meta.id).inserted else { continue }
            let prev = previous[meta.id]
            let folderName = meta.folderId.isEmpty
                ? ""
                : (folderNames[meta.folderId] ?? previousFolderNames[meta.folderId] ?? "未命名文件夹")
            if !meta.folderId.isEmpty { counts[meta.folderId, default: 0] += 1 }

            // 只有「版本一致 + 正文在本地」才算正文可用。改动过但这次没拉成功的，
            // hasBody 必须保持 false，否则会把旧正文永久当成新版内容，改动再也拉不进来。
            let sameVersion = prev != nil && prev!.modifyDate == meta.modifyDate && prev!.hasBody

            let note = CachedNote(
                id: meta.id,
                title: meta.title,
                snippet: meta.snippet,
                folderId: meta.folderId,
                folderName: folderName,
                createDate: meta.createDate,
                modifyDate: meta.modifyDate,
                fileIds: meta.files.map { $0.fileId },
                imageFileIds: meta.files.filter { $0.isImage }.map { $0.fileId },
                hasBody: sameVersion,
                imported: prev?.imported ?? false,
                appleId: prev?.appleId,
                aiModified: prev?.aiModified ?? false
            )

            if sameVersion {
                let missing = note.imageFileIds.filter { !hasLocalImage(fileId: $0) }
                if missing.isEmpty {
                    result.reused += 1
                } else if concreteCache != nil {
                    // 只补缺的那几张，不重下正文和已有图片。
                    result.toPatch.append(ImagePatch(meta: meta, missing: missing))
                } else {
                    // 缓存实现不支持单图落盘（NoteCache 之外的情况），整条重拉。
                    result.toFetch.append(meta)
                }
            } else {
                result.toFetch.append(meta)
            }
            result.indexById[meta.id] = result.notes.count
            result.notes.append(note)
        }

        // 文件夹：这次返回的 + 笔记实际用到的，noteCount 现算。
        var folderIds = Set(folderNames.keys)
        folderIds.formUnion(counts.keys)
        result.folders = folderIds.map { id in
            CachedFolder(id: id,
                         name: folderNames[id] ?? previousFolderNames[id] ?? "未命名文件夹",
                         noteCount: counts[id] ?? 0)
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        return result
    }

    // MARK: - 拉正文与图片

    private func pullContents(api: MiAPI, merge: inout MergeResult) async throws {
        let toFetch = merge.toFetch
        progress.phase = .fetchingBodies

        guard !toFetch.isEmpty else {
            log("没有需要拉取正文的笔记。")
            return
        }

        var firstError: Error?
        for meta in toFetch {
            try guardCancelled()
            progress.phase = .fetchingBodies
            progress.currentTitle = meta.title
            do {
                let detail = try await api.fetchDetail(id: meta.id)
                try guardCancelled()
                // 思维导图的分流收在 XiaomiConvert 里，这里只用 toDisplayHTML，
                // 不要自己判断 isMindMap，更不要用 toHtmlFragment（会解析出乱码）。
                let html = XiaomiConvert.toDisplayHTML(detail.content, files: detail.meta.files)

                let imageFiles = detail.meta.files.filter { $0.isImage }
                var images: [String: Data] = [:]
                if !imageFiles.isEmpty { progress.phase = .downloadingImages }
                for file in imageFiles {
                    try guardCancelled()
                    do {
                        let bytes = try await api.fetchFile(fileId: file.fileId)
                        images[file.fileId] = bytes
                        progress.imagesDownloaded += 1
                    } catch {
                        // 单张图失败不中断整批：正文和其他图仍然要落盘。
                        progress.imagesFailed += 1
                        log("图片下载失败（\(meta.title) / \(file.fileId)）：\(error.localizedDescription)")
                    }
                }

                try cache.saveContent(CachedNoteContent(html: html, images: images), for: meta.id)
                if let idx = merge.indexById[meta.id] { merge.notes[idx].hasBody = true }
                progress.notesPulled += 1
            } catch PullEngineError.cancelled {
                throw PullEngineError.cancelled
            } catch {
                // 单条失败不中断整批；hasBody 保持 false，下次拉取会重试这一条。
                if firstError == nil { firstError = error }
                log("正文拉取失败（\(meta.title)，\(meta.id)）：\(error.localizedDescription)")
            }
            progress.completed += 1
        }
        progress.currentTitle = nil

        // 一条都没成功且有明确错误：大概率不是「某条笔记的问题」（典型是 Cookie 中途失效），
        // 交给上层把整个拉取标成 failed。
        if progress.notesPulled == 0, let error = firstError {
            throw error
        }
    }

    // MARK: - 补图

    /// 正文没变、但上一次有图片没下下来（或下载后写入失败）的笔记，只补缺的那几张。
    /// 正文、已有图片都不重下——这是「单张图失败不中断整批」的配套修复：
    /// 失败了不能直接把这张图永久判死刑。
    private func patchImages(api: MiAPI, patches: [ImagePatch], cache noteCache: NoteCache) async throws {
        guard !patches.isEmpty else { return }
        progress.phase = .downloadingImages
        log("\(patches.count) 条笔记的正文未变但缺图片，开始补图…")

        for patch in patches {
            try guardCancelled()
            progress.currentTitle = patch.meta.title
            for fileId in patch.missing {
                try guardCancelled()
                do {
                    let bytes = try await api.fetchFile(fileId: fileId)
                    try noteCache.saveImage(bytes, fileId: fileId)
                    progress.imagesDownloaded += 1
                } catch {
                    // 还是失败就继续留在「缺失」状态，下次拉取会再试，不会被永久跳过。
                    progress.imagesFailed += 1
                    log("补图失败（\(patch.meta.title) / \(fileId)）：\(error.localizedDescription)")
                }
            }
            progress.completed += 1
        }
        progress.currentTitle = nil
    }

    // MARK: - 辅助

    /// 具体实现，用于契约之外的轻量操作（`hasImage`）。NoteCache 是唯一实现。
    private var concreteCache: NoteCache? { cache as? NoteCache }

    /// 图片是否已在本地。优先用 NoteCache 的轻量检查（只 stat、不读字节）；
    /// 其它实现退化为读一次字节。
    private func hasLocalImage(fileId: String) -> Bool {
        if let noteCache = concreteCache {
            return noteCache.hasImage(fileId: fileId)
        }
        return cache.imageData(fileId: fileId) != nil
    }

    /// 把缓存里最新的「导入侧字段」（imported / appleId / aiModified）贴回本轮结果。
    /// 归属约定：这三个字段由导入侧 / AI 侧写，拉取只负责别冲掉它们。
    private func reconcileImportState(_ notes: [CachedNote]) -> [CachedNote] {
        let (cached, _) = cache.loadIndex()
        guard !cached.isEmpty else { return notes }
        var latest: [String: CachedNote] = [:]
        for n in cached { latest[n.id] = n }
        return notes.map { note in
            guard let fresh = latest[note.id] else { return note }
            var merged = note
            merged.imported = fresh.imported
            merged.appleId = fresh.appleId
            merged.aiModified = fresh.aiModified
            return merged
        }
    }

    private func guardCancelled() throws {
        if cancelled { throw PullEngineError.cancelled }
    }

    private func log(_ message: String) {
        logLines.append("[\(Self.logTimeFormatter.string(from: Date()))] \(message)")
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }
}

/// 拉取引擎内部错误。取消是正常流程的一部分，和真正的失败分开处理。
enum PullEngineError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled: return "拉取已取消。"
        }
    }
}
