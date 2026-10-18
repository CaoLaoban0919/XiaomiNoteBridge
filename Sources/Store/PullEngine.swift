import Foundation
import Combine

@MainActor
final class PullEngine: ObservableObject, PullEngineProtocol {

    @Published private(set) var progress = PullProgress()
    @Published private(set) var logLines: [String] = []
    @Published private(set) var notes: [CachedNote] = []
    @Published private(set) var folders: [CachedFolder] = []
    @Published private(set) var isRunning = false

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

    func reloadFromCache() async {

        guard !isRunning else { return }
        let (cachedNotes, cachedFolders) = cache.loadIndex()
        notes = cachedNotes.sorted { $0.modifyDate > $1.modifyDate }
        folders = cachedFolders.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        progress.total = notes.count
        progress.completed = notes.count
        log("已从本地缓存载入 \(notes.count) 条笔记、\(folders.count) 个文件夹（离线可看）。")
    }

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

    private func runPull() async throws {
        guard let cookie = CredentialsStore.loadCookie(),
              !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            progress.phase = .failed("未登录")
            log("未找到小米账号 Cookie，无法拉取。")
            return
        }
        let api = MiAPI(cookie: cookie)

        progress.phase = .fetchingList
        log("开始拉取小米笔记列表…")
        let (metas, folderNames) = try await fetchAllPages(api: api)
        try guardCancelled()
        log("共拉取 \(metas.count) 条笔记，涉及 \(folderNames.count) 个文件夹。")

        var merge = mergeWithCache(metas: metas, folderNames: folderNames)
        log("增量比对完成：\(merge.reused) 条未变（复用本地），"
            + "\(merge.toFetch.count) 条需要拉取正文，\(merge.toPatch.count) 条只缺图片。")
        progress.completed = 0
        progress.total = merge.toFetch.count + merge.toPatch.count

        try await pullContents(api: api, merge: &merge)

        if let noteCache = concreteCache {
            try await patchImages(api: api, patches: merge.toPatch, cache: noteCache)
        }

        try guardCancelled()

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

            guard let next = p.syncTag, !next.isEmpty, next != tag else { break }
            tag = next
        }
        return (metas, folders)
    }

    private struct MergeResult {
        var notes: [CachedNote] = []
        var folders: [CachedFolder] = []

        var toFetch: [MiNoteMeta] = []

        var toPatch: [ImagePatch] = []

        var indexById: [String: Int] = [:]

        var reused = 0
    }

    private struct ImagePatch {
        var meta: MiNoteMeta

        var missing: [String]
    }

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

            guard seen.insert(meta.id).inserted else { continue }
            let prev = previous[meta.id]
            let folderName = meta.folderId.isEmpty
                ? ""
                : (folderNames[meta.folderId] ?? previousFolderNames[meta.folderId] ?? "未命名文件夹")
            if !meta.folderId.isEmpty { counts[meta.folderId, default: 0] += 1 }

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

                    result.toPatch.append(ImagePatch(meta: meta, missing: missing))
                } else {

                    result.toFetch.append(meta)
                }
            } else {
                result.toFetch.append(meta)
            }
            result.indexById[meta.id] = result.notes.count
            result.notes.append(note)
        }

        var folderIds = Set(folderNames.keys)
        folderIds.formUnion(counts.keys)
        result.folders = folderIds.map { id in
            CachedFolder(id: id,
                         name: folderNames[id] ?? previousFolderNames[id] ?? "未命名文件夹",
                         noteCount: counts[id] ?? 0)
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        return result
    }

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

                if firstError == nil { firstError = error }
                log("正文拉取失败（\(meta.title)，\(meta.id)）：\(error.localizedDescription)")
            }
            progress.completed += 1
        }
        progress.currentTitle = nil

        if progress.notesPulled == 0, let error = firstError {
            throw error
        }
    }

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

                    progress.imagesFailed += 1
                    log("补图失败（\(patch.meta.title) / \(fileId)）：\(error.localizedDescription)")
                }
            }
            progress.completed += 1
        }
        progress.currentTitle = nil
    }

    private var concreteCache: NoteCache? { cache as? NoteCache }

    private func hasLocalImage(fileId: String) -> Bool {
        if let noteCache = concreteCache {
            return noteCache.hasImage(fileId: fileId)
        }
        return cache.imageData(fileId: fileId) != nil
    }

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

enum PullEngineError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled: return "拉取已取消。"
        }
    }
}
