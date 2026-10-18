import Foundation

@MainActor
enum ImportPipelineTests {
    final class MemoryCache: NoteCacheProtocol {
        var notes: [CachedNote] = []
        var contents: [String: CachedNoteContent] = [:]
        var contentReads = 0
        func loadIndex() -> (notes: [CachedNote], folders: [CachedFolder]) { (notes, []) }
        func saveIndex(notes: [CachedNote], folders: [CachedFolder]) throws { self.notes = notes }
        func content(for id: String) -> CachedNoteContent? { contentReads += 1; return contents[id] }
        func html(for id: String) -> String? { contents[id]?.html }
        func saveContent(_ content: CachedNoteContent, for id: String) throws { contents[id] = content }
        func saveHTML(_ html: String, for id: String) throws { contents[id]?.html = html }
        func saveOriginalIfAbsent(_ content: CachedNoteContent, for id: String) throws {}
        func originalContent(for id: String) -> String? { nil }
        func removeNote(id: String) throws { notes.removeAll { $0.id == id } }
        func imageData(fileId: String) -> Data? { nil }
        func clearAll() throws { notes = []; contents = [:] }
    }
    final class Harness {
        let cache = MemoryCache()
        var state = SyncState()
        var opened: [URL] = []
        var candidates: [AppleNote] = []
        var count = 10
        var writes = 0
        var moved: [String] = []
        init() {
            let note = CachedNote(id: "synthetic-import", title: "合成导入验收", snippet: "", folderId: "", folderName: "验收文件夹",
                                  createDate: 1_700_000_000_000, modifyDate: 1_700_000_000_000,
                                  fileIds: [], imageFileIds: [], hasBody: true, imported: false, appleId: nil, aiModified: false)
            cache.notes = [note]
            cache.contents[note.id] = CachedNoteContent(html: "<p>合成正文</p>", images: [:])
            candidates = [AppleNote(id: "synthetic-apple", name: note.title, folder: "导入的备忘录",
                                    created: Date(timeIntervalSince1970: note.createDate / 1000), modified: nil, bodyLength: 0)]
        }
        func services() -> ImportEngine.Services {
            var services = ImportEngine.Services()
            services.loadState = { self.state }
            services.saveState = { self.state = $0 }
            services.countNotes = { self.count }
            services.listNotes = { _ in self.candidates }
            services.openENEX = { self.opened.append($0); self.count += 1 }
            services.renderHTML = { $0 }
            services.setBody = { _, _ in self.writes += 1 }
            services.folders = { [AppleFolder(id: "synthetic-folder", name: "验收文件夹")] }
            services.createFolder = { _ in throw NotesImportError.invalidData("unexpected folder creation") }
            services.moveNote = { id, _ in self.moved.append(id) }
            services.importTimeout = 0.08
            services.pollInterval = 1_000_000
            return services
        }
        func cleanup() { for url in opened { try? FileManager.default.removeItem(at: url) } }
    }

    static func run() async throws {
        let check = MathWebRuntimeTests.check
        check(try await NotesBridge.run("return \"synthetic-ok\"", timeout: 2) == "synthetic-ok", "real osascript bridge returns without accessing Apple Notes")
        do {
            let _: Int = try await MathImageRenderer.bounded(timeout: 0.03) { _ in }
            check(false, "missing WebKit callback is bounded")
        } catch MathImageRenderer.RenderError.timeout { check(true, "missing WebKit callback times out instead of hanging import") }
        let webTask = Task { let _: Int = try await MathImageRenderer.bounded { _ in } }
        try await Task.sleep(nanoseconds: 10_000_000); webTask.cancel()
        do { try await webTask.value; check(false, "WebKit callback wait cancellation") }
        catch is CancellationError { check(true, "stop import interrupts a pending WebKit callback") }
        // No Apple Events: subprocess tests exercise exactly the runner used by osascript.
        let echo = try await ScriptProcess.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["合成结果"], timeout: 2)
        check(echo.status == 0 && echo.stdout.contains("合成结果"), "automation runner returns output asynchronously")
        let many = try await ScriptProcess.run(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                                               arguments: ["-e", "print STDERR 'e' x 200000; print STDOUT 'o' x 200000;"], timeout: 3)
        check(many.stderr.count == 200000 && many.stdout.count == 200000, "large stderr before stdout cannot deadlock automation")
        let start = Date()
        do {
            _ = try await ScriptProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.08)
            check(false, "unresponsive process times out")
        } catch ScriptProcess.Failure.timedOut { check(Date().timeIntervalSince(start) < 2, "unresponsive process times out promptly") }
        let stubborn = Date()
        do {
            _ = try await ScriptProcess.run(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                                            arguments: ["-e", "$SIG{TERM}='IGNORE'; sleep 10;"], timeout: 0.15)
            check(false, "SIGTERM ignoring process is bounded")
        } catch ScriptProcess.Failure.timedOut { check(Date().timeIntervalSince(stubborn) < 2, "SIGTERM ignoring process is forcibly stopped") }
        let task = Task { try await ScriptProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 20) }
        try await Task.sleep(nanoseconds: 30_000_000); task.cancel()
        do { _ = try await task.value; check(false, "automation process cancellation") }
        catch ScriptProcess.Failure.cancelled { check(true, "automation process responds to cancellation") }
        catch is CancellationError { check(true, "automation process responds to cancellation") }

        for html in ["<p>图片</p><img fileid=\"synthetic-image\"/>",
                     "<svg><path d=\"M0 0L1 1\"/></svg>",
                     "<span data-latex=\"x^2\"></span>"] {
            let rich = Harness()
            rich.cache.notes[0].imported = true
            rich.cache.notes[0].appleId = "synthetic-existing"
            let richIDs = rich.cache.notes.map(\.id)
            rich.cache.contents[richIDs[0]]?.html = html
            let engine = ImportEngine(cache: rich.cache, services: rich.services())
            let plan = engine.plan(noteIds: richIDs)
            check(plan.overwrites.count == 1 && plan.needsApproval.isEmpty && plan.blocked.count == 1,
                  "rich existing note is linked but ineligible for the text-only overwrite path")
            check(plan.blocked.first?.blockedReason?.contains("暂不支持图片、公式或图表") == true,
                  "rich overwrite reports the current channel limitation explicitly")
            await engine.start(noteIds: richIDs, approvedOverwrites: Set(richIDs))
            check(rich.writes == 0 && rich.opened.isEmpty && engine.lastAppliedNoteIds.isEmpty,
                  "even explicit approval cannot silently strip rich content or create duplicates")
        }

        let copy = Harness()
        copy.cache.notes[0].imported = true
        copy.cache.notes[0].appleId = "existing-copy-source"
        copy.cache.notes[0].aiModified = true
        let copyIDs = copy.cache.notes.map(\.id)
        let copyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")!
        copy.cache.notes[0].imageFileIds = ["copy-photo"]
        copy.cache.contents[copyIDs[0]] = CachedNoteContent(
            html: AITextToHTML.render("公式 $x^2$\n\n```chart\n{\"type\":\"function\",\"expression\":\"sin(x)\"}\n```") + "<img fileid=\"copy-photo\"/>",
            images: ["copy-photo": copyPNG])
        copy.state.pendingBatch = PendingBatch(file: "/synthetic-pending.enex", noteIds: ["unrelated"], expectedCount: 1, createdAt: Date())
        let stateEncoder = JSONEncoder()
        stateEncoder.outputFormatting = [.sortedKeys]
        let beforeState = try stateEncoder.encode(copy.state)
        let beforeCache = copy.cache.notes
        var copyServices = copy.services()
        copyServices.renderHTML = { try await MathImageRenderer.exportHTML($0) }
        copyServices.loadState = { preconditionFailure("copy export must not read or reconcile sync state") }
        copyServices.saveState = { _ in preconditionFailure("copy export must not change pairings") }
        copyServices.countNotes = { preconditionFailure("copy export must not contact Notes") }
        let copyEngine = ImportEngine(cache: copy.cache, services: copyServices)
        let copyData = try await copyEngine.copyFileData(noteIds: copyIDs + copyIDs)
        let copyXML = String(decoding: copyData, as: UTF8.self)
        check(EnexWriter.validate(copyXML, expectedNotes: 1).isEmpty, "copy exports linked and AI-edited notes once without applying overwrite restrictions")
        check(copyXML.components(separatedBy: "<resource>").count - 1 == 3 && copyXML.components(separatedBy: "<en-media").count - 1 == 3,
              "copy ENEX retains photo plus rendered formula and chart attachments")
        let afterState = try stateEncoder.encode(copy.state)
        check(copy.cache.notes == beforeCache && afterState == beforeState && copy.opened.isEmpty && copy.writes == 0,
              "copy export leaves note pairing, pending batches, and Apple Notes unchanged")
        check(copyEngine.progress.phase == .idle && !copyEngine.isRunning && copyEngine.logLines.isEmpty,
              "copy export does not masquerade as a completed import")
        try copyData.write(to: MathWebRuntimeTests.root.appendingPathComponent("copy-validation.enex"), options: .atomic)

        copy.cache.contents[copyIDs[0]]?.images = [:]
        do {
            _ = try await copyEngine.copyFileData(noteIds: copyIDs)
            check(false, "copy export refuses missing photo bytes")
        } catch {
            check(error.localizedDescription.contains("图片") && error.localizedDescription.contains("未保存"),
                  "missing copy attachment reports failure without saving a lossy file")
        }
        copy.cache.notes[0].imageFileIds = []
        copy.cache.contents[copyIDs[0]]?.html = "<img fileid=\"missing-in-html\"/>"
        do {
            _ = try await copyEngine.copyFileData(noteIds: copyIDs)
            check(false, "copy export checks image references absent from metadata")
        } catch { check(true, "unresolved HTML image cannot silently disappear from copy") }
        for emptyIDs in [[], ["unknown-copy-id"]] as [[String]] {
            do { _ = try await copyEngine.copyFileData(noteIds: emptyIDs); check(false, "invalid copy selection fails") }
            catch { check(true, "invalid copy selection reports an error rather than creating an empty file") }
        }

        try await runCopyImportTests()

        let good = Harness(); defer { good.cleanup() }
        let source = AITextToHTML.render("公式 $x^2$\n\n```chart\n{\"type\":\"function\",\"expression\":\"sin(x)\"}\n```")
        good.cache.contents[good.cache.notes[0].id]?.html = source
        var liveRender = good.services()
        liveRender.renderHTML = { try await MathImageRenderer.exportHTML($0) }
        let engine = ImportEngine(cache: good.cache, services: liveRender)
        let ids = good.cache.notes.map(\.id)
        check(engine.plan(noteIds: ids).creates.count == 1 && good.cache.contentReads == 0, "approval preview never loads image attachments")
        await engine.start(noteIds: ids, approvedOverwrites: [])
        check(engine.progress.phase == .finished && !engine.isRunning && good.opened.count == 1, "import pipeline completes and clears running state")
        let enex = try String(contentsOf: good.opened[0], encoding: .utf8)
        check(enex.components(separatedBy: "<resource>").count - 1 == 2 && enex.components(separatedBy: "<en-media").count - 1 == 2, "actual import ENEX retains both formula and chart PNG attachments")
        check(good.cache.notes[0].imported && good.state.notes[ids[0]]?.appleId == "synthetic-apple" && engine.lastAppliedNoteIds == Set(ids), "successful readback persists pairing and clears applied selection")
        check(good.moved == ["synthetic-apple"] && good.state.pendingBatch == nil, "import organizes confirmed note and clears pending batch")

        let denied = Harness(); var noAccess = denied.services()
        noAccess.countNotes = { throw NotesImportError.notAuthorized }
        let deniedEngine = ImportEngine(cache: denied.cache, services: noAccess)
        await deniedEngine.start(noteIds: ids, approvedOverwrites: [])
        check(!deniedEngine.isRunning && denied.opened.isEmpty && denied.cache.contentReads == 0, "permission error stops before rendering or importing")
        check(deniedEngine.logLines.last?.contains("自动化权限") == true, "permission failure is visible in import status")

        let rejected = Harness(); defer { rejected.cleanup() }
        var refusesOpen = rejected.services()
        refusesOpen.openENEX = { url in
            rejected.opened.append(url)
            throw ImportEngineError.openFailed(url.path, "synthetic open failure")
        }
        let rejectedEngine = ImportEngine(cache: rejected.cache, services: refusesOpen)
        await rejectedEngine.start(noteIds: ids, approvedOverwrites: [])
        check(!rejectedEngine.isRunning && rejected.state.pendingBatch == nil && rejectedEngine.pendingFileURL == nil, "rejected ENEX handoff clears pending state so a safe retry is possible")
        check(rejectedEngine.logLines.last?.contains("synthetic open failure") == true, "ENEX handoff failure reports the actual launch error")

        let waiting = Harness(); defer { waiting.cleanup() }
        var neverArrives = waiting.services()
        neverArrives.openENEX = { waiting.opened.append($0) }
        let waitingEngine = ImportEngine(cache: waiting.cache, services: neverArrives)
        await waitingEngine.start(noteIds: ids, approvedOverwrites: [])
        if case .failed = waitingEngine.progress.phase { check(true, "unconfirmed import reports failure instead of false success") }
        else { check(false, "unconfirmed import reports failure instead of false success") }
        check(waiting.state.pendingBatch != nil && waitingEngine.pendingFileURL != nil && !waitingEngine.isRunning, "unconfirmed batch retains recoverable file and returns control")
        // Simulate user confirming the already-open Notes import after timeout.
        await waitingEngine.start(noteIds: ids, approvedOverwrites: [])
        check(waiting.opened.count == 1 && waiting.writes == 0 && waiting.state.pendingBatch == nil && waiting.cache.notes[0].imported, "retry reconciles completed batch without duplicate import or overwrite")

        let cancelled = Harness(); var slow = cancelled.services()
        slow.countNotes = {
            _ = try await ScriptProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 20)
            return 10
        }
        let cancelledEngine = ImportEngine(cache: cancelled.cache, services: slow)
        let importing = Task { await cancelledEngine.start(noteIds: ids, approvedOverwrites: []) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let cancelAt = Date(); cancelledEngine.cancel(); await importing.value
        check(!cancelledEngine.isRunning && cancelledEngine.progress.phase == .idle && Date().timeIntervalSince(cancelAt) < 2, "stop import cancels outstanding automation and restores responsive UI")
        check(cancelled.opened.isEmpty && cancelled.state.pendingBatch == nil, "cancel before dispatch leaves no pending or partial import")

        let incomplete = Harness(); defer { incomplete.cleanup() }
        incomplete.candidates = []
        var missing = incomplete.services()
        missing.openENEX = { incomplete.opened.append($0) }
        let incompleteEngine = ImportEngine(cache: incomplete.cache, services: missing)
        await incompleteEngine.start(noteIds: ids, approvedOverwrites: [])
        await incompleteEngine.start(noteIds: ids, approvedOverwrites: [])
        check(incomplete.opened.count == 1 && incomplete.state.pendingBatch != nil && !incomplete.cache.notes[0].imported, "unresolved batch cannot be blindly resent on retry")
        incompleteEngine.discardPendingBatch()
        check(incomplete.state.pendingBatch == nil && incompleteEngine.pendingFileURL == nil && incompleteEngine.progress.phase == .idle, "explicit user acknowledgement releases pending state without deleting notes or files")
    }

    static func runCopyImportTests() async throws {
        let check = MathWebRuntimeTests.check
        let fixture = Harness(); defer { fixture.cleanup() }
        let id = fixture.cache.notes[0].id
        fixture.cache.notes[0].imported = true
        fixture.cache.notes[0].appleId = "original-apple-id"
        fixture.cache.notes[0].aiModified = true
        fixture.cache.notes[0].imageFileIds = ["photo"]
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")!
        let fence = String(repeating: Character(UnicodeScalar(96)!), count: 3)
        fixture.cache.contents[id] = CachedNoteContent(
            html: AITextToHTML.render("公式 $x^2$\n\n\(fence)chart\n{\"type\":\"function\",\"expression\":\"sin(x)\"}\n\(fence)") + "<img fileid=\"photo\"/>", images: ["photo": png])
        fixture.state.notes[id] = NoteRecord(noteId: id, modifyDate: 1, appleId: "original-apple-id", bodyHash: "keep",
                                            title: "original", snippet: nil, aiModified: true, status: .synced)
        fixture.state.lastSyncAt = Date(timeIntervalSince1970: 123)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let originalState = try encoder.encode(fixture.state)
        let originalCache = fixture.cache.notes
        var services = fixture.services()
        services.renderHTML = { try await MathImageRenderer.exportHTML($0) }
        services.listAllNotes = { fixture.candidates }
        services.openENEX = { url in
            fixture.opened.append(url)
            let items = fixture.state.pendingBatch?.copyItems ?? []
            fixture.candidates += items.map { AppleNote(id: "copy-\(fixture.opened.count)-" + $0.noteId, name: $0.title, folder: "任意导入文件夹",
                                                        created: nil, modified: nil, bodyLength: 0) }
        }
        let engine = ImportEngine(cache: fixture.cache, services: services)
        await engine.startCopies(noteIds: [id, id])
        check(engine.progress.phase == .finished && fixture.opened.count == 1 && engine.lastAppliedNoteIds == [id],
              "linked AI-edited rich note imports as one new copy through the explicit Notes handoff")
        let finalState = try encoder.encode(fixture.state)
        check(fixture.cache.notes == originalCache && finalState == originalState && fixture.writes == 0 && fixture.moved.isEmpty,
              "copy import preserves original pairing, sync metadata, and original Apple Notes body")
        let xml = try String(contentsOf: fixture.opened[0], encoding: .utf8)
        check(EnexWriter.validate(xml, expectedNotes: 1).isEmpty && xml.components(separatedBy: "<resource>").count - 1 == 3,
              "copy handed to Notes embeds photo, formula and curve images")
        check(xml.contains("<title>合成导入验收（1）</title>") && engine.pendingFileURL == nil, "first copy uses a numbered title and clears pending only after readback")
        await engine.startCopies(noteIds: [id])
        let secondXML = try String(contentsOf: fixture.opened[1], encoding: .utf8)
        check(secondXML.contains("<title>合成导入验收（2）</title>") && engine.progress.phase == .finished,
              "repeated copy import increments suffix against existing Apple Notes titles")

        let waiting = Harness(); defer { waiting.cleanup() }
        var pendingServices = waiting.services()
        pendingServices.listAllNotes = { waiting.candidates }
        pendingServices.openENEX = { url in waiting.opened.append(url); waiting.count += 100 }
        let pendingEngine = ImportEngine(cache: waiting.cache, services: pendingServices)
        await pendingEngine.startCopies(noteIds: [id])
        check(waiting.state.pendingBatch?.copyItems?.count == 1 && pendingEngine.pendingFileURL != nil && pendingEngine.lastAppliedNoteIds.isEmpty,
              "unrelated note count changes cannot falsely confirm a copy")
        let encoded = try encoder.encode(waiting.state)
        waiting.state = try JSONDecoder().decode(SyncState.self, from: encoded)
        let restarted = ImportEngine(cache: waiting.cache, services: pendingServices)
        await restarted.startCopies(noteIds: [id])
        check(waiting.opened.count == 1 && waiting.state.pendingBatch != nil, "unconfirmed copy survives restart and is never blindly resent")
        let item = waiting.state.pendingBatch!.copyItems![0]
        waiting.candidates.append(AppleNote(id: "confirmed-copy", name: item.title, folder: "用户移动后的文件夹",
                                             created: nil, modified: nil, bodyLength: 0))
        await restarted.startCopies(noteIds: [id])
        check(restarted.progress.phase == .finished && waiting.opened.count == 1 && waiting.state.pendingBatch == nil && waiting.state.notes.isEmpty && !waiting.cache.notes[0].imported,
              "late confirmation recovers copy across folders without reimport or creating an original pairing")

        let multiple = Harness(); defer { multiple.cleanup() }
        var second = multiple.cache.notes[0]
        second.id = "copy-second-id"
        multiple.cache.notes.append(second)
        multiple.cache.contents[second.id] = multiple.cache.contents[id]
        var multiServices = multiple.services()
        multiServices.listAllNotes = { multiple.candidates }
        multiServices.openENEX = { url in
            multiple.opened.append(url)
            let item = multiple.state.pendingBatch!.copyItems![0]
            multiple.candidates.append(AppleNote(id: "partial-first", name: item.title, folder: "导入的备忘录", created: nil, modified: nil, bodyLength: 0))
        }
        let multiEngine = ImportEngine(cache: multiple.cache, services: multiServices)
        await multiEngine.startCopies(noteIds: [id, second.id, id])
        let multiPending = multiple.state.pendingBatch!
        check(multiPending.expectedCount == 2 && Set(multiPending.copyItems!.map(\.title)).count == 2,
              "same-title multi-selection creates distinct copies in selection order without duplicate source IDs")
        check(multiPending.copyItems!.map(\.title) == ["合成导入验收（1）", "合成导入验收（2）"],
              "same-title copies in one batch receive consecutive parenthesized numbers")
        check(multiEngine.lastAppliedNoteIds.isEmpty && multiEngine.pendingFileURL != nil,
              "partial copy readback cannot report the whole batch complete")
        await multiEngine.startCopies(noteIds: [id, second.id])
        check(multiple.opened.count == 1 && multiple.state.pendingBatch != nil, "retry of partial batch never resends already imported copies")
        let secondItem = multiPending.copyItems![1]
        multiple.candidates.append(AppleNote(id: "partial-second", name: secondItem.title, folder: "导入的备忘录", created: nil, modified: nil, bodyLength: 0))
        await multiEngine.startCopies(noteIds: [id, second.id])
        check(multiEngine.progress.phase == .finished && multiEngine.lastAppliedNoteIds == [id, second.id] && multiple.opened.count == 1,
              "partial copy batch completes after all distinct new notes are confirmed")

        let missingImage = Harness()
        missingImage.cache.notes[0].imageFileIds = ["missing-copy-image"]
        var missingImageServices = missingImage.services()
        missingImageServices.listAllNotes = { [] }
        let missingImageEngine = ImportEngine(cache: missingImage.cache, services: missingImageServices)
        await missingImageEngine.startCopies(noteIds: [id])
        check(missingImage.opened.isEmpty && missingImage.state.pendingBatch == nil && missingImageEngine.lastAppliedNoteIds.isEmpty,
              "copy with a missing local attachment fails before sending any incomplete note to Notes")

        let refused = Harness(); defer { refused.cleanup() }
        var refusedServices = refused.services()
        refusedServices.listAllNotes = { [] }
        refusedServices.openENEX = { url in refused.opened.append(url); throw ImportEngineError.openFailed(url.path, "synthetic refusal") }
        let refusedEngine = ImportEngine(cache: refused.cache, services: refusedServices)
        await refusedEngine.startCopies(noteIds: [id])
        check(refused.state.pendingBatch == nil && refusedEngine.pendingFileURL == nil && !refusedEngine.isRunning, "explicit copy handoff refusal permits safe retry")

        let failedSave = Harness()
        var failedSaveServices = failedSave.services()
        failedSaveServices.listAllNotes = { [] }
        failedSaveServices.saveState = { state in
            if let file = state.pendingBatch?.file { try? FileManager.default.removeItem(atPath: file) }
            throw NotesImportError.invalidData("synthetic state write failure")
        }
        let saveEngine = ImportEngine(cache: failedSave.cache, services: failedSaveServices)
        await saveEngine.startCopies(noteIds: [id])
        check(failedSave.opened.isEmpty && !saveEngine.isRunning, "copy handoff stops if durable recovery state cannot be written")

        let cancelled = Harness(); defer { cancelled.cleanup() }
        var cancelServices = cancelled.services()
        cancelServices.listAllNotes = { cancelled.candidates }
        cancelServices.openENEX = { url in
            cancelled.opened.append(url)
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        let cancelEngine = ImportEngine(cache: cancelled.cache, services: cancelServices)
        let task = Task { await cancelEngine.startCopies(noteIds: [id]) }
        for _ in 0..<100 where cancelled.opened.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        cancelEngine.cancel(); await task.value
        check(!cancelEngine.isRunning && cancelEngine.progress.phase == .idle && cancelled.state.pendingBatch?.copyItems != nil,
              "cancel during copy handoff keeps uncertain delivery pending and returns control")

        let legacy = PendingBatch(file: "/legacy.enex", noteIds: [id], expectedCount: 1, createdAt: Date())
        let legacyData = try encoder.encode(legacy)
        let decodedLegacy = try JSONDecoder().decode(PendingBatch.self, from: legacyData)
        check(!String(decoding: legacyData, as: UTF8.self).contains("copyItems") && decodedLegacy.copyItems == nil,
              "copy recovery metadata remains compatible with legacy pending batches")
    }
}
