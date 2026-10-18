import SwiftUI
import Foundation
import AppKit
import WebKit

private enum SidebarSelection: Hashable {
    case all
    case folder(id: String)
    case trash
}

private let mainViewNoteCache = NoteCache()

struct MainView: View {
    @EnvironmentObject private var onboarding: OnboardingState

    @StateObject private var pull = PullEngine(cache: mainViewNoteCache)

    @StateObject private var importer = ImportEngine(cache: mainViewNoteCache)

    private var cache: NoteCacheProtocol { mainViewNoteCache }

    @State private var sidebarSelection: SidebarSelection? = .all
    @State private var selectedNoteID: String?

    @State private var importSelection: Set<String> = []

    @State private var approvalPlan: ChangePlan?
    @State private var showingImportApproval = false
    @State private var showingPermissions = false
    @State private var showingSettings = false

    @State private var confirmingMoveToTrash = false

    @State private var errorAlert: ErrorAlertState?

    private struct ErrorAlertState: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private func showError(_ title: String, _ message: String) {
        errorAlert = ErrorAlertState(title: title, message: message)
    }
    @State private var automation: AutomationStatus = .notDetermined
    @State private var checking = true

    @State private var pullStarted = false
    @State private var importStarted = false

    @State private var noteBlocks: [NoteBlock] = []
    @State private var noteImages: [String: Data] = [:]
    @State private var noteBodyError: String?

    @State private var noteHTML = ""

    @State private var bodySaveTask: Task<Void, Never>?

    @State private var showingOriginal = false

    @State private var originalHTML: String = ""

    @State private var noteBodyHeight: CGFloat = 0

    @State private var originalBodyHeight: CGFloat = 0

    @State private var editorCommand: NoteEditorCommand?

    @State private var aiHeightOverride: CGFloat?

    @State private var dragStartHeight: CGFloat?

    @State private var dragStartLocation: CGFloat?

    @State private var persistedHTML = ""

    @State private var lastAutoSaveToast = Date.distantPast

    @State private var toast: ToastState?

    private struct ToastState: Identifiable {
        let id = UUID()
        var text: String
        var icon: String = "checkmark.circle.fill"
        var tint: Color = DS.Status.ok
        var duration: Double = 4
        var undo: (() -> Void)?
    }

    @State private var noteAIModified = false

    @StateObject private var noteAI = NoteAI(provider: AIProvider.shared)

    @StateObject private var chat = AIChatSession()

    private var trashedNoteIDs: Set<String> {
        let state = SyncStateStore.load()
        var ids: Set<String> = []
        for (noteId, record) in state.notes where record.trashed == true {
            ids.insert(noteId)
        }
        return ids
    }

    private var currentNotes: [CachedNote] {
        let trashed = trashedNoteIDs

        if let sidebarSelection, case .trash = sidebarSelection {
            return pull.notes
                .filter { trashed.contains($0.id) }
                .sorted { $0.modifyDate > $1.modifyDate }
        }

        let notes: [CachedNote]
        if let sidebarSelection, case .folder(let id) = sidebarSelection {
            notes = pull.notes.filter { $0.folderId == id }
        } else {
            notes = pull.notes
        }
        return notes
            .filter { !trashed.contains($0.id) }
            .sorted { $0.modifyDate > $1.modifyDate }
    }

    private func trashSelection() {
        guard !importSelection.isEmpty else { return }
        var state = SyncStateStore.load()
        for noteId in importSelection {
            if var record = state.notes[noteId] {
                record.trashed = true
                state.notes[noteId] = record
            }
        }
        try? SyncStateStore.save(state)
        importSelection.removeAll()
        Task {
            await pull.reloadFromCache()
            afterCacheChanged()
        }
        showToast("已移到回收站，可在回收站恢复")
    }

    private func restoreSelection() {
        guard !importSelection.isEmpty else { return }
        var state = SyncStateStore.load()
        for noteId in importSelection {
            if var record = state.notes[noteId] {
                record.trashed = false
                state.notes[noteId] = record
            }
        }
        try? SyncStateStore.save(state)
        importSelection.removeAll()
        Task {
            await pull.reloadFromCache()
            afterCacheChanged()
        }
        showToast("已恢复到原来的文件夹")
    }

    private func restoreFromTrash(_ note: CachedNote) {
        var state = SyncStateStore.load()
        if var record = state.notes[note.id] {
            record.trashed = false
            state.notes[note.id] = record
            try? SyncStateStore.save(state)
        }
        selectedNoteID = nil
        Task {
            await pull.reloadFromCache()
            afterCacheChanged()
        }
        showToast("已恢复到原来的文件夹")
    }

    private var showingTrash: Bool {
        if let sidebarSelection, case .trash = sidebarSelection { return true }
        return false
    }

    private func moveToTrash(_ note: CachedNote) {
        var state = SyncStateStore.load()
        if var record = state.notes[note.id] {
            record.trashed = true
            state.notes[note.id] = record
        } else {

            var record = NoteRecord(noteId: note.id,
                                    modifyDate: note.modifyDate,
                                    appleId: note.appleId,
                                    bodyHash: nil,
                                    title: note.title,
                                    snippet: note.snippet,
                                    aiModified: nil,
                                    status: .synced)
            record.trashed = true
            state.notes[note.id] = record
        }
        try? SyncStateStore.save(state)

        selectedNoteID = nil
        Task {
            await pull.reloadFromCache()
            afterCacheChanged()
        }
        showToast("已移到回收站")
    }

    private func deletePermanently(_ note: CachedNote) {
        try? cache.removeNote(id: note.id)

        var state = SyncStateStore.load()
        state.notes.removeValue(forKey: note.id)
        try? SyncStateStore.save(state)

        selectedNoteID = nil
        Task {
            await pull.reloadFromCache()
            afterCacheChanged()
        }
        showToast("已从米记桥删除（备忘录里仍保留）")
    }

    private var currentFolderTitle: String {
        if let sidebarSelection, case .trash = sidebarSelection {
            return "回收站"
        }
        guard let sidebarSelection, case .folder(let id) = sidebarSelection else {
            return "全部笔记"
        }
        return pull.folders.first { $0.id == id }?.name ?? "文件夹"
    }

    private var selectedNote: CachedNote? {
        guard let selectedNoteID else { return nil }
        return pull.notes.first { $0.id == selectedNoteID }
    }

    private func canSelectForImport(_ note: CachedNote) -> Bool {
        note.hasBody
    }

    private var selectableNotes: [CachedNote] {
        currentNotes.filter(canSelectForImport)
    }

    private var allSelected: Bool {
        !selectableNotes.isEmpty && selectableNotes.allSatisfy { importSelection.contains($0.id) }
    }

    private var canImport: Bool {
        !importSelection.isEmpty && !importer.isRunning && !pull.isRunning
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            noteList
        } detail: {
            detailPane
        }
        .task {

            automation = NotesBridge.automationStatus(askUser: false)
            checking = false

            await pull.reloadFromCache()
            afterCacheChanged()
        }
        .sheet(isPresented: $showingPermissions) { PermissionListSheet() }
        .sheet(isPresented: $showingSettings) { SettingsSheet() }

        .sheet(isPresented: $showingImportApproval) {
            if let plan = approvalPlan {
                ImportApprovalSheet(plan: plan) { approvedOverwrites in
                    startImport(approvedOverwrites: approvedOverwrites)
                }
            }
        }

        .onAppear {
            EditorShortcuts.shared.flushSave = { flushBodySave() }
            EditorShortcuts.shared.sendCommand = { command in

                guard isBodyEditorFocused else { return }
                editorCommand = command
            }
            EditorShortcuts.shared.undo = { redo in
                guard isBodyEditorFocused else { return false }
                editorCommand = redo ? .redo : .undo
                return true
            }
            EditorShortcuts.shared.setEditableNote(selectedNote?.hasBody == true)
        }
        .onDisappear {
            EditorShortcuts.shared.flushSave = nil
            EditorShortcuts.shared.sendCommand = nil
            EditorShortcuts.shared.undo = nil
            EditorShortcuts.shared.setEditableNote(false)
        }
        .onChange(of: selectedNote?.hasBody ?? false) { _, hasBody in
            EditorShortcuts.shared.setEditableNote(hasBody)
        }
    }

    private var isBodyEditorFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        var view: NSView? = responder
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section {
                Label("全部笔记", systemImage: "tray.full")
                    .badge(pull.notes.count)
                    .tag(SidebarSelection.all)
            } header: {
                Text("米记桥").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }

            Section {
                if pull.folders.isEmpty {
                    Text("还没有文件夹。点下面的「拉取」把云端的笔记取回本地。")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(pull.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(folder.noteCount)
                        .tag(SidebarSelection.folder(id: folder.id))
                }
            } header: {
                Text("文件夹").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }

            Section {
                Label("回收站", systemImage: "trash")
                    .badge(trashedNoteIDs.count)
                    .tag(SidebarSelection.trash)
            } header: {
                Text("整理").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }

            Section {
                if pullNeedsAttention {
                    DSStatusBar(icon: pullStatusIcon,
                                tint: pullStatusTint,
                                title: pullPhaseTitle,
                                detail: pullPhaseDetail,
                                busy: pull.isRunning)
                    if pull.isRunning {
                        Button("停止拉取") { pull.cancel() }
                            .controlSize(.small)
                    }
                }

                if importerNeedsAttention {
                    DSStatusBar(icon: importStatusIcon,
                                tint: importStatusTint,
                                title: importPhaseTitle,
                                detail: importPhaseDetail,
                                busy: importer.isRunning)
                    if importer.isRunning {
                        Button("停止导入") { importer.cancel() }
                            .controlSize(.small)
                    }
                }

                Button {
                    startPull()
                } label: {
                    Label("拉取", systemImage: "arrow.down.circle")
                }
                .disabled(pull.isRunning || importer.isRunning || onboarding.cookie == nil)

                Button {
                    showingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }

                if onboarding.cookie == nil {
                    Text("未登录小米账号，拉取暂不可用。")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("操作").font(DS.Fonts.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)

        .scrollContentBackground(.hidden)
        .background { sidebarGlass }
        .navigationTitle("米记桥")

        .navigationSplitViewColumnWidth(min: DS.Size.sidebarMinWidth,
                                        ideal: DS.Size.sidebarIdealWidth,
                                        max: DS.Size.sidebarMaxWidth)
    }

    @ViewBuilder
    private var sidebarGlass: some View {
        ZStack {

            DS.Palette.surfaceDeep

            LinearGradient(
                colors: [DS.Palette.accent.opacity(0.10),
                         DS.Palette.accent.opacity(0.02),
                         Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if #available(macOS 26.0, *) {

                Color.clear.glassEffect(.regular, in: Rectangle())
            }
        }
        .ignoresSafeArea()
    }

    private var importButtonTitle: String {
        "导入选中项（\(importSelection.count)）"
    }

    private var noteList: some View {
        Group {
            if currentNotes.isEmpty {
                emptyListPlaceholder
            } else {
                VStack(spacing: 0) {
                    listToolbar
                    Divider()
                    List(selection: $selectedNoteID) {
                        ForEach(currentNotes) { note in
                            NoteRow(note: note,
                                    isChecked: importBinding(for: note),
                                    isAIModified: note.id == selectedNoteID ? noteAIModified : note.aiModified)
                                .tag(note.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .navigationTitle(currentFolderTitle)

        .onChange(of: sidebarSelection) { _, _ in clearOffscreenSelection() }
    }

    private var listToolbar: some View {
        HStack(spacing: DS.Space.s) {
            Button(allSelected ? "全不选" : "全选") { toggleSelectAll() }
                .controlSize(.small)
                .disabled(selectableNotes.isEmpty || importer.isRunning)
                .help(allSelected
                      ? "取消勾选这个文件夹里所有可导入的笔记"
                      : "勾选这个文件夹里所有可导入的笔记")

            if !importSelection.isEmpty {
                if showingTrash {

                    Button {
                        restoreSelection()
                    } label: {
                        Text("恢复（\(importSelection.count)）")
                    }
                    .controlSize(.small)
                    .help("把这些笔记放回原来的文件夹")
                } else {
                    Button {
                        openImportApproval()
                    } label: {

                        Text(importButtonTitle)
                    }
                    .controlSize(.small)
                    .dsPrimaryButton()
                    .disabled(!canImport)
                    .help("先看变更计划，确认后才写进备忘录")
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))

                    Button(role: .destructive) {
                        trashSelection()
                    } label: {

                        Text("删除（\(importSelection.count)）")
                            .foregroundStyle(.red)
                    }
                    .controlSize(.small)
                    .help("移到回收站，不会删除笔记内容")
                }
            }

            Text(selectionSummary)
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .animation(.easeOut(duration: 0.16), value: importSelection.isEmpty)
    }

    private var selectionSummary: String {
        if importSelection.isEmpty {
            return "共 \(currentNotes.count) 条 · 勾选笔记后可导入"
        }

        return "已勾选 \(importSelection.count) 条"
    }

    @ViewBuilder
    private var emptyListPlaceholder: some View {
        VStack(spacing: DS.Space.s) {
            Text(pull.notes.isEmpty ? "这里还没有笔记" : "这个文件夹里没有笔记")
                .font(DS.Fonts.label)
                .foregroundStyle(.secondary)
            if pull.notes.isEmpty {
                Text("点左栏的「拉取」从云端把笔记取回本地——这一步只读，不会写进备忘录。")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let note = selectedNote {
            noteDetail(note)
        } else {
            guidePane
        }
    }

    private func noteDetail(_ note: CachedNote) -> some View {
        VStack(spacing: 0) {

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(note.title).font(DS.Fonts.screenTitle)

                        Spacer(minLength: DS.Space.m)

                        if noteAIModified {
                            Button(showingOriginal ? "显示当前" : "显示原文") {
                                if showingOriginal {
                                    showingOriginal = false
                                } else {
                                    originalHTML = cache.originalContent(for: note.id) ?? ""

                                    if !originalHTML.isEmpty { showingOriginal = true }
                                }
                            }
                            .controlSize(.small)
                            .help(showingOriginal ? "回到 AI 改写后的正文"
                                                  : "查看 AI 改写前的原文")
                        }

                        Button {
                            if showingTrash {
                                restoreFromTrash(note)
                            } else {
                                confirmingMoveToTrash = true
                            }
                        } label: {
                            Image(systemName: showingTrash ? "arrow.uturn.backward" : "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        .foregroundStyle(showingTrash ? Color.primary : Color.red)
                        .help(showingTrash ? "恢复到原来的文件夹" : "移到回收站")
                    }

                    HStack(spacing: DS.Space.s) {
                        Text(note.folderName.isEmpty ? "无文件夹" : note.folderName)
                            .font(DS.Fonts.label)
                            .foregroundStyle(.secondary)
                        Text(formattedDate(note.modifyDate))
                            .font(DS.Fonts.label)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if note.imported {
                            NoteBadge(text: "已导入", tint: DS.Status.ok)
                        }
                        if !note.hasBody {
                            NoteBadge(text: "正文非最新", tint: DS.Status.warn)
                        }
                    }

                    Divider()

                    bodySection(note)
                }
                .padding(DS.Space.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            aiResizeHandle

            aiSection(note)
                // **上限 440：正文必须先看得见。**
                // AI 区高度是按"消息条数 × 46"估的，但一条带图表的消息实际有 200pt+，
                // 估算严重偏低时内容会溢出；而拖过分隔条留下的 override 又可能没有上限。
                // 这里兜住：不管消息多少，AI 区最多占 440，剩下的给正文。
                .frame(height: min(aiPanelHeight, 440))
        }
        .navigationTitle(note.title)
        .alert("移到回收站？", isPresented: $confirmingMoveToTrash) {
            Button("移到回收站", role: .destructive) { moveToTrash(note) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("它会从所有文件夹中消失，但仍能在回收站里找到并恢复。")
        }
        .alert(item: $errorAlert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("知道了")))
        }

        .overlay(alignment: .bottom) { toastOverlay }

        .task(id: note.id) {

            chat.clear()

            showingOriginal = false
            originalHTML = ""

            noteBodyHeight = 0
            originalBodyHeight = 0
            loadBody(note)

            chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)
        }
        .onChange(of: noteHTML) { _, newValue in

            guard !newValue.isEmpty, selectedNote?.id == note.id else { return }
            scheduleBodySave(newValue, note: note)

            chat.noteContext = AIChatSession.NoteContext(title: note.title, html: newValue)
        }
    }

    @ViewBuilder
    private func bodySection(_ note: CachedNote) -> some View {

        if showingOriginal, !originalHTML.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Text("AI 改写前的原文（可直接修改）")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button("以此为准") {
                        restoreOriginalAsCurrent(note)
                    }
                    .controlSize(.small)
                    .help("把这份原文写回当前笔记，覆盖 AI 改写的版本")
                }

                WebNoteEditor(html: $originalHTML,
                              images: noteImages,
                              contentHeight: $originalBodyHeight,
                              command: $editorCommand)
                    .frame(height: max(originalBodyHeight, 240))
            }
        } else {
            editableBodySection(note)
        }
    }

    @ViewBuilder
    private func editableBodySection(_ note: CachedNote) -> some View {
        if note.hasBody {
            if let error = noteBodyError {
                DSStatusBar(icon: "exclamationmark.triangle.fill",
                            tint: DS.Status.warn,
                            title: "正文读取失败",
                            detail: error)

                Text(note.plainSnippet)
                    .font(DS.Fonts.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !noteBlocks.isEmpty {

                editorToolbar

                WebNoteEditor(html: $noteHTML,
                              images: noteImages,
                              contentHeight: $noteBodyHeight,
                              command: $editorCommand)

                    .frame(height: max(noteBodyHeight, 240))
            } else {
                Text(note.plainSnippet)
                    .font(DS.Fonts.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if noteBlocks.isEmpty {

            DSStatusBar(icon: "arrow.down.circle",
                        tint: DS.Status.warn,
                        title: "正文还没拉到本地",
                        detail: "点左栏的「拉取」把这条笔记的正文与图片下载下来，之后在这里离线也能看。")
            Text(note.plainSnippet)
                .font(DS.Fonts.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {

            DSStatusBar(icon: "clock.arrow.circlepath",
                        tint: DS.Status.warn,
                        title: "下面是上次拉到的旧版本",
                        detail: "这条笔记在云端改过，但本次没拉到新正文。点「拉取」可以重试；在拉到新版本之前，它不会被导入，也不能用 AI 重构。")
            NoteHTMLView(blocks: noteBlocks, images: noteImages)
        }
    }

    private func scheduleBodySave(_ html: String, note: CachedNote) {

        guard html != persistedHTML else { return }

        bodySaveTask?.cancel()
        bodySaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await persistBody(html, note: note)
        }
    }

    @MainActor
    private func persistBody(_ html: String, note: CachedNote) async {
        do {

            try cache.saveHTML(html, for: note.id)

            guard selectedNoteID == note.id else { return }
            persistedHTML = html
            announceAutoSave()
        } catch {

            showError("自动保存失败", error.localizedDescription)
        }
    }

    private func announceAutoSave() {
        if let toast, toast.undo != nil { return }

        let now = Date()
        guard now.timeIntervalSince(lastAutoSaveToast) > 2.5 else { return }
        lastAutoSaveToast = now
        showToast("已自动保存到本地",
                  icon: "checkmark.circle",
                  tint: DS.Status.ok,
                  duration: 1.6)
    }

    private func flushBodySave() {

        guard !showingOriginal else {
            showToast("原文改动请点「以此为准」写回正文",
                      icon: "info.circle",
                      tint: DS.Palette.accent,
                      duration: 3.5)
            return
        }
        guard let note = selectedNote, !noteHTML.isEmpty else { return }
        bodySaveTask?.cancel()

        if noteHTML == persistedHTML {
            showToast("已是最新版本", icon: "checkmark.circle", duration: 1.4)
            return
        }
        let html = noteHTML
        Task { @MainActor in await persistBody(html, note: note) }
    }

    /// AI 对话的产出 → **追加到当前正文末尾**，只写本地缓存。
    ///
    /// 不直接写「备忘录」：AI 给的是素材，最终要不要落到云端由用户在编辑器里决定。
    /// 之前的实现直接 `setBody`，等于每聊一句就覆盖一遍云端正文——
    /// 用户还没看清内容，远端那一份已经被改掉了，而且撤销也依赖再写一次。
    private func applyAIResult(_ text: String, to note: CachedNote) {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>" + $0.replacingOccurrences(of: "\n", with: "<br/>") + "</p>" }

        guard !paragraphs.isEmpty else { return }
        let addition = NotesHTMLSanitizer.sanitize(paragraphs.joined())
        guard !addition.isEmpty else { return }

        let previous = noteHTML
        // 追加而不是替换：原文一个字都不能动，AI 的内容接在后面
        noteHTML = previous + addition
        chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)

        // 复用编辑器既有的自动保存（600ms 防抖 → 写本地缓存）
        scheduleBodySave(noteHTML, note: note)

        showToast("已添加到正文末尾") { [previous] in
            noteHTML = previous
            chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)
            scheduleBodySave(previous, note: note)
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: DS.Space.xs) {
            toolButton("bold", "加粗") { editorCommand = .bold }
            toolButton("italic", "斜体") { editorCommand = .italic }
            toolButton("underline", "下划线") { editorCommand = .underline }

            Divider().frame(height: 18)

            toolButton("textformat.size.larger", "标题 1") { editorCommand = .heading1 }
            toolButton("textformat.size", "标题 2") { editorCommand = .heading2 }
            toolButton("textformat", "正文") { editorCommand = .paragraph }

            Divider().frame(height: 18)

            toolButton("list.bullet", "无序列表") { editorCommand = .bulletList }
            toolButton("list.number", "有序列表") { editorCommand = .orderedList }

            Divider().frame(height: 18)

            toolButton("photo.badge.plus", "插入图片") { editorCommand = .insertImage }

            Spacer(minLength: 0)

            toolButton("arrow.uturn.backward", "撤销") { editorCommand = .undo }
            toolButton("arrow.uturn.forward", "重做") { editorCommand = .redo }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.s))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.s)
                .strokeBorder(DS.Palette.stroke, lineWidth: 1)
        )
    }

    private func toolButton(_ symbol: String,
                            _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func loadBody(_ note: CachedNote) {
        noteBlocks = []
        noteImages = [:]
        noteHTML = ""
        noteBodyError = nil

        noteAIModified = note.aiModified

        guard let content = cache.content(for: note.id) else {

            if note.hasBody {
                noteBodyError = "本地缓存里找不到这条笔记的正文。可以点一次「拉取」重新下载。"

                showError("没有正文可显示", noteBodyError ?? "")
            }
            persistedHTML = ""
            return
        }
        noteHTML = content.html

        persistedHTML = content.html
        noteBlocks = NoteHTML.parse(content.html)
        noteImages = content.images
    }

    @ViewBuilder
    private func aiSection(_ note: CachedNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            AIChatView(session: chat) { text in
                applyAIResult(text, to: note)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Palette.surface)
    }

    private var aiResizeHandle: some View {
        ZStack {

            Color.clear

            if #available(macOS 26.0, *) {
                Capsule()
                    .frame(width: 64, height: 6)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Capsule()
                    .fill(DS.Palette.stroke)
                    .frame(width: 40, height: 3)
            }
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in

            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .gesture(

            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = aiPanelHeight
                        dragStartLocation = value.startLocation.y
                    }
                    let startY = dragStartLocation ?? value.startLocation.y

                    let delta = value.location.y - startY
                    aiHeightOverride = max(120, (dragStartHeight ?? aiPanelHeight) - delta)
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    dragStartLocation = nil
                }
        )
        .onTapGesture(count: 2) {

            aiHeightOverride = nil
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            DSToastBubble(
                text: toast.text,
                icon: toast.icon,
                tint: toast.tint,
                undo: toast.undo.map { action in
                    {
                        action()
                        withAnimation { self.toast = nil }
                    }
                }
            )

            .padding(.bottom, aiPanelHeight + DS.Space.m)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func restoreOriginalAsCurrent(_ note: CachedNote) {
        let html = NotesHTMLSanitizer.sanitize(originalHTML)
        guard !html.isEmpty else { return }
        let previous = noteHTML

        Task {
            do {
                try await noteAI.applyResult(
                    NoteAIResult(html: html, summary: "恢复原文"),
                    toNoteId: note.id
                )

                noteAI.clearAIModified(noteId: note.id)
                noteAIModified = false
                showingOriginal = false

                await pull.reloadFromCache()
                afterCacheChanged()
                if let refreshed = pull.notes.first(where: { $0.id == note.id }) {
                    loadBody(refreshed)
                } else {
                    loadBody(note)
                }
                chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)

                showToast("已用原文替换当前正文") { [previous] in
                    Task {
                        try? await noteAI.applyResult(
                            NoteAIResult(html: previous, summary: "撤销恢复"),
                            toNoteId: note.id
                        )
                        await pull.reloadFromCache()
                        afterCacheChanged()
                        if let restored = pull.notes.first(where: { $0.id == note.id }) {
                            loadBody(restored)
                        }
                        chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)
                    }
                }
            } catch {
                showError("恢复原文失败", error.localizedDescription)
            }
        }
    }

    private func showToast(_ text: String,
                           icon: String = "checkmark.circle.fill",
                           tint: Color = DS.Status.ok,
                           duration: Double = 4,
                           undo: (() -> Void)? = nil) {
        let state = ToastState(text: text,
                               icon: icon,
                               tint: tint,
                               duration: duration,
                               undo: undo)
        withAnimation(.easeOut(duration: 0.18)) { toast = state }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if toast?.id == state.id {
                withAnimation(.easeIn(duration: 0.15)) { toast = nil }
            }
        }
    }

    private var aiPanelHeight: CGFloat {

        if let override = aiHeightOverride {
            // 拖动也要有上限，否则向上一直拖会把正文压成零高度
            return min(max(120, override), 440)
        }

        var height: CGFloat = 88

        if !chat.pending.isEmpty { height += 60 }
        if !chat.messages.isEmpty {

            height += min(CGFloat(chat.messages.count) * 46, 340)
        }
        return height
    }

    private var guidePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                DSScreenHeader(title: "米记桥", subtitle: "把小米笔记搬到 Apple 备忘录。看是只读的，写要你确认。")
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    accountCard
                    permissionCard
                    transferCard
                }
                .padding(.horizontal, DS.Space.screen)
                .padding(.bottom, DS.Space.xl)
            }
        }
        .navigationTitle("米记桥")
    }

    private var accountCard: some View {
        DSCard(title: "小米账户", icon: "person.crop.circle") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DSInfoRow(label: "登录凭证", value: onboarding.cookie == nil ? "未登录" : "已保存")
                if let perm = CredentialsStore.cookieFilePermission() {
                    DSInfoRow(label: "文件权限", value: perm, mono: true)
                }
                DSInfoRow(label: "存储位置", value: CredentialsStore.directory.path)
                if onboarding.cookie == nil {

                    Button("去设置里登录小米账号") { showingSettings = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    private var permissionCard: some View {
        DSCard(title: "系统权限", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DSStatusBar(
                    icon: automation == .authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: automation == .authorized ? DS.Status.ok : DS.Status.warn,
                    title: "备忘录自动化权限",
                    detail: checking ? "检测中…" : automationText,
                    busy: checking
                )
                Button("查看权限清单") { showingPermissions = true }
                    .controlSize(.small)
            }
        }
    }

    private var transferCard: some View {
        DSCard(title: "拉取与导入", icon: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DSStatusBar(icon: pullStatusIcon,
                            tint: pullStatusTint,
                            title: pullPhaseTitle,
                            detail: pullPhaseDetail,
                            busy: pull.isRunning)

                DSStatusBar(icon: importStatusIcon,
                            tint: importStatusTint,
                            title: importPhaseTitle,
                            detail: importPhaseDetail,
                            busy: importer.isRunning)

                Text("「拉取」只把笔记下载到本机，不动备忘录；在中栏勾选、并确认过要写哪些文件夹之后，「导入」才会写进备忘录。")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DS.Space.s) {
                    Button("拉取") { startPull() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(pull.isRunning || importer.isRunning || onboarding.cookie == nil)

                    if !importSelection.isEmpty {
                        Button("导入选中项（\(importSelection.count)）") { openImportApproval() }
                            .controlSize(.small)
                            .disabled(!canImport)
                    }
                }
            }
        }
    }

    private func importBinding(for note: CachedNote) -> Binding<Bool> {
        Binding(
            get: { importSelection.contains(note.id) },
            set: { newValue in
                guard canSelectForImport(note) else { return }
                if newValue {
                    importSelection.insert(note.id)
                } else {
                    importSelection.remove(note.id)
                }
            }
        )
    }

    private func toggleSelectAll() {
        if allSelected {
            for note in selectableNotes { importSelection.remove(note.id) }
        } else {
            for note in selectableNotes { importSelection.insert(note.id) }
        }
    }

    private func openImportApproval() {
        guard canImport else { return }
        let ids = pull.notes.filter { importSelection.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        approvalPlan = importer.plan(noteIds: ids)
        showingImportApproval = true
    }

    private func startImport(approvedOverwrites: Set<String>) {
        let ids = pull.notes.filter { importSelection.contains($0.id) }.map(\.id)

        guard !ids.isEmpty, !importer.isRunning, !pull.isRunning else { return }
        importStarted = true

        Task {
            await importer.start(noteIds: ids, approvedOverwrites: approvedOverwrites)

            await pull.reloadFromCache()
            afterCacheChanged()
            clearAppliedSelection()

            if case .failed(let message) = importer.progress.phase {
                showError("导入失败", message)
            }
        }
    }

    private func startPull() {
        guard !pull.isRunning, !importer.isRunning else { return }
        pullStarted = true
        Task {
            await pull.pull()
            afterCacheChanged()

            if case .failed(let message) = pull.progress.phase {
                showError("拉取失败",
                          message + "\n\n请依次检查：\n"
                          + "1. 是否已登录小米账号（设置 → 账号）\n"
                          + "2. 网络连接是否正常\n"
                          + "3. 登录是否已过期——过期就重新登录一次")
            }
        }
    }

    private func afterCacheChanged() {
        let valid = Set(pull.notes.filter(canSelectForImport).map(\.id))
        importSelection.formIntersection(valid)

        if let id = selectedNoteID, !pull.notes.contains(where: { $0.id == id }) {
            selectedNoteID = nil
        }
    }

    private func clearAppliedSelection() {
        importSelection.subtract(importer.lastAppliedNoteIds)
    }

    private func clearOffscreenSelection() {
        guard let id = selectedNoteID else { return }
        if !currentNotes.contains(where: { $0.id == id }) {
            selectedNoteID = nil
        }
    }

    private var pullPhaseTitle: String {
        switch pull.progress.phase {
        case .idle: return pullStarted ? "拉取已停止" : "尚未拉取"
        case .fetchingList: return "正在获取笔记列表"
        case .fetchingBodies: return "正在拉取正文"
        case .downloadingImages: return "正在下载图片"
        case .finished: return "拉取完成"
        case .failed(let message): return "拉取失败：\(message)"
        }
    }

    private var pullPhaseDetail: String {
        let progress = pull.progress
        if let title = progress.currentTitle {
            return "正在处理「\(title)」（\(progress.completed)/\(progress.total)）"
        }

        if !pull.isRunning, let last = pull.logLines.last, last != pullPhaseTitle {
            return last
        }
        return "本地已有 \(pull.notes.count) 条笔记 · \(pull.folders.count) 个文件夹"
    }

    private var pullNeedsAttention: Bool {
        if pull.isRunning { return true }
        if case .failed = pull.progress.phase { return true }
        return pull.progress.phase == .idle && pullStarted
    }

    private var importerNeedsAttention: Bool {
        if importer.isRunning { return true }
        if case .failed = importer.progress.phase { return true }
        return importer.progress.phase == .idle && importStarted
    }

    private var pullStatusIcon: String {
        switch pull.progress.phase {
        case .idle: return "circle.dashed"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "arrow.down.circle"
        }
    }

    private var pullStatusTint: Color {
        switch pull.progress.phase {
        case .idle: return DS.Status.idle
        case .finished: return DS.Status.ok
        case .failed: return DS.Status.bad
        default: return DS.Palette.accent
        }
    }

    private var importPhaseTitle: String {
        switch importer.progress.phase {
        case .idle: return importStarted ? "导入已停止" : "尚未导入"
        case .preparing: return "正在准备要写入的内容"
        case .writing: return "正在写入「备忘录」"
        case .awaitingImport: return "等待「备忘录」接收"
        case .organizingFolders: return "正在按文件夹归位"
        case .finished: return "导入完成"
        case .failed(let message): return "导入失败：\(message)"
        }
    }

    private var importPhaseDetail: String {
        let progress = importer.progress
        if let title = progress.currentTitle {
            return "正在处理「\(title)」（\(progress.completed)/\(progress.total)）"
        }

        if !importer.isRunning, let last = importer.logLines.last, last != importPhaseTitle {
            return last
        }
        if progress.total > 0 {
            return "已处理 \(progress.completed)/\(progress.total) 条"
        }
        return "在中栏勾选要写入的笔记，然后点中栏顶部的「导入选中项」。"
    }

    private var importStatusIcon: String {
        switch importer.progress.phase {
        case .idle: return "circle.dashed"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "square.and.arrow.down.on.square"
        }
    }

    private var importStatusTint: Color {
        switch importer.progress.phase {
        case .idle: return DS.Status.idle
        case .finished: return DS.Status.ok
        case .failed: return DS.Status.bad
        default: return DS.Palette.accent
        }
    }

    private var automationText: String {
        switch automation {
        case .authorized: return "已授权。"
        case .denied: return "已被拒绝，相关功能将降级。"
        case .notDetermined: return "尚未授权。"
        case .targetNotRunning: return "「备忘录」未运行。"
        case .unknown(let c): return "状态未知（错误码 \(c)）。"
        }
    }

    private func formattedDate(_ milliseconds: Double) -> String {
        Self.dateFormatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct NoteRow: View {
    let note: CachedNote
    @Binding var isChecked: Bool

    let isAIModified: Bool

    private var selectable: Bool { note.hasBody }

    private var checkboxHelp: String {
        if !note.hasBody { return "正文不是最新版本，先点「拉取」" }
        if note.imported {
            return isChecked
                ? "取消勾选"
                : "已经导入过——勾选后会先出变更计划，覆盖更新要你逐条确认"
        }
        return isChecked ? "取消勾选" : "勾选后点列表顶部的「导入选中项」"
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Toggle("导入这条笔记", isOn: $isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!selectable)
                .help(checkboxHelp)
                .padding(.top, DS.Optical.hairline)

            VStack(alignment: .leading, spacing: DS.Optical.snug) {
                HStack(spacing: DS.Space.s) {
                    Text(note.title)
                        .font(DS.Fonts.rowTitle)
                        .lineLimit(1)
                    if note.imported {
                        NoteBadge(text: "已导入", tint: DS.Status.ok)
                    }
                    if isAIModified {
                        NoteBadge(text: "AI 已重构", tint: DS.Palette.accent)
                    }
                    if !note.hasBody {
                        NoteBadge(text: "正文非最新", tint: DS.Status.warn)
                    }
                    Spacer(minLength: 0)
                }
                Text(note.plainSnippet)
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
}

private struct NoteBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Optical.hairline)
            .background(DS.Palette.tint(tint), in: Capsule())
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var onboarding: OnboardingState
    @State private var automation: AutomationStatus = .notDetermined
    @State private var checking = true
    @State private var showingPermissions = false
    @State private var showingAISettings = false

    @State private var showingLogin = false

    @ObservedObject private var aiProvider = AIProvider.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(DS.Fonts.screenTitle)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    accountCard
                    permissionCard
                    aiCard
                }
                .padding(DS.Space.xl)
            }
        }
        .frame(width: DS.windowSize.width, height: DS.windowSize.height)
        .task {

            automation = NotesBridge.automationStatus(askUser: false)
            checking = false
        }
        .sheet(isPresented: $showingPermissions) { PermissionListSheet() }
        .sheet(isPresented: $showingAISettings) { AISettingsSheet() }
    }

    private var accountCard: some View {
        DSCard(title: "小米账户", icon: "person.crop.circle") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DSInfoRow(label: "登录凭证", value: onboarding.cookie == nil ? "未登录" : "已保存")
                if let perm = CredentialsStore.cookieFilePermission() {
                    DSInfoRow(label: "文件权限", value: perm, mono: true)
                }
                DSInfoRow(label: "存储位置", value: CredentialsStore.directory.path)

                if onboarding.cookie == nil {

                    Button("登录小米账号") { showingLogin = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                Button("清除登录凭证") {
                    CredentialsStore.clearCookie()
                    onboarding.cookie = nil
                }
                .controlSize(.small)
                .disabled(onboarding.cookie == nil)
            }
        }

        .sheet(isPresented: $showingLogin) { loginSheet }
    }

    private var loginSheet: some View {
        LoginStepView(
            onLoggedIn: { cookie in
                onboarding.loginLater(cookie: cookie)
                showingLogin = false
            },
            onSkip: { showingLogin = false }
        )
        .frame(width: DS.windowSize.width, height: DS.windowSize.height)
    }

    private var permissionCard: some View {
        DSCard(title: "系统权限", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DSStatusBar(
                    icon: automation == .authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: automation == .authorized ? DS.Status.ok : DS.Status.warn,
                    title: "备忘录自动化权限",
                    detail: checking ? "检测中…" : automationText,
                    busy: checking
                )
                Button("查看权限清单") { showingPermissions = true }
                    .controlSize(.small)
            }
        }
    }

    private var aiCard: some View {
        DSCard(title: "AI 服务", icon: "sparkles") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DSInfoRow(label: "配置状态",
                          value: aiProvider.config.isUsable ? "已配置" : "未配置")
                if aiProvider.config.isUsable {
                    DSInfoRow(label: "文本模型", value: aiProvider.config.model)
                    if !aiProvider.config.visionModel
                        .trimmingCharacters(in: .whitespaces).isEmpty {
                        DSInfoRow(label: "图片模型", value: aiProvider.config.visionModel)
                    }
                }
                Button("AI 设置") { showingAISettings = true }
                    .controlSize(.small)
            }
        }
    }

    private var automationText: String {
        switch automation {
        case .authorized: return "已授权。"
        case .denied: return "已被拒绝，相关功能将降级。"
        case .notDetermined: return "尚未授权。"
        case .targetNotRunning: return "「备忘录」未运行。"
        case .unknown(let c): return "状态未知（错误码 \(c)）。"
        }
    }
}

struct PermissionListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var automation: AutomationStatus = .notDetermined

    private var text: String {
        if let url = Bundle.main.url(forResource: "权限清单", withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return "未能载入权限清单文件。"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("权限清单").font(DS.Fonts.screenTitle)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)

            Divider()

            DSStatusBar(
                icon: automation == .authorized ? "checkmark.circle.fill" : "circle.dashed",
                tint: automation == .authorized ? DS.Status.ok : DS.Status.warn,
                title: "备忘录自动化权限",
                detail: automation == .authorized ? "当前已授权。" : "当前未授权。"
            )
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.m)

            DSReaderPane {
                MarkdownLite(text: text, bodySize: 12)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, DS.Space.xl)
        }
        .frame(width: 640, height: 580)
        .task {

            automation = NotesBridge.automationStatus(askUser: false)
        }
    }
}

private struct ImportApprovalSheet: View {
    let plan: ChangePlan

    let onExecute: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var approved: Set<String> = []

    @State private var skipped: Set<String> = []

    private var executableCreates: [PlannedChange] {
        plan.creates.filter { $0.blockedReason == nil }
    }

    private var executableMoves: [PlannedChange] {
        plan.moves.filter { $0.blockedReason == nil }
    }

    private var lowRiskChanges: [PlannedChange] {
        executableCreates + executableMoves
    }

    private var pendingOverwrites: [PlannedChange] {
        plan.needsApproval.filter { !approved.contains($0.id) && !skipped.contains($0.id) }
    }

    private var canExecute: Bool {
        !lowRiskChanges.isEmpty || !approved.isEmpty
    }

    private var summaryTitle: String {
        var parts: [String] = []
        if !executableCreates.isEmpty { parts.append("新建 \(executableCreates.count) 条") }
        if !executableMoves.isEmpty { parts.append("归入文件夹 \(executableMoves.count) 条") }
        if !plan.needsApproval.isEmpty {
            parts.append("覆盖 \(plan.needsApproval.count) 条已有笔记的正文")
        }
        if parts.isEmpty {
            return plan.isEmpty ? "这次没有需要变更的内容" : "这次没有可执行的变更"
        }
        return "将" + parts.joined(separator: "、") + "。"
    }

    private var summaryDetail: String {
        if plan.needsApproval.isEmpty {
            if plan.isEmpty { return "勾选的笔记都已经是最新状态，不必再写一遍。" }
            if lowRiskChanges.isEmpty { return "选中的笔记这次都无法执行，原因在下面。" }
            return "新建的笔记之后能自己删，归位只是挪文件夹——都不会覆盖已有内容，会随「执行」一并完成。"
        }
        if lowRiskChanges.isEmpty {
            return "覆盖会把「备忘录」里那条笔记的正文换成小米侧的版本，写掉就找不回来——请逐条确认；用「全部覆盖」可以一次批准剩下的全部。"
        }
        return "新建 / 归位这类可逆变更会随「执行」一并完成；覆盖会把正文换掉，写掉就找不回来——请逐条确认。"
    }

    private var summaryIcon: String {
        if !plan.needsApproval.isEmpty { return "exclamationmark.triangle.fill" }
        return lowRiskChanges.isEmpty ? "circle.dashed" : "checkmark.shield"
    }

    private var summaryTint: Color {
        if !plan.needsApproval.isEmpty { return DS.Status.warn }
        return lowRiskChanges.isEmpty ? DS.Status.idle : DS.Palette.accent
    }

    private var footerNote: String {
        guard canExecute else {
            if plan.needsApproval.isEmpty { return "这次没有可以执行的变更。" }
            return "至少批准一条覆盖才能执行；一条都不想要就点「取消」。"
        }
        var parts: [String] = []
        if !lowRiskChanges.isEmpty { parts.append("低危变更 \(lowRiskChanges.count) 条一并放行") }
        if !approved.isEmpty { parts.append("覆盖 \(approved.count) 条") }
        if !skipped.isEmpty { parts.append("跳过 \(skipped.count) 条") }
        if !pendingOverwrites.isEmpty {
            parts.append("还有 \(pendingOverwrites.count) 条未决定，不会执行")
        }
        return parts.joined(separator: " · ")
    }

    private var folderSummary: String? {
        let names = folderNames(of: executableCreates)
        let unfiled = executableCreates.filter {
            $0.targetFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count

        var parts: [String] = []
        if !names.isEmpty {
            let shown = names.count > 3
                ? names.prefix(3).joined(separator: "、") + " 等 \(names.count) 个文件夹"
                : names.joined(separator: "、")
            parts.append("会用到文件夹：\(shown)")
        }
        if unfiled > 0 {
            parts.append("\(unfiled) 条没有归属文件夹，留在「导入的备忘录」")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "；") + "。"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    DSStatusBar(icon: summaryIcon,
                                tint: summaryTint,
                                title: summaryTitle,
                                detail: summaryDetail)

                    if !lowRiskChanges.isEmpty { lowRiskCard }
                    if !plan.needsApproval.isEmpty { overwriteSection }
                    if !plan.blocked.isEmpty { blockedCard }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            DSFooter(note: footerNote) {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("执行") {
                    onExecute(approved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canExecute)
            }
        }
        .frame(width: 720, height: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("变更审批").font(DS.Fonts.screenTitle)
            Text("这是本次导入会对「备忘录」做的全部改动。可逆的批量放行，不可逆的逐条确认。")
                .font(DS.Fonts.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lowRiskCard: some View {
        DSCard(title: "会一并放行的变更", icon: "checkmark.shield") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if !executableCreates.isEmpty {
                    DSBulletRow(icon: "square.and.pencil",
                                title: "新建 \(executableCreates.count) 条笔记",
                                detail: "在「备忘录」里新建。之后不想要了可以自己删——不会覆盖任何已有内容。")
                }
                if !executableMoves.isEmpty {
                    DSBulletRow(icon: "folder",
                                title: "把 \(executableMoves.count) 条笔记归入文件夹",
                                detail: "只挪位置、不改正文；同名文件夹直接复用，不会重复创建。")
                }
                if let folderSummary {
                    Text(folderSummary)
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var overwriteSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Status.warn)
                    .padding(.top, DS.Optical.hairline)
                Text("以下 \(plan.needsApproval.count) 条已有笔记的正文会被替换，写掉就找不回来——请逐条确认。")
                    .font(DS.Fonts.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("全部覆盖") { approveAllPending() }
                    .controlSize(.small)
                    .disabled(pendingOverwrites.isEmpty)
                    .help("一次性批准剩下所有还没决定的覆盖；已经跳过的不动")
            }

            ForEach(plan.needsApproval) { change in
                overwriteCard(change)
            }
        }
    }

    private func overwriteCard(_ change: PlannedChange) -> some View {
        let isApproved = approved.contains(change.id)
        let isSkipped = skipped.contains(change.id)
        let folder = change.targetFolder.trimmingCharacters(in: .whitespacesAndNewlines)

        return DSCard(tint: isApproved ? DS.Status.ok : nil) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Text(change.title)
                        .font(DS.Fonts.rowTitle)
                        .lineLimit(1)
                    if isApproved {
                        NoteBadge(text: "将覆盖", tint: DS.Status.ok)
                    } else if isSkipped {
                        NoteBadge(text: "已跳过", tint: DS.Status.idle)
                    } else {
                        NoteBadge(text: "待确认", tint: DS.Status.warn)
                    }
                    Spacer(minLength: 0)
                }

                Text(folder.isEmpty ? "留在「导入的备忘录」" : "目标文件夹：\(folder)")
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: DS.Space.xs) {

                    Text("将写入的正文（小米侧的新版本）")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                    if change.preview.isEmpty {
                        Text("（这条笔记没有可预览的正文）")
                            .font(DS.Fonts.label)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(change.preview)
                            .font(DS.Fonts.label)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surfaceDeep, in: RoundedRectangle(cornerRadius: DS.Radius.s))

                HStack(spacing: DS.Space.s) {
                    if isApproved || isSkipped {
                        Button("撤销") { reset(change.id) }
                            .controlSize(.small)
                            .help("把这条改回「待确认」")
                    } else {
                        Button("覆盖") { approved.insert(change.id) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("跳过") { skipped.insert(change.id) }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var blockedCard: some View {
        DSCard(title: "这次无法执行的变更", icon: "nosign", tint: DS.Status.warn) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("下面 \(plan.blocked.count) 条不会被处理，也不会用别的方式做。每条的原因：")
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(plan.blocked.enumerated()), id: \.offset) { _, change in
                    DSBulletRow(icon: "xmark.circle",
                                title: change.title,
                                detail: "\(change.kind.label)：\(change.blockedReason ?? "原因未知")")
                }
            }
        }
    }

    private func approveAllPending() {
        approved.formUnion(pendingOverwrites.map(\.id))
    }

    private func reset(_ noteId: String) {
        approved.remove(noteId)
        skipped.remove(noteId)
    }

    private func folderNames(of changes: [PlannedChange]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for change in changes {
            let name = change.targetFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
        }
        return out
    }
}
