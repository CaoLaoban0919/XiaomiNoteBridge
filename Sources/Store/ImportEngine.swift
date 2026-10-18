import Foundation
import Combine
import AppKit

@MainActor
final class ImportEngine: ObservableObject, ImportEngineProtocol {

    @Published private(set) var progress = ImportProgress()
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isRunning = false

    @Published private(set) var lastAppliedNoteIds: Set<String> = []

    private let cache: NoteCacheProtocol

    private var cachedNotes: [CachedNote] = []

    private var state: SyncState = SyncState()

    private var pairedAppleIds: [String: String] = [:]

    private var cancelled = false

    private let importTimeout: TimeInterval = 90

    private let pollInterval: UInt64 = 1_000_000_000

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

    func plan(noteIds: [String]) -> ChangePlan {
        var plan = ChangePlan()
        guard !noteIds.isEmpty else { return plan }

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

                break
            }
        }
        return plan
    }

    func start(noteIds: [String], approvedOverwrites: Set<String>) async {

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

    private func runImport(noteIds: [String], approvedOverwrites: Set<String>) async throws {
        recoverPendingBatchIfNeeded()

        lastAppliedNoteIds = []

        let index = cache.loadIndex()
        cachedNotes = index.notes
        let evaluations = evaluate(noteIds: noteIds, notes: index.notes, state: state)

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

        var enexNotes: [EnexNote] = []
        if !batch.isEmpty {
            progress.phase = .preparing
            enexNotes = try buildEnexNotes(batch)
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
            try EnexWriter.write(notes: enexNotes, to: enexURL)
            let problems = EnexWriter.validate(EnexWriter.render(notes: enexNotes), expectedNotes: enexNotes.count)
            for p in problems { log("ENEX 校验警告：\(p)") }
            log("已生成 ENEX 文件（\(enexNotes.count) 条）：\(enexURL.path)")
            try guardCancelled()

            let beforeCount = try await NotesImporter.countNotes(inFolder: nil)
            log("导入前备忘录共有 \(beforeCount) 条笔记。")

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
            let content = cache.content(for: id)
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
                                                reason: "含图片，覆盖会丢图，已跳过"))
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
        return content.html.contains("fileid=")
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
                try await NotesImporter.setBody(id: task.appleId,
                                                html: Self.overwriteBody(title: task.note.title,
                                                                         contentHTML: task.content.html))
                done += 1
                recordOverwrite(task)

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
                try await NotesImporter.moveNote(id: appleId, toFolder: folderName)
                moved += 1
            } catch {
                log("移动笔记「\(note.title)」到「\(folderName)」失败：\(error.localizedDescription)")
            }
        }
        progress.currentTitle = nil
        log("文件夹归位完成：\(moved)/\(targets.count) 条已移动。")
    }

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

    private func recoverPendingBatchIfNeeded() {
        guard let batch = state.pendingBatch else { return }
        log("检测到上次未完成的导入批次（\(batch.noteIds.count) 条），未确认的笔记将重新导入。")
        for id in batch.noteIds where state.notes[id]?.appleId == nil {
            state.notes.removeValue(forKey: id)
        }
        state.pendingBatch = nil
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

enum ImportEngineError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled: return "导入已取消。"
        }
    }
}
