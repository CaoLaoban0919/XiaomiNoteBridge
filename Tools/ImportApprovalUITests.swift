import AppKit
import SwiftUI

/// Uses production views, synthetic cache data, and services that never write to Notes.
@main
@MainActor
struct ImportApprovalUITests {
    final class MemoryCache: NoteCacheProtocol {
        var bodyHTML = "<p>合成正文</p>"
        var notes = [CachedNote(id: "approval-ui-fixture", title: "审批弹窗验收", snippet: "合成正文",
                                folderId: "", folderName: "", createDate: 1, modifyDate: 1,
                                fileIds: [], imageFileIds: [], hasBody: true, imported: false,
                                appleId: nil, aiModified: false)]
        func loadIndex() -> (notes: [CachedNote], folders: [CachedFolder]) { (notes, []) }
        func saveIndex(notes: [CachedNote], folders: [CachedFolder]) throws { self.notes = notes }
        func html(for noteId: String) -> String? { bodyHTML }
        func content(for noteId: String) -> CachedNoteContent? { .init(html: bodyHTML, images: [:]) }
        func saveContent(_ content: CachedNoteContent, for noteId: String) throws {}
        func saveHTML(_ html: String, for noteId: String) throws {}
        func saveOriginalIfAbsent(_ content: CachedNoteContent, for noteId: String) throws {}
        func originalContent(for noteId: String) -> String? { nil }
        func removeNote(id noteId: String) throws {}
        func imageData(fileId: String) -> Data? { nil }
        func clearAll() throws {}
    }

    static var checks = 0
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(message)")
    }
    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task {
            await run()
            await runOverwriteChoiceTests()
            await runRichContentChoiceTests()
            await runCopySaveTests()
            await runCopyImportTests()
            print("APPROVAL UI: \(checks) assertions, \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
        NSApplication.shared.run()
    }
    struct Accessible {
        let object: NSObject
        func get(_ selector: String) -> Any? {
            let sel = NSSelectorFromString(selector)
            guard object.responds(to: sel) else { return nil }
            return object.perform(sel)?.takeUnretainedValue()
        }
        func accessibilityRole() -> NSAccessibility.Role? {
            (get("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:))
        }
        func accessibilityLabel() -> String? { get("accessibilityLabel") as? String }
        func accessibilityTitle() -> String? { get("accessibilityTitle") as? String }
        func accessibilityValue() -> Any? { get("accessibilityValue") }
        func flag(_ name: String) -> Bool {
            let sel = NSSelectorFromString(name)
            guard object.responds(to: sel) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: sel), to: Getter.self)(object, sel)
        }
        func isAccessibilityEnabled() -> Bool { flag("isAccessibilityEnabled") }
        func accessibilityPerformPress() -> Bool { flag("accessibilityPerformPress") }
    }
    static func elements(in root: Any, depth: Int = 0) -> [Accessible] {
        guard depth < 35, let object = root as? NSObject else { return [] }
        let element = Accessible(object: object)
        return [element] + (element.get("accessibilityChildren") as? [Any] ?? []).flatMap { elements(in: $0, depth: depth + 1) }
    }
    static func button(_ label: String, in window: NSWindow) -> Accessible? {
        elements(in: window).first {
            $0.accessibilityRole() == .button && ($0.accessibilityLabel() == label || $0.accessibilityTitle() == label)
        }
    }
    static func overwriteToggle(in window: NSWindow) -> Accessible? {
        elements(in: window).first {
            $0.accessibilityLabel() == "覆盖更新已有笔记" || $0.accessibilityTitle() == "覆盖更新已有笔记"
        }
    }
    static func contains(_ label: String, in window: NSWindow) -> Bool {
        elements(in: window).contains {
            $0.accessibilityLabel()?.contains(label) == true
                || ($0.accessibilityValue() as? String)?.contains(label) == true
                || $0.accessibilityTitle()?.contains(label) == true
        }
    }
    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
    static func dump(_ window: NSWindow) {
        for element in elements(in: window) {
            print("AX \(element.accessibilityRole()?.rawValue ?? "?") \(element.accessibilityLabel() ?? "") \(element.accessibilityTitle() ?? "") \(String(describing: element.accessibilityValue()))")
        }
    }
    static func run() async {
        let cache = MemoryCache()
        var executionCalls = 0
        var services = ImportEngine.Services()
        services.loadState = { SyncState() }
        services.saveState = { _ in }
        services.countNotes = {
            executionCalls += 1
            throw NSError(domain: "ApprovalUIFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "合成导入错误（未写入备忘录）"])
        }
        services.openENEX = { _ in preconditionFailure("UI test must not open a real import") }
        services.setBody = { _, _ in preconditionFailure("UI test must not change Apple Notes") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "导入审批 UI 验收（合成数据）"
        window.contentView = NSHostingView(rootView: MainView(cache: cache, importServices: services)
            .environmentObject(OnboardingState()))
        window.orderFront(nil)
        defer { window.close() }

        guard await waitUntil({ button("全选", in: window) != nil }) else {
            check(false, "production MainView exposes selection controls"); dump(window); return
        }
        check(button("全选", in: window)?.accessibilityPerformPress() == true, "select synthetic note using the real toolbar")
        guard await waitUntil({ button("导入选中项（1）", in: window) != nil }) else {
            check(false, "selection enables the real import button"); dump(window); return
        }
        check(button("导入选中项（1）", in: window)?.isAccessibilityEnabled() == true, "import button becomes enabled")
        check(button("导入选中项（1）", in: window)?.accessibilityPerformPress() == true, "first import click is delivered")
        guard await waitUntil({ window.attachedSheet != nil }), let first = window.attachedSheet else {
            check(false, "first click presents a native approval sheet"); dump(window); return
        }
        check(await waitUntil({ contains("变更审批", in: first) && contains("新建 1 条", in: first) }), "first sheet contains the actual nonempty plan")
        check(button("保存副本文件…", in: first)?.isAccessibilityEnabled() == true, "approval offers a separate copy-file action")
        check(contains("是否覆盖更新", in: first) && overwriteToggle(in: first)?.isAccessibilityEnabled() == false,
              "new-note approval explains overwrite choice and disables it without existing matches")
        check(executionCalls == 0, "opening approval does not start import")
        check(button("取消", in: first)?.accessibilityPerformPress() == true, "approval cancel button works")
        check(await waitUntil({ window.attachedSheet == nil }), "cancel dismisses approval")
        check(executionCalls == 0, "cancel does not invoke import")

        _ = button("导入选中项（1）", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ window.attachedSheet != nil }), let second = window.attachedSheet else {
            check(false, "approval can reopen after cancel"); return
        }
        check(await waitUntil({ button("执行", in: second) != nil }), "reopened sheet has execute control")
        check(button("执行", in: second)?.accessibilityPerformPress() == true, "execute invokes the approved request")
        check(await waitUntil({ executionCalls == 1 }), "execution reaches the injected import service exactly once")
        check(await waitUntil({ window.attachedSheet.map { contains("合成导入错误", in: $0) } == true }), "global import error is visible with no selected detail note")
        if let alert = window.attachedSheet { _ = button("知道了", in: alert)?.accessibilityPerformPress() }
        check(await waitUntil({ window.attachedSheet == nil }), "global import error can be dismissed")

        cache.notes[0].aiModified = true
        _ = button("导入选中项（1）", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ window.attachedSheet != nil }), let blocked = window.attachedSheet else {
            check(false, "blocked plan still presents approval"); return
        }
        check(await waitUntil({ contains("这次无法执行的变更", in: blocked) }), "blocked plan explains why nothing can run")
        check(button("执行", in: blocked)?.isAccessibilityEnabled() == false, "blocked plan cannot execute")
        _ = button("取消", in: blocked)?.accessibilityPerformPress()
        _ = await waitUntil { window.attachedSheet == nil }

        cache.notes = []
        _ = button("导入选中项（1）", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ window.attachedSheet != nil }), let empty = window.attachedSheet else {
            check(false, "empty plan still presents approval"); return
        }
        check(await waitUntil({ contains("这次没有需要变更的内容", in: empty) }), "empty plan shows feedback instead of silently returning")
        check(button("执行", in: empty)?.isAccessibilityEnabled() == false, "empty plan cannot execute")
        _ = button("取消", in: empty)?.accessibilityPerformPress()
        _ = await waitUntil { window.attachedSheet == nil }
        check(executionCalls == 1, "blocked and empty approvals do not invoke import")
    }

    static func runOverwriteChoiceTests() async {
        let cache = MemoryCache()
        cache.notes[0].imported = true
        cache.notes[0].appleId = "synthetic-apple-existing"
        var writes: [(String, String)] = []
        var connectionCalls = 0
        var services = ImportEngine.Services()
        services.loadState = { SyncState() }
        services.saveState = { _ in }
        services.countNotes = { connectionCalls += 1; return 0 }
        services.setBody = { writes.append(($0, $1)) }
        services.openENEX = { _ in preconditionFailure("overwrite must not create a duplicate import") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "覆盖更新 UI 验收（合成数据）"
        window.contentView = NSHostingView(rootView: MainView(cache: cache, importServices: services)
            .environmentObject(OnboardingState()))
        window.orderFront(nil)
        defer { window.close() }
        guard await waitUntil({ button("全选", in: window) != nil }) else {
            check(false, "overwrite fixture loads in MainView"); return
        }
        _ = button("全选", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ button("导入选中项（1）", in: window) != nil }) else {
            check(false, "overwrite fixture becomes selectable"); return
        }
        _ = button("导入选中项（1）", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ window.attachedSheet != nil }), let sheet = window.attachedSheet else {
            check(false, "overwrite approval opens"); return
        }
        check(await waitUntil({ overwriteToggle(in: sheet)?.isAccessibilityEnabled() == true }), "overwrite choice is enabled for an existing linked note")
        check(button("执行", in: sheet)?.isAccessibilityEnabled() == false, "overwrite updates default to off")
        check(contains("当前不覆盖更新", in: sheet) && writes.isEmpty && connectionCalls == 0, "default keeps existing notes untouched without contacting Notes")
        check(overwriteToggle(in: sheet)?.accessibilityPerformPress() == true, "user can enable overwrite updates")
        check(await waitUntil({ button("执行", in: sheet)?.isAccessibilityEnabled() == true && contains("覆盖更新 1 条", in: sheet) }), "enabling overwrite approves the displayed existing note")
        _ = overwriteToggle(in: sheet)?.accessibilityPerformPress()
        check(await waitUntil({ button("执行", in: sheet)?.isAccessibilityEnabled() == false }), "disabling overwrite removes authorization")
        _ = overwriteToggle(in: sheet)?.accessibilityPerformPress()
        _ = await waitUntil { button("执行", in: sheet)?.isAccessibilityEnabled() == true }
        _ = button("取消", in: sheet)?.accessibilityPerformPress()
        _ = await waitUntil { window.attachedSheet == nil }
        check(writes.isEmpty && connectionCalls == 0, "cancel after enabling overwrite never writes")

        _ = button("导入选中项（1）", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ window.attachedSheet != nil }), let reopened = window.attachedSheet else {
            check(false, "overwrite approval reopens"); return
        }
        check(await waitUntil({ button("执行", in: reopened)?.isAccessibilityEnabled() == false }), "reopening requires a fresh overwrite choice")
        _ = overwriteToggle(in: reopened)?.accessibilityPerformPress()
        _ = await waitUntil { button("跳过", in: reopened) != nil }
        check(button("跳过", in: reopened)?.accessibilityPerformPress() == true, "enabled overwrite can still be skipped per note")
        check(await waitUntil({ button("执行", in: reopened)?.isAccessibilityEnabled() == false }), "skipping the only overwrite disables execution")
        _ = button("覆盖", in: reopened)?.accessibilityPerformPress()
        check(await waitUntil({ button("执行", in: reopened)?.isAccessibilityEnabled() == true }), "a skipped note can be explicitly approved again")
        check(writes.isEmpty, "choosing overwrite alone never starts a write")
        _ = button("执行", in: reopened)?.accessibilityPerformPress()
        check(await waitUntil({ writes.count == 1 && window.attachedSheet == nil }), "execute performs exactly one injected overwrite")
        check(writes.first?.0 == "synthetic-apple-existing" && writes.first?.1.contains("合成正文") == true,
              "overwrite targets the linked note and uses the current local body")
        check(connectionCalls == 1, "overwrite execution connects once without creating another ENEX")
    }

    static func runRichContentChoiceTests() async {
        for includeNewNote in [false, true] {
            let cache = MemoryCache()
            cache.notes[0].imported = true
            cache.notes[0].appleId = "synthetic-image-note"
            cache.bodyHTML = "<p>含图正文</p><img fileid=\"synthetic-image\"/>"
            if includeNewNote {
                var new = cache.notes[0]
                new.id = "new-image-note"
                new.imported = false
                new.appleId = nil
                cache.notes.append(new)
            }
            var services = ImportEngine.Services()
            services.loadState = { SyncState() }
            services.saveState = { _ in preconditionFailure("approval must not save state") }
            services.countNotes = { preconditionFailure("approval must not contact Notes") }
            services.setBody = { _, _ in preconditionFailure("blocked images must not be stripped") }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(cache: cache, importServices: services)
                .environmentObject(OnboardingState()))
            window.orderFront(nil)
            defer { window.close() }
            guard await waitUntil({ button("全选", in: window) != nil }) else {
                check(false, "rich overwrite fixture loads"); continue
            }
            _ = button("全选", in: window)?.accessibilityPerformPress()
            let title = "导入选中项（\(cache.notes.count)）"
            guard await waitUntil({ button(title, in: window) != nil }) else {
                check(false, "rich overwrite fixture is selectable"); continue
            }
            _ = button(title, in: window)?.accessibilityPerformPress()
            guard await waitUntil({ window.attachedSheet != nil }), let sheet = window.attachedSheet else {
                check(false, "rich overwrite approval opens"); continue
            }
            check(await waitUntil({ contains("本次有 1 条已关联笔记", in: sheet) }), "linked image note is identified rather than described as unmatched (mixed: \(includeNewNote))")
            check(overwriteToggle(in: sheet)?.isAccessibilityEnabled() == false, "unsupported image overwrite keeps the choice disabled (mixed: \(includeNewNote))")
            check(button("保存副本文件…", in: sheet)?.isAccessibilityEnabled() == true,
                  "blocked image updates can still be saved as copy files (mixed: \(includeNewNote))")
            check(contains("暂不支持图文覆盖", in: sheet) && contains("原笔记保持不变", in: sheet), "image restriction and original preservation are explained (mixed: \(includeNewNote))")
            check(!contains("本次没有可覆盖更新的已关联笔记", in: sheet), "blocked image plan does not claim no linked notes (mixed: \(includeNewNote))")
            check(button("执行", in: sheet)?.isAccessibilityEnabled() == includeNewNote, "only a mixed plan permits importing its new note")
            _ = button("保存副本文件…", in: sheet)?.accessibilityPerformPress()
            check(await waitUntil({ contains("副本保存失败", in: sheet) }), "copy preparation failure remains visible inside approval (mixed: \(includeNewNote))")
            check(button("保存副本文件…", in: sheet)?.isAccessibilityEnabled() == true,
                  "failed copy preparation allows a retry (mixed: \(includeNewNote))")
            if includeNewNote {
                check(contains("新建 1 条", in: sheet) && contains("无法执行 1 条，原笔记保留", in: sheet), "mixed summary separates new imports from blocked updates")
            } else {
                check(contains("所选已有笔记暂不支持覆盖更新", in: sheet), "image-only summary names the unsupported operation")
            }
            _ = button("取消", in: sheet)?.accessibilityPerformPress()
            check(await waitUntil({ window.attachedSheet == nil }), "rich content approval can be canceled")
        }
    }

    static func runCopyImportTests() async {
        let cache = MemoryCache()
        cache.notes[0].imported = true
        cache.notes[0].appleId = "copy-original"
        cache.notes[0].aiModified = true
        cache.bodyHTML = "<p>副本</p><img src=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=\"/>"
        var state = SyncState()
        var opened: [URL] = []
        var candidates: [AppleNote] = []
        var services = ImportEngine.Services()
        services.loadState = { state }
        services.saveState = { state = $0 }
        services.listAllNotes = { candidates }
        services.countNotes = { preconditionFailure("copy must confirm its own titles rather than unrelated note counts") }
        services.setBody = { _, _ in preconditionFailure("copy cannot overwrite existing notes") }
        services.renderHTML = { $0 }
        services.openENEX = { url in
            opened.append(url)
            candidates = (state.pendingBatch?.copyItems ?? []).map {
                AppleNote(id: "ui-copy-" + $0.noteId, name: $0.title, folder: "导入的备忘录", created: nil, modified: nil, bodyLength: 0)
            }
        }
        services.pollInterval = 1_000_000
        services.importTimeout = 1
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(cache: cache, importServices: services)
            .environmentObject(OnboardingState()))
        window.orderFront(nil)
        defer {
            window.close()
            for url in opened { try? FileManager.default.removeItem(at: url) }
        }
        guard await waitUntil({ button("全选", in: window) != nil }) else {
            check(false, "copy import fixture loads"); return
        }
        _ = button("全选", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ button("导入选中项（1）", in: window) != nil }) else {
            check(false, "copy import fixture selected"); return
        }
        _ = button("导入选中项（1）", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ window.attachedSheet != nil }), let sheet = window.attachedSheet else {
            check(false, "copy import approval opens"); return
        }
        check(await waitUntil { button("副本存入 Apple 备忘录", in: sheet)?.isAccessibilityEnabled() == true },
              "linked AI-edited rich note offers the copy-to-Notes action")
        check(contains("备忘录弹窗确认", in: sheet), "approval explains the native Notes import confirmation")
        check(button("执行", in: sheet)?.isAccessibilityEnabled() == false, "blocked normal import does not prevent independent copy")
        _ = button("副本存入 Apple 备忘录", in: sheet)?.accessibilityPerformPress()
        check(await waitUntil { window.attachedSheet == nil && opened.count == 1 }, "copy button dismisses approval and dispatches ENEX exactly once")
        check(await waitUntil { state.pendingBatch == nil && button("导入选中项（1）", in: window) == nil },
              "confirmed copy clears only its completed selection")
        let xml = opened.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check(xml.contains("<title>审批弹窗验收（1）</title>") && xml.contains("<resource>"), "UI hands off a numbered copy with its image attachment")
        check(cache.notes[0].appleId == "copy-original" && state.notes.isEmpty,
              "copy UI leaves original cache association and synchronization records intact")
    }

    static func runCopySaveTests() async {
        let cache = MemoryCache()
        cache.notes[0].imported = true
        cache.notes[0].appleId = "existing-copy-source"
        cache.bodyHTML = "<p>副本正文</p><img src=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=\"/>"
        var services = ImportEngine.Services()
        services.loadState = { SyncState() }
        services.saveState = { _ in preconditionFailure("saving a copy must not update sync state") }
        services.countNotes = { preconditionFailure("saving a copy must not contact Notes") }
        services.setBody = { _, _ in preconditionFailure("saving a copy must not overwrite a note") }
        services.openENEX = { _ in preconditionFailure("saving a copy must not auto-import it") }
        services.renderHTML = { $0 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minote-copy-ui-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { check(false, "copy UI fixture directory can be created"); return }
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(cache: cache, importServices: services)
            .environmentObject(OnboardingState()))
        window.orderFront(nil)
        defer { window.close() }
        guard await waitUntil({ button("全选", in: window) != nil }) else {
            check(false, "copy save fixture loads"); return
        }
        _ = button("全选", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ button("导入选中项（1）", in: window) != nil }) else {
            check(false, "copy save fixture can be selected"); return
        }
        _ = button("导入选中项（1）", in: window)?.accessibilityPerformPress()
        guard await waitUntil({ window.attachedSheet != nil }), let approval = window.attachedSheet else {
            check(false, "copy save approval opens"); return
        }
        _ = button("保存副本文件…", in: approval)?.accessibilityPerformPress()
        guard await waitUntil({ NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible } }),
              let panel = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: { $0.isVisible }) else {
            check(false, "save copy presents the native save panel"); dump(approval); return
        }
        defer { if panel.isVisible { panel.cancel(nil) } }
        check(panel.nameFieldStringValue.contains("副本") && panel.nameFieldStringValue.contains("enex"), "copy filename is labeled and defaults to ENEX")
        check(panel.allowedContentTypes.contains { $0.conforms(to: .xml) }, "native save panel uses an XML-compatible ENEX file type")
        // The save panel's controls run in another process. Cancel via its supported API;
        // pipeline tests separately save and parse the exact generated ENEX bytes.
        DispatchQueue.main.async { panel.cancel(nil) }
        check(await waitUntil({ !panel.isVisible }), "native save panel cancellation returns to approval")
        check(!contains("副本已保存", in: approval), "canceling file save does not show a false success")
        check((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true,
              "canceling the save panel does not write an output file")
        check(button("保存副本文件…", in: approval)?.isAccessibilityEnabled() == true, "canceling save allows another copy attempt")
        _ = button("保存副本文件…", in: approval)?.accessibilityPerformPress()
        check(await waitUntil({ NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible } }), "copy save dialog can reopen after cancellation")
        if let reopened = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: { $0.isVisible }) {
            DispatchQueue.main.async { reopened.cancel(nil) }
            _ = await waitUntil { !reopened.isVisible }
        }
        check(cache.notes[0].appleId == "existing-copy-source", "saving the copy keeps the existing note association")
        _ = button("取消", in: approval)?.accessibilityPerformPress()
        _ = await waitUntil { window.attachedSheet == nil }
    }
}
