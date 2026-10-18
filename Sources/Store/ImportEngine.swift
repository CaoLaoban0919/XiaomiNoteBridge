import Foundation
import Combine
import AppKit

@MainActor
final class ImportEngine: ObservableObject, ImportEngineProtocol {
    struct Services {
        var loadState: () -> SyncState = { SyncStateStore.load() }
        var saveState: (SyncState) throws -> Void = { try SyncStateStore.save($0) }
        var countNotes: () async throws -> Int = { try await NotesImporter.countNotes(inFolder: nil) }
        var listNotes: (String) async throws -> [AppleNote] = { try await NotesImporter.listNotes(inFolder: $0) }
        var listAllNotes: () async throws -> [AppleNote] = { try await NotesImporter.listNotes(inFolder: nil) }
        var openENEX: (URL) async throws -> Void = { url in
            let result = try await ScriptProcess.run(executable: URL(fileURLWithPath: "/usr/bin/open"),
                                                     arguments: ["-b", NotesBridge.notesBundleID, url.path], timeout: 10)
            guard result.status == 0 else { throw ImportEngineError.openFailed(url.path, result.stderr) }
        }
        var renderHTML: (String) async throws -> String = { try await MathImageRenderer.exportHTML($0) }
        var setBody: (String, String) async throws -> Void = { try await NotesImporter.setBody(id: $0, html: $1) }
        var folders: () async throws -> [AppleFolder] = { try await NotesImporter.listFoldersWithIDs() }
        var createFolder: (String) async throws -> String = { try await NotesImporter.createFolder(named: $0) }
        var moveNote: (String, String) async throws -> Void = { try await NotesImporter.moveNote(id: $0, toFolder: $1) }
        var importTimeout: TimeInterval = 90
        var pollInterval: UInt64 = 1_000_000_000
    }

    @Published private(set) var progress = ImportProgress()
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isRunning = false

    @Published private(set) var lastAppliedNoteIds: Set<String> = []
    @Published private(set) var pendingFileURL: URL?

    private let cache: NoteCacheProtocol
    private let services: Services

    private var cachedNotes: [CachedNote] = []

    private var state: SyncState = SyncState()

    private var pairedAppleIds: [String: String] = [:]

    private var cancelled = false
    private var activeTask: Task<Void, Error>?


    private static let inboxFolderName = "导入的备忘录"

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(cache: NoteCacheProtocol = NoteCache(), services: Services = Services()) {
        self.cache = cache
        self.services = services
    }

    func plan(noteIds: [String]) -> ChangePlan {
        var plan = ChangePlan()
        guard !noteIds.isEmpty else { return plan }

        let stateSnapshot = services.loadState()
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

                break
            }
        }
        return plan
    }

    /// Export a standalone snapshot, including notes that cannot be overwritten in Notes.
    /// Does not contact Notes, create pending batches, or change existing pairings.
    func copyFileData(noteIds: [String]) async throws -> Data {
        let byID = Dictionary(cache.loadIndex().notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var batch: [PendingImport] = []
        var seen: Set<String> = []
        for id in noteIds where seen.insert(id).inserted {
            try Task.checkCancellation()
            guard let note = byID[id], note.hasBody, let html = cache.html(for: id) else {
                throw ImportEngineError.missingContent(byID[id]?.title ?? id)
            }
            batch.append(PendingImport(note: note, content: CachedNoteContent(html: html, images: [:])))
        }
        guard !batch.isEmpty else {
            throw NotesImportError.invalidData("没有选中可保存的笔记。")
        }
        let notes = try await buildEnexNotes(batch, recordingProgress: false, requireImages: true)
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            let xml = EnexWriter.render(notes: notes)
            let problems = EnexWriter.validate(xml, expectedNotes: notes.count)
            guard problems.isEmpty else { throw NotesImportError.invalidData(problems.joined(separator: "；")) }
            return Data(xml.utf8)
        }.value
    }

    func start(noteIds: [String], approvedOverwrites: Set<String>) async {
        await performImport(noteIds: noteIds, approvedOverwrites: approvedOverwrites, asCopies: false)
    }

    func startCopies(noteIds: [String]) async {
        await performImport(noteIds: noteIds, approvedOverwrites: [], asCopies: true)
    }

    private func performImport(noteIds: [String], approvedOverwrites: Set<String>, asCopies: Bool) async {

        guard !noteIds.isEmpty else { return }
        guard !isRunning else { return }

        isRunning = true
        cancelled = false
        logLines = []
        pairedAppleIds = [:]
        progress = ImportProgress(total: noteIds.count)
        state = services.loadState()
        pendingFileURL = state.pendingBatch.map { URL(fileURLWithPath: $0.file) }
        lastAppliedNoteIds = []
        progress.phase = .preparing
        log(asCopies ? "正在准备存入 Apple 备忘录的独立副本…" : "正在检查导入状态…")

        let task = Task {
            if asCopies { try await self.runCopyImport(noteIds: noteIds) }
            else { try await self.runImport(noteIds: noteIds, approvedOverwrites: approvedOverwrites) }
        }
        activeTask = task
        defer { activeTask = nil; isRunning = false }
        do {
            try await task.value
        } catch is CancellationError {
            log("导入已取消；已交给备忘录的批次请先核对结果。")
            progress.phase = .idle
            progress.currentTitle = nil
        } catch ImportEngineError.cancelled {
            log("导入已取消。")
            progress.phase = .idle
            progress.currentTitle = nil
        } catch {
            log("导入失败：\(error.localizedDescription)")
            progress.phase = .failed(error.localizedDescription)
            progress.currentTitle = nil
        }
    }

    func cancel() {
        cancelled = true
        activeTask?.cancel()
        log("收到取消请求，将在安全点停止…")
    }

    /// 只能由界面明确确认后调用；已配对的笔记记录不受影响。
    func discardPendingBatch() {
        guard !isRunning else { return }
        state = services.loadState()
        state.pendingBatch = nil
        saveState()
        progress.phase = .idle
        log("已解除上次批次的等待状态；原 ENEX 文件保留，已导入的笔记不删除。")
    }

    /// A copy is a new Notes item. Never evaluate overwrites or write back pairings.
    private func runCopyImport(noteIds: [String]) async throws {
        try await recoverPendingBatchIfNeeded()
        try guardCancelled()
        var seen = lastAppliedNoteIds
        let ids = noteIds.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else {
            finishCopyImport()
            return
        }
        let byID = Dictionary(cache.loadIndex().notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let batch = try ids.map { id -> PendingImport in
            guard let note = byID[id], note.hasBody, let html = cache.html(for: id) else {
                throw ImportEngineError.missingContent(byID[id]?.title ?? id)
            }
            return PendingImport(note: note, content: CachedNoteContent(html: html, images: [:]))
        }
        progress.total = lastAppliedNoteIds.count + batch.count
        log("正在连接「备忘录」并检查自动化权限…")
        let existingNotes = try await services.listAllNotes()
        let existingIDs = Set(existingNotes.map(\.id))
        try guardCancelled()
        var notes = try await buildEnexNotes(batch, requireImages: true)
        var reservedTitles = Set(existingNotes.map(\.name)).union(notes.map(\.title))
        for i in notes.indices {
            let title = notes[i].title
            var number = 1
            while reservedTitles.contains("\(title)（\(number)）") { number += 1 }
            notes[i].title = "\(title)（\(number)）"
            reservedTitles.insert(notes[i].title)
        }
        let preparedNotes = notes
        let data = try await Task.detached(priority: .userInitiated) {
            let xml = EnexWriter.render(notes: preparedNotes)
            let problems = EnexWriter.validate(xml, expectedNotes: preparedNotes.count)
            guard problems.isEmpty else { throw NotesImportError.invalidData(problems.joined(separator: "；")) }
            return Data(xml.utf8)
        }.value
        try guardCancelled()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MiNoteBridge-Copy-\(UUID().uuidString).enex")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        state.pendingBatch = PendingBatch(file: url.path, noteIds: ids, expectedCount: notes.count, createdAt: Date(),
                                         copyItems: zip(ids, notes).map { PendingCopyItem(noteId: $0.0, title: $0.1.title) },
                                         existingAppleIds: Array(existingIDs))
        // Persist before dispatch. A failed state write must not risk duplicate imports.
        try services.saveState(state)
        pendingFileURL = url
        progress.phase = .awaitingImport
        progress.currentTitle = nil
        log("副本文件已生成；正在用 Apple 备忘录打开。请在备忘录弹窗点击「导入」，原笔记不会被覆盖。")
        do { try await services.openENEX(url) }
        catch let error as ImportEngineError {
            if case .openFailed = error {
                state.pendingBatch = nil
                try services.saveState(state)
                pendingFileURL = nil
            }
            throw error
        }
        let deadline = Date().addingTimeInterval(services.importTimeout)
        while Date() < deadline {
            try guardCancelled()
            try await Task.sleep(nanoseconds: services.pollInterval)
            guard let pending = state.pendingBatch else { break }
            do {
                if try await confirmCopyImport(pending) {
                    finishCopyImport()
                    return
                }
            } catch is CancellationError { throw CancellationError() }
            catch { throw ImportEngineError.unconfirmed(url.path, error.localizedDescription) }
            let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            progress.detail = "请在 Apple 备忘录确认导入副本；等待结果中，剩余 \(remaining) 秒。"
        }
        throw ImportEngineError.unconfirmed(url.path, "尚未回读到全部副本。请先在 Apple 备忘录确认导入，再重试核对；不会重复发送文件。")
    }

    private func confirmCopyImport(_ batch: PendingBatch) async throws -> Bool {
        guard let items = batch.copyItems, !items.isEmpty, items.count == batch.expectedCount,
              let existing = batch.existingAppleIds else { return false }
        let existingIDs = Set(existing)
        let fresh = try await services.listAllNotes().filter { !existingIDs.contains($0.id) }
        try guardCancelled()
        var matchedIDs: Set<String> = []
        for item in items {
            let matches = fresh.filter { $0.name == item.title && !matchedIDs.contains($0.id) }
            guard matches.count == 1, let match = matches.first else { return false }
            matchedIDs.insert(match.id)
        }
        state.pendingBatch = nil
        try services.saveState(state)
        pendingFileURL = nil
        lastAppliedNoteIds.formUnion(items.map(\.noteId))
        progress.completed = lastAppliedNoteIds.count
        log("已在 Apple 备忘录确认 \(items.count) 条新副本；原笔记及原关联保持不变。")
        return true
    }

    private func finishCopyImport() {
        progress.completed = progress.total
        progress.phase = .finished
        progress.currentTitle = nil
        log("副本导入完成：已确认 \(lastAppliedNoteIds.count) 条，未覆盖原笔记。")
    }

    private func runImport(noteIds: [String], approvedOverwrites: Set<String>) async throws {
        try await recoverPendingBatchIfNeeded()
        try guardCancelled()
        await Task.yield()

        let index = cache.loadIndex()
        cachedNotes = index.notes
        pairedAppleIds = [:]
        let evaluations = evaluate(noteIds: noteIds.filter { !lastAppliedNoteIds.contains($0) }, notes: index.notes, state: state)

        var batch: [PendingImport] = []
        var overwrites: [OverwriteTask] = []
        var unauthorized = 0
        var blockedCount = 0
        var unknownCount = 0

        for item in evaluations {
            switch item {
            case .create(let note, let content):
                batch.append(PendingImport(note: note, content: content))

            case .overwrite(let note, let content, let appleId):

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

        progress.total = batch.count + overwrites.count
        log("选中 \(noteIds.count) 条：新建 \(batch.count)，已授权覆盖 \(overwrites.count)，"
            + "未授权覆盖 \(unauthorized)，无法执行 \(blockedCount)，缓存中不存在 \(unknownCount)。")

        guard !batch.isEmpty || !overwrites.isEmpty else {
            log("没有可执行的变更，本次不写任何内容。")
            finish(created: 0, unpaired: 0, overwritten: 0, overwriteFailed: 0,
                   unauthorized: unauthorized, blocked: blockedCount, unknown: unknownCount)
            return
        }

        log("正在连接「备忘录」并检查自动化权限，请留意系统授权提示…")
        let beforeCount = try await services.countNotes()
        try guardCancelled()
        log("已连接「备忘录」，当前共有 \(beforeCount) 条笔记。")

        var enexNotes: [EnexNote] = []
        if !batch.isEmpty {
            progress.phase = .preparing
            enexNotes = try await buildEnexNotes(batch)
        }

        progress.phase = .writing
        progress.currentTitle = nil
        var overwritten = 0
        var overwriteFailed = 0
        if !overwrites.isEmpty {
            let result = try await runOverwrites(overwrites)
            overwritten = result.done
            overwriteFailed = result.failed
        }

        if !batch.isEmpty {
            let enexURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiNoteBridge-\(UUID().uuidString).enex")
            log("正在生成导入文件（\(enexNotes.count) 条）…")
            let preparedNotes = enexNotes
            let problems = try await Task.detached(priority: .userInitiated) {
                try EnexWriter.write(notes: preparedNotes, to: enexURL)
                return EnexWriter.validate(EnexWriter.render(notes: preparedNotes), expectedNotes: preparedNotes.count)
            }.value
            for p in problems { log("ENEX 校验警告：\(p)") }
            log("已生成 ENEX 文件（\(enexNotes.count) 条）：\(enexURL.path)")
            try guardCancelled()

            state.pendingBatch = PendingBatch(file: enexURL.path,
                                              noteIds: batch.map { $0.note.id },
                                              expectedCount: enexNotes.count,
                                              createdAt: Date())
            saveState()

            progress.phase = .awaitingImport
            log("正在用「备忘录」打开 ENEX；请在备忘录弹窗中点击「导入」，然后返回这里。")
            // ENEX 的系统默认打开应用可能是印象笔记，必须明确指定 Apple Notes。
            do { try await services.openENEX(enexURL) }
            catch let error as ImportEngineError {
                // open 明确拒绝时没有交付；超时或取消的交付状态不明，保留 pending。
                state.pendingBatch = nil; saveState()
                throw error
            }

            let expected = beforeCount + enexNotes.count
            let deadline = Date().addingTimeInterval(services.importTimeout)
            var current = beforeCount
            while Date() < deadline {
                try guardCancelled()
                try await Task.sleep(nanoseconds: services.pollInterval)
                let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                progress.detail = "请在「备忘录」确认导入；等待结果中，剩余 \(remaining) 秒。"
                do {
                    current = try await services.countNotes()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ImportEngineError.unconfirmed(enexURL.path, error.localizedDescription)
                }
                if current >= expected { break }
            }
            if current >= expected {
                log("导入确认：笔记数 \(beforeCount) → \(current)。")
            } else {
                throw ImportEngineError.unconfirmed(enexURL.path, "等待 \(Int(services.importTimeout)) 秒后仍未确认（预期 \(expected)，当前 \(current)）。请检查备忘录中的导入确认窗口。")
            }

            progress.phase = .organizingFolders
            try await pairImportedNotes(batch.map { $0.note })
            try await organizeImportedNotes(batch.map { $0.note })
            guard pairedAppleIds.count == batch.count else {
                throw ImportEngineError.unconfirmed(enexURL.path, "部分笔记已接收，但尚未全部配对；请先核对备忘录，避免重复导入。")
            }
        }

        finish(created: pairedAppleIds.count,
               unpaired: batch.count - pairedAppleIds.count,
               overwritten: overwritten,
               overwriteFailed: overwriteFailed,
               unauthorized: unauthorized,
               blocked: blockedCount,
               unknown: unknownCount)
    }

    private enum NoteEvaluation {

        case create(note: CachedNote, content: CachedNoteContent)

        case overwrite(note: CachedNote, content: CachedNoteContent, appleId: String)

        case blocked(PlannedChange)

        case unknown(id: String)
    }

    private func evaluate(noteIds: [String], notes: [CachedNote], state: SyncState) -> [NoteEvaluation] {
        let byId = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return noteIds.map { id in
            guard let note = byId[id] else { return .unknown(id: id) }
            let appleId = Self.importedAppleId(for: note, in: state)
            // 审批只需正文预览；不要为每个候选项加载并复制所有图片。
            let content = cache.html(for: id).map { CachedNoteContent(html: $0, images: [:]) }
            let kind: ChangeKind = appleId == nil ? .create : .overwrite

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
                                                reason: "当前覆盖通道暂不支持图片、公式或图表，无法完整更新；原笔记保持不变"))
            }
            if let appleId {
                return .overwrite(note: note, content: content, appleId: appleId)
            }
            return .create(note: note, content: content)
        }
    }

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

    private static func previewText(from html: String, limit: Int = 120) -> String {
        guard !html.isEmpty else { return "" }
        var text = XiaomiConvert.replaceRegex("<[^>]+>", in: html) { _ in " " }
        text = XiaomiConvert.decodeEntities(text)
        text = XiaomiConvert.replaceRegex("\\s+", in: text) { _ in " " }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func containsImages(note: CachedNote, content: CachedNoteContent) -> Bool {
        if !note.imageFileIds.isEmpty { return true }
        if !content.images.isEmpty { return true }
        let html = content.html.lowercased()
        return html.contains("<img") || html.contains("<svg") || html.contains("fileid=") || html.contains("data-latex")
            || html.contains("katex") || html.contains("$$") || html.contains("\\[") || html.contains("\\(")
    }

    private struct OverwriteTask {
        var note: CachedNote
        var content: CachedNoteContent

        var appleId: String
    }

    private func runOverwrites(_ tasks: [OverwriteTask]) async throws -> (done: Int, failed: Int) {
        var done = 0
        var failed = 0

        for task in tasks {
            try guardCancelled()
            progress.currentTitle = task.note.title
            do {
                try await services.setBody(task.appleId, Self.overwriteBody(title: task.note.title,
                                                                         contentHTML: task.content.html))
                done += 1
                recordOverwrite(task)

                lastAppliedNoteIds.insert(task.note.id)
                log("已覆盖「\(task.note.title)」的正文。")
            } catch is CancellationError {
                throw CancellationError()
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

    private static func overwriteBody(title: String, contentHTML: String) -> String {
        let body = XiaomiConvert.sanitizeToENML(contentHTML, imageMeta: [:])
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        if firstLine(of: body) == trimmed { return body }
        return "<h1>\(XiaomiConvert.escapeXML(trimmed))</h1>" + body
    }

    private static func firstLine(of html: String) -> String {
        let withBreaks = XiaomiConvert.replaceRegex("</(div|p|h1|h2|h3|li|blockquote|pre|tr|table)>",
                                                    in: html) { _ in "\n" }
        let text = XiaomiConvert.replaceRegex("<[^>]+>", in: withBreaks) { _ in "" }
        return XiaomiConvert.decodeEntities(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    private struct PendingImport {
        var note: CachedNote
        var content: CachedNoteContent
    }

    private func buildEnexNotes(_ batch: [PendingImport], recordingProgress: Bool = true,
                                requireImages: Bool = false) async throws -> [EnexNote] {
        var notes: [EnexNote] = []
        for item in batch {
            try Task.checkCancellation()
            if recordingProgress {
                try guardCancelled()
                progress.currentTitle = item.note.title
                log("正在准备「\(item.note.title)」的正文、公式和图表（\(notes.count + 1)/\(batch.count)）…")
            }
            await Task.yield()
            guard let content = cache.content(for: item.note.id) else {
                throw ImportEngineError.missingContent(item.note.title)
            }

            var imageMeta: [String: (mime: String, hash: String)] = [:]
            var resources: [EnexResource] = []
            for fileId in Set(item.note.imageFileIds).union(content.images.keys).sorted() {
                guard let data = content.images[fileId], !data.isEmpty else {
                    if requireImages {
                        throw NotesImportError.invalidData("「\(item.note.title)」的图片 \(fileId) 不在本地，未保存不完整的副本。请先重新拉取图片。")
                    }
                    log("图片 \(fileId) 在缓存里缺失，正文中将显示占位。")
                    continue
                }
                let mime = Self.imageMIME(data)
                let res = EnexResource(data: data, mime: mime, filename: "\(fileId).\(Self.imageExt(mime))")
                resources.append(res)
                imageMeta[fileId] = (mime: mime, hash: res.md5)
            }

            let rendered = try await services.renderHTML(content.html)
            try Task.checkCancellation()
            if recordingProgress { try guardCancelled() }
            let attached = try NoteExportHTML.attachInlineImages(rendered)
            resources.append(contentsOf: attached.resources)
            imageMeta.merge(attached.imageMeta) { existing, _ in existing }
            if requireImages { try NoteExportHTML.validateCopyImages(attached.html, imageMeta: imageMeta) }
            let body = XiaomiConvert.sanitizeToENML(attached.html, imageMeta: imageMeta)
            notes.append(EnexNote(
                title: item.note.title,
                body: body,
                created: Date(timeIntervalSince1970: item.note.createDate / 1000),
                updated: Date(timeIntervalSince1970: item.note.modifyDate / 1000),
                tags: item.note.folderName.isEmpty ? [] : [item.note.folderName],
                resources: resources
            ))
            if recordingProgress { log("已准备「\(item.note.title)」，包含 \(resources.count) 个附件。") }
        }
        return notes
    }

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

    private func pairImportedNotes(_ imported: [CachedNote], strict: Bool = false) async throws {
        let appleNotes = try await services.listNotes(Self.inboxFolderName)
        var knownIds = Set(cachedNotes.compactMap { $0.appleId }.filter { !$0.isEmpty })
        knownIds.formUnion(state.notes.values.compactMap { $0.appleId })
        var fresh = appleNotes.filter { !knownIds.contains($0.id) }
        log("回读到「导入的备忘录」共 \(appleNotes.count) 条，其中新出现 \(fresh.count) 条待配对。")

        var paired = 0
        for note in imported {
            try guardCancelled()
            let miCreated = Date(timeIntervalSince1970: note.createDate / 1000)
            let candidates = strict ? fresh.filter { $0.name == note.title && createdDistance($0.created, to: miCreated) < 2 } : fresh
            guard let matched = bestMatch(for: note, miCreated: miCreated, in: candidates), !strict || candidates.count == 1 else {
                log("未能配对笔记「\(note.title)」（标题+创建时间都不匹配），保留为待确认。")
                continue
            }
            fresh.removeAll { $0.id == matched.id }
            pairedAppleIds[note.id] = matched.id
            lastAppliedNoteIds.insert(note.id)
            progress.completed += 1

            state.notes[note.id] = NoteRecord(noteId: note.id, modifyDate: note.modifyDate,
                                              appleId: matched.id, bodyHash: nil,
                                              title: note.title, snippet: note.snippet,
                                              aiModified: note.aiModified, status: .synced)
            paired += 1
        }
        log("配对完成：成功 \(paired)/\(imported.count)。")

        writeBackPairings()
        saveState()
    }

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

    private func organizeImportedNotes(_ imported: [CachedNote]) async throws {
        var targets: [String: String] = [:]
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
                try await services.moveNote(appleId, folderName)
                moved += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("移动笔记「\(note.title)」到「\(folderName)」失败：\(error.localizedDescription)")
            }
        }
        progress.currentTitle = nil
        progress.detail = nil
        log("文件夹归位完成：\(moved)/\(targets.count) 条已移动。")
    }

    private func ensureFolders(named names: Set<String>) async throws -> Set<String> {
        var existing = Set<String>()
        for folder in try await services.folders() {
            existing.insert(folder.name)
        }
        var ready = Set<String>()
        for name in names {
            try guardCancelled()
            if existing.contains(name) {
                ready.insert(name)
                continue
            }
            do {
                _ = try await services.createFolder(name)
                ready.insert(name)
                log("已在「备忘录」中创建文件夹「\(name)」。")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("创建文件夹「\(name)」失败：\(error.localizedDescription)")
            }
        }
        return ready
    }

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

    private func recoverPendingBatchIfNeeded() async throws {
        guard let batch = state.pendingBatch else { return }
        log("正在回读上次导入结果，不重复发送文件…")
        if batch.copyItems != nil {
            if try await confirmCopyImport(batch) { return }
            throw ImportEngineError.unconfirmed(batch.file, "上次副本导入尚未全部确认。请先核对 Apple 备忘录中的导入弹窗和结果，避免重复导入。")
        }
        cachedNotes = cache.loadIndex().notes
        let byID = Dictionary(cachedNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unresolved = batch.noteIds.filter { state.notes[$0]?.appleId == nil }
        let recoverable = unresolved.compactMap { byID[$0] }
        if !recoverable.isEmpty {
            try await pairImportedNotes(recoverable, strict: true)
            try await organizeImportedNotes(recoverable)
        }
        if batch.noteIds.allSatisfy({ state.notes[$0]?.appleId != nil }) {
            state.pendingBatch = nil; saveState()
            log("上次批次已确认，继续本次操作。")
            return
        }
        // 已发送给备忘录的操作无法回滚，不能在未核对时自动再次导入。
        throw ImportEngineError.unconfirmed(batch.file, "检测到上次未确认的批次（\(batch.noteIds.count) 条）。请先核对备忘录的接收结果，避免重复导入。")
    }

    private static func importedAppleId(for note: CachedNote, in state: SyncState) -> String? {
        if note.imported, let appleId = note.appleId, !appleId.isEmpty { return appleId }
        if let appleId = state.notes[note.id]?.appleId, !appleId.isEmpty { return appleId }
        return nil
    }

    private static func isAIModified(_ note: CachedNote, in state: SyncState) -> Bool {
        note.aiModified || (state.notes[note.id]?.aiModified ?? false)
    }

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
        pendingFileURL = state.pendingBatch.map { URL(fileURLWithPath: $0.file) }
        do {
            try services.saveState(state)
        } catch {
            log("保存同步状态失败：\(error.localizedDescription)")
        }
    }

    private func guardCancelled() throws {
        try Task.checkCancellation()
        if cancelled { throw ImportEngineError.cancelled }
    }

    private func log(_ message: String) {
        let line = "[\(Self.logTimeFormatter.string(from: Date()))] \(message)"
        logLines.append(line)
        progress.detail = message
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }
}

enum ImportEngineError: LocalizedError {
    case cancelled
    case openFailed(String, String)
    case unconfirmed(String, String)
    case missingContent(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "导入已取消。"
        case .openFailed(let path, let detail): return "无法用「备忘录」打开导入文件：\(detail)。ENEX 保留在：\(path)"
        case .unconfirmed(let path, let detail): return "\(detail)\n导入文件保留在：\(path)"
        case .missingContent(let title): return "「\(title)」的本地正文已不可用，请重新拉取后再导入。"
        }
    }
}
