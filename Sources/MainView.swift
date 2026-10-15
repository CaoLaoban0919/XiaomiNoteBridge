import SwiftUI
import Foundation

// 主界面（三栏式）。这一版的核心变化：**「拉取」与「导入」彻底分开**。
//
//   拉取（Pull）  只读。把小米的笔记与图片下到本地缓存，**不碰备忘录一个字**，
//                 拉完就能在软件里直接看（详情栏只读缓存，完全不联网）。
//   导入（Import）才写。用户在中栏手动勾选，先由引擎「只算不写」出一份变更计划、
//                 在审批 sheet 里过目（可逆的批量放行、覆盖正文的逐条点头），
//                 点过「执行」才调 `start(noteIds:approvedOverwrites:)` 写进备忘录。
//
// 界面只依赖 `Store/StoreContract.swift` 里的三个协议（拉取 / 导入 / 缓存），
// 不 import 任何引擎实现，也没有任何直接写备忘录的调用——
// 写备忘录这件事只有导入引擎能做，而且必须先经用户审批。

// MARK: - 侧栏选中项

/// 左栏列表的选中值：「全部笔记」或某个小米文件夹。
///
/// 用枚举而不是 `String?`：文件夹 id 是小米侧的字符串，
/// 若拿它当选中值，「全部笔记」就得靠一个魔法空串表示，很容易和真实 id 撞上。
private enum SidebarSelection: Hashable {
    case all
    case folder(id: String)
}

// MARK: - 详情栏 AI 重构的状态机

/// 详情栏 AI 区域的全部状态。**每一次只处在其中一个态**，界面按态渲染对应出口：
///
///     idle ──(用 AI 重构这条笔记)──▶ running ──成功──▶ preview ──(写入备忘录)──▶ applied
///                                              │                    │
///                                              │                    └─(放弃)──▶ idle
///                                              └──失败──▶ failed ──(再试)──▶ running
///
/// 关键词：**先预览再写入**。`preview` 态只把结果留在内存里，
/// 只有用户点「写入备忘录」才会真正碰用户的备忘录数据。
private enum AIRewriteState {
    /// 无进行中的任务：显示输入框与主按钮。
    case idle
    /// 正在请求模型（重构中或写入中）。
    case running
    /// 已拿到结果、等待用户确认。
    case preview(AIRewritePreview)
    /// 请求或写入失败。文本直接来自 `error.localizedDescription`，不吞。
    case failed(String)
    /// 写入成功。
    case applied(String)
}

/// 预览所需的一整套：模型结果 + 已解析好的块。
///
/// 解析在拿到结果时做一次并在这里缓存，避免 SwiftUI 每次重绘都重跑一遍 HTML 解析
/// （与 `noteBlocks` 同一个理由）。
private struct AIRewritePreview {
    var result: NoteAIResult
    var blocks: [NoteBlock]
}

// MARK: - 本地缓存

/// 本地缓存实例。**全场只此一份**：拉取引擎往里写正文、导入引擎从里读正文并写回
/// 「已导入」标记、详情栏从里读正文给用户看。三边拿到的必须是同一个落点。
///
/// 放文件作用域而不是视图属性，是因为 `@StateObject` 的默认值不能引用实例成员；
/// 写成全局 `let` 还顺带避开了 SwiftUI 每次重建视图都新造一份实例的问题。
private let mainViewNoteCache = NoteCache()

// MARK: - 主界面（三栏式，仿 Apple 备忘录）

struct MainView: View {
    @EnvironmentObject private var onboarding: OnboardingState

    // MARK: 引擎

    /// 拉取引擎：**只读**。把小米的笔记与图片拉到本地缓存。
    ///
    /// 与引擎之间只走 `PullEngineProtocol`（`StoreContract.swift` 定死的契约），
    /// 不碰它的任何内部状态。用具体类型持有是为了让 SwiftUI 能观察 `progress / notes`
    /// 这些 `@Published` 的变化——和原来 `SyncEngine` 那条路一模一样。
    @StateObject private var pull = PullEngine(cache: mainViewNoteCache)
    /// 导入引擎：**只有用户在确认框点过「导入」之后**才会被调用。
    @StateObject private var importer = ImportEngine(cache: mainViewNoteCache)

    /// 详情栏的正文与图片**只从这里读，不联网**。
    private var cache: NoteCacheProtocol { mainViewNoteCache }

    // MARK: 界面状态

    @State private var sidebarSelection: SidebarSelection? = .all
    @State private var selectedNoteID: String?
    /// 中栏勾选的笔记 id（导入选择）。**可以跨文件夹勾选**，确认框里会按文件夹汇总。
    @State private var importSelection: Set<String> = []
    /// 待审批的变更计划。点「导入选中项」时由 `importer.plan`（**只算不写**）生成，
    /// 用户在审批 sheet 里对着它逐条决定，点「执行」才真正开写。
    @State private var approvalPlan: ChangePlan?
    @State private var showingImportApproval = false
    @State private var showingPermissions = false
    @State private var showingSettings = false
    @State private var automation: AutomationStatus = .notDetermined
    @State private var checking = true

    /// 用户在这次会话里点过拉取 / 导入没有。
    ///
    /// 引擎取消之后会把 phase 退回 `.idle`，与「一次都没跑过」是同一个值；
    /// 靠这两个标记才能把状态条的文案说准（「已停止」而不是「尚未开始」）。
    @State private var pullStarted = false
    @State private var importStarted = false

    // MARK: 详情栏的正文渲染状态（数据全部来自本地缓存）

    /// **解析结果存这里，不在 body 里现解析**——否则每次重绘都要重新跑一遍 HTML 解析。
    @State private var noteBlocks: [NoteBlock] = []
    @State private var noteImages: [String: Data] = [:]
    @State private var noteBodyError: String?

    /// 选中笔记的**正文 HTML 片段**。AI 重构需要把它发给模型；
    /// `noteBlocks` 是解析后的模型，拿不回原串，所以单独存一份。
    @State private var noteHTML = ""
    /// 选中笔记是否已被 AI 重构过（决定详情栏上的标记）。
    @State private var noteAIModified = false

    // MARK: 详情栏的 AI 重构

    /// 与设置界面共用同一个客户端实例——否则设置改了地址、发请求的还是旧配置。
    @ObservedObject private var aiProvider = AIProvider.shared
    @StateObject private var noteAI = NoteAI(provider: AIProvider.shared)
    /// 用户填写的额外要求（可选）
    @State private var aiInstruction = ""
    /// 详情栏 AI 区域的状态机
    @State private var aiState: AIRewriteState = .idle
    /// 当前这次 AI 任务属于哪条笔记。用户中途切走时，在途任务的结果不能再贴回来。
    @State private var aiRunningNoteId: String?
    @State private var showingAISettings = false

    // MARK: - 数据切片

    /// 当前选中文件夹下的笔记。默认按修改时间倒序，与用户的直觉一致。
    private var currentNotes: [CachedNote] {
        let notes: [CachedNote]
        if let sidebarSelection, case .folder(let id) = sidebarSelection {
            notes = pull.notes.filter { $0.folderId == id }
        } else {
            notes = pull.notes
        }
        return notes.sorted { $0.modifyDate > $1.modifyDate }
    }

    private var currentFolderTitle: String {
        guard let sidebarSelection, case .folder(let id) = sidebarSelection else {
            return "全部笔记"
        }
        return pull.folders.first { $0.id == id }?.name ?? "文件夹"
    }

    private var selectedNote: CachedNote? {
        guard let selectedNoteID else { return nil }
        return pull.notes.first { $0.id == selectedNoteID }
    }

    /// 这条笔记能不能被勾选去导入。
    ///
    /// 硬条件只有 `hasBody`：没有正文导过去就是空的、或过期的，两种都不是用户想要的结果。
    /// **已导入的笔记现在可以勾选**——那表示「按小米侧的版本覆盖更新」。
    /// 覆盖会写掉备忘录里那条笔记现有的正文，属于高危操作，
    /// 所以导入前会先出一份变更计划，这种要逐条点头才会真正执行。
    private func canSelectForImport(_ note: CachedNote) -> Bool {
        note.hasBody
    }

    /// 当前文件夹里可以被勾选的笔记（「全选」作用在它们身上）。
    private var selectableNotes: [CachedNote] {
        currentNotes.filter(canSelectForImport)
    }

    private var allSelected: Bool {
        !selectableNotes.isEmpty && selectableNotes.allSatisfy { importSelection.contains($0.id) }
    }

    /// 「导入选中项」能否点：**没有勾选就必须禁用**，别让按钮可点却没反应。
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
            _ = await NotesBridge.ensureNotesRunning()
            automation = NotesBridge.automationStatus(askUser: false)
            checking = false
            // 进入界面先读缓存：**不联网**，让用户马上看到上次拉到的内容。
            await pull.reloadFromCache()
            afterCacheChanged()
        }
        .sheet(isPresented: $showingPermissions) { PermissionListSheet() }
        .sheet(isPresented: $showingSettings) { SettingsSheet() }
        .sheet(isPresented: $showingAISettings) { AISettingsSheet() }
        // 导入的审批入口。**点开它不等于开始写**——只是把「会写掉什么」先摆出来，
        // 真正写备忘录要等用户在 sheet 里点「执行」，那时才会走到 `startImport`。
        .sheet(isPresented: $showingImportApproval) {
            if let plan = approvalPlan {
                ImportApprovalSheet(plan: plan) { approvedOverwrites in
                    startImport(approvedOverwrites: approvedOverwrites)
                }
            }
        }
    }

    // MARK: - 左栏：文件夹列表 + 操作

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
                    openImportApproval()
                } label: {
                    Label(importButtonTitle, systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!canImport)

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
        .navigationTitle("米记桥")
        // 不设这个的话用系统默认宽度，实测偏窄，文件夹列表会显得局促。
        // 给 min/max 是为了保留用户自己拖宽拖窄的能力。
        .navigationSplitViewColumnWidth(min: DS.Size.sidebarMinWidth,
                                        ideal: DS.Size.sidebarIdealWidth,
                                        max: DS.Size.sidebarMaxWidth)
    }

    private var importButtonTitle: String {
        importSelection.isEmpty ? "导入选中项" : "导入选中项（\(importSelection.count)）"
    }

    // MARK: - 中栏：笔记列表（带导入勾选）

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
                            NoteRow(note: note, isChecked: importBinding(for: note))
                                .tag(note.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .navigationTitle(currentFolderTitle)
        // 切文件夹时，详情栏不该继续显示别的文件夹里的笔记。
        .onChange(of: sidebarSelection) { _, _ in clearOffscreenSelection() }
    }

    /// 列表顶部的「全选 / 全不选」与计数。
    private var listToolbar: some View {
        HStack(spacing: DS.Space.s) {
            Button(allSelected ? "全不选" : "全选") { toggleSelectAll() }
                .controlSize(.small)
                .disabled(selectableNotes.isEmpty || importer.isRunning)
                .help(allSelected
                      ? "取消勾选这个文件夹里所有可导入的笔记"
                      : "勾选这个文件夹里所有可导入的笔记")

            Text(selectionSummary)
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }

    private var selectionSummary: String {
        if importSelection.isEmpty {
            return "共 \(currentNotes.count) 条 · 勾选后点左栏的「导入选中项」"
        }
        return "共 \(currentNotes.count) 条 · 已勾选 \(importSelection.count) 条"
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

    // MARK: - 右栏：详情（只读缓存）

    @ViewBuilder
    private var detailPane: some View {
        if let note = selectedNote {
            noteDetail(note)
        } else {
            guidePane
        }
    }

    private func noteDetail(_ note: CachedNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text(note.title).font(DS.Fonts.screenTitle)

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
                    if note.aiModified {
                        NoteBadge(text: "AI 已重构", tint: DS.Palette.accent)
                    }
                    if !note.hasBody {
                        NoteBadge(text: "正文非最新", tint: DS.Status.warn)
                    }
                }

                Divider()

                aiSection(note)

                bodySection(note)
            }
            .padding(DS.Space.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(note.title)
        // id 绑定到笔记本身：切换笔记时重新从缓存读一次，同一笔记不会重复读。
        .task(id: note.id) {
            // 换了笔记，上一条的 AI 输入与预览/结果都不该带过来。
            aiState = .idle
            aiInstruction = ""
            aiRunningNoteId = nil
            loadBody(note)
        }
    }

    /// 正文区域。数据全部来自本地缓存，**这个视图不会发出任何网络请求**。
    @ViewBuilder
    private func bodySection(_ note: CachedNote) -> some View {
        if note.hasBody {
            if let error = noteBodyError {
                DSStatusBar(icon: "exclamationmark.triangle.fill",
                            tint: DS.Status.warn,
                            title: "正文读取失败",
                            detail: error)
                // 读不到正文时至少把本地已有的摘要显示出来，别留一片空白
                Text(note.snippet)
                    .font(DS.Fonts.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !noteBlocks.isEmpty {
                NoteHTMLView(blocks: noteBlocks, images: noteImages)
            } else {
                Text(note.snippet)
                    .font(DS.Fonts.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if noteBlocks.isEmpty {
            // 缓存里连旧版本都没有 → 这条笔记的正文一次都没拉下来过
            DSStatusBar(icon: "arrow.down.circle",
                        tint: DS.Status.warn,
                        title: "正文还没拉到本地",
                        detail: "点左栏的「拉取」把这条笔记的正文与图片下载下来，之后在这里离线也能看。")
            Text(note.snippet)
                .font(DS.Fonts.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // `hasBody == false` 但磁盘上还留着上一版正文：小米侧改过、这次没拉到新的。
            // 内容仍然给用户看（离线阅读是这软件的本分），但**必须说清它是旧的**，
            // 否则用户会把过期内容当成最新。
            DSStatusBar(icon: "clock.arrow.circlepath",
                        tint: DS.Status.warn,
                        title: "下面是上次拉到的旧版本",
                        detail: "这条笔记在云端改过，但本次没拉到新正文。点「拉取」可以重试；在拉到新版本之前，它不会被导入，也不能用 AI 重构。")
            NoteHTMLView(blocks: noteBlocks, images: noteImages)
        }
    }

    /// 从**本地缓存**取正文与图片，并在这里解析一次。
    ///
    /// 结果存进 `noteBlocks` / `noteImages` —— 渲染时直接用，
    /// 不在 `body` 里调 `NoteHTML.parse`（那会让每次重绘都重新解析一遍 HTML）。
    private func loadBody(_ note: CachedNote) {
        noteBlocks = []
        noteImages = [:]
        noteHTML = ""
        noteBodyError = nil
        // 「已被 AI 重构」的标记来自缓存里的笔记本身，与正文能否加载无关。
        noteAIModified = note.aiModified

        // 注意：`hasBody == false` 时磁盘上**仍可能留着旧版本的正文**（小米侧改过、
        // 这次没拉到新的）。这里照样读出来，由 `bodySection` 负责把「这是旧版本」
        // 标清楚——总比让用户点开只看到一条摘要强。
        guard let content = cache.content(for: note.id) else {
            // hasBody 为真却没有正文文件 = 索引与缓存文件对不上（正常不该发生）。
            if note.hasBody {
                noteBodyError = "本地缓存里找不到这条笔记的正文。可以点一次「拉取」重新下载。"
            }
            return
        }
        noteHTML = content.html
        noteBlocks = NoteHTML.parse(content.html)
        noteImages = content.images
    }

    // MARK: - 详情栏的 AI 区域

    /// AI 区域放在「状态行之下、正文之上」：
    /// 入口与进度常驻可见，不必把长正文滚到底才能发现功能；
    /// 预览卡片插在这里、下方紧接着就是原文，便于上下对照。
    @ViewBuilder
    private func aiSection(_ note: CachedNote) -> some View {
        DSCard(title: "用 AI 重构", icon: "sparkles") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if noteAIModified {
                    DSStatusBar(icon: "wand.and.stars",
                                tint: DS.Status.ok,
                                title: "已被 AI 重构",
                                detail: "这条笔记的正文是 AI 重构后的版本，导入时不会覆盖它。")
                }

                if !aiProvider.config.isUsable {
                    DSStatusBar(icon: "exclamationmark.triangle.fill",
                                tint: DS.Status.warn,
                                title: "尚未配置 AI 服务",
                                detail: "填写服务地址、密钥与模型之后才能使用。")
                    Button("AI 设置") { showingAISettings = true }
                        .controlSize(.small)
                }

                TextField("额外要求（可选），例如：把这段手绘整理成表格",
                          text: $aiInstruction)
                    .textFieldStyle(.roundedBorder)
                    .disabled(aiIsRunning)

                Button("用 AI 重构这条笔记") { runAIRewrite(note) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!aiCanRun)

                aiFeedback(note)
            }
        }
    }

    /// AI 区域的状态反馈。每个态都给出明确出口，失败也不吞错误。
    @ViewBuilder
    private func aiFeedback(_ note: CachedNote) -> some View {
        switch aiState {
        case .idle:
            EmptyView()

        case .running:
            DSStatusBar(icon: "sparkles",
                        tint: DS.Palette.accent,
                        title: "正在用 AI 重构…",
                        detail: "请求已经发出，请稍候。",
                        busy: true)

        case .failed(let message):
            DSStatusBar(icon: "exclamationmark.triangle.fill",
                        tint: DS.Status.bad,
                        title: "重构失败",
                        detail: message)

        case .applied(let message):
            DSStatusBar(icon: "checkmark.circle.fill",
                        tint: DS.Status.ok,
                        title: message,
                        detail: "已写入备忘录，并标记为不会被导入覆盖。")

        case .preview(let preview):
            aiPreview(preview, note: note)
        }
    }

    /// 重构预览：先给用户看，确认了才落盘。
    private func aiPreview(_ preview: AIRewritePreview, note: CachedNote) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("重构预览（尚未写入）").font(DS.Fonts.cardTitle)

            Text(preview.result.summary)
                .font(DS.Fonts.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // 复用现成的 HTML 渲染。AI 结果按约束不含图片，所以图片表给空。
            NoteHTMLView(blocks: preview.blocks, images: [:])

            HStack(spacing: DS.Space.s) {
                Button("写入备忘录") { applyAIResult(preview, to: note) }
                    .buttonStyle(.borderedProminent)
                Button("放弃") { aiState = .idle }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.tint(DS.Palette.accent),
                    in: RoundedRectangle(cornerRadius: DS.Radius.m))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m)
                .stroke(DS.Palette.accent.opacity(0.25), lineWidth: DS.Optical.hairline)
        )
    }

    // MARK: - AI 行为

    private func runAIRewrite(_ note: CachedNote) {
        guard !aiIsRunning else { return }
        aiState = .running

        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = Self.aiImages(from: noteImages)
        let body = noteHTML
        let title = note.title
        let noteId = note.id
        aiRunningNoteId = noteId

        Task {
            do {
                let result = try await noteAI.rewriteNote(noteId: noteId,
                                                          title: title,
                                                          body: body,
                                                          images: images,
                                                          instruction: instruction.isEmpty ? nil : instruction)
                // 用户在等待期间切到了别的笔记 → 这次结果作废，别把预览贴错地方。
                guard aiRunningNoteId == noteId else { return }
                // 解析放在拿到结果时做一次并随预览一起存，避免每次重绘都重解析。
                let blocks = NoteHTML.parse(result.html)
                aiState = .preview(AIRewritePreview(result: result, blocks: blocks))
            } catch {
                // 错误一律如实显示，不因「可能已切走」而吞掉。
                aiState = .failed(error.localizedDescription)
            }
        }
    }

    private func applyAIResult(_ preview: AIRewritePreview, to note: CachedNote) {
        guard !aiIsRunning else { return }
        aiState = .running
        let noteId = note.id
        aiRunningNoteId = noteId

        Task {
            do {
                try await noteAI.applyResult(preview.result, toNoteId: noteId)
                guard aiRunningNoteId == noteId else { return }
                noteAIModified = true
                // 写回之后以缓存为准刷新：重读一次索引与正文，同样**不联网**。
                await pull.reloadFromCache()
                afterCacheChanged()
                if let refreshed = pull.notes.first(where: { $0.id == noteId }) {
                    loadBody(refreshed)
                }
                aiState = .applied("已写入备忘录")
            } catch {
                // 写入失败必须让用户看到，不吞。
                aiState = .failed(error.localizedDescription)
            }
        }
    }

    private var aiIsRunning: Bool {
        if case .running = aiState { return true }
        return false
    }

    /// 主按钮能否点击：配置可用、没有正在跑的任务、正文已加载出来、且有内容可处理。
    ///
    /// 还要求 `hasBody == true`（正文与云端一致）：正文不是最新版本时，
    /// 重构结果写回去等于拿旧内容盖掉更新的版本，宁可先禁用。
    private var aiCanRun: Bool {
        guard aiProvider.config.isUsable,
              !aiIsRunning,
              noteBodyError == nil,
              selectedNote?.hasBody == true else { return false }
        let hasText = !noteHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !noteImages.isEmpty
    }

    /// 把缓存里的图片字节包成发给模型的形态，并按魔数补上 MIME。
    private static func aiImages(from images: [String: Data]) -> [AIImage] {
        images.values.map { AIImage(data: $0, mimeType: imageMimeType($0)) }
    }

    /// 从字节头判断图片类型。服务端通常按内容探测，但显式声明更稳；判不出来时回落 PNG。
    private static func imageMimeType(_ data: Data) -> String {
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

    // MARK: - 引导页（未选中任何笔记时）

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

    // MARK: 引导页卡片

    private var accountCard: some View {
        DSCard(title: "小米账户", icon: "person.crop.circle") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DSInfoRow(label: "登录凭证", value: onboarding.cookie == nil ? "未登录" : "已保存")
                if let perm = CredentialsStore.cookieFilePermission() {
                    DSInfoRow(label: "文件权限", value: perm, mono: true)
                }
                DSInfoRow(label: "存储位置", value: CredentialsStore.directory.path)
                if onboarding.cookie == nil {
                    // 未登录拉不了笔记。补登录入口在「设置 → 小米账户」里。
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

    /// 「拉取」与「导入」的分工说明 + 两边的进度。
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
                    Button("导入选中项") { openImportApproval() }
                        .controlSize(.small)
                        .disabled(!canImport)
                }
            }
        }
    }

    // MARK: - 导入流程（先出计划，再审批）

    /// 中栏某一行的勾选绑定。
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

    /// 点「导入选中项」：先让引擎「只算不写」列一份变更计划，再把审批 sheet 摆出来。
    ///
    /// 这一步**不写任何东西**。计划摆给用户看，低危的批量放行、覆盖正文的逐条决定，
    /// 用户在 sheet 里点过「执行」之后才会走到 `startImport`。
    private func openImportApproval() {
        guard canImport else { return }
        let ids = pull.notes.filter { importSelection.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        approvalPlan = importer.plan(noteIds: ids)
        showingImportApproval = true
    }

    /// 用户点了审批 sheet 里的「执行」才会走到这里。**这是界面上唯一的写备忘录入口。**
    ///
    /// - Parameter approvedOverwrites: 用户逐条批准覆盖的 noteId。
    ///   不在这个集合里的覆盖（跳过的、没决定的、执行不了的）一律不执行——
    ///   这是红绿灯机制的核心，交给引擎把关。
    private func startImport(approvedOverwrites: Set<String>) {
        let ids = pull.notes.filter { importSelection.contains($0.id) }.map(\.id)
        // 两个引擎不并行：拉取在跑的这一刻，缓存索引随时会变，导入要等它停下来。
        guard !ids.isEmpty, !importer.isRunning, !pull.isRunning else { return }
        importStarted = true

        Task {
            await importer.start(noteIds: ids, approvedOverwrites: approvedOverwrites)
            // 导入结束后从缓存重读：`imported` 标记由导入引擎写进索引。
            await pull.reloadFromCache()
            afterCacheChanged()
            clearImportedSelection()
        }
    }

    // MARK: - 动作

    private func startPull() {
        guard !pull.isRunning, !importer.isRunning else { return }
        pullStarted = true
        Task {
            await pull.pull()
            afterCacheChanged()
        }
    }

    /// 缓存或列表变化之后收尾：清掉已经失效的勾选与已消失的详情选中项。
    ///
    /// 勾选集里只保留「仍然存在、还有正文」的笔记。
    /// **已导入的笔记不再被清掉**——现在勾选它表示「覆盖更新」，是合法意图；
    /// 导入成功之后该清哪批，由 `clearImportedSelection` 专门负责。
    private func afterCacheChanged() {
        let valid = Set(pull.notes.filter(canSelectForImport).map(\.id))
        importSelection.formIntersection(valid)

        if let id = selectedNoteID, !pull.notes.contains(where: { $0.id == id }) {
            selectedNoteID = nil
        }
    }

    /// 一次导入跑完之后收尾：把已经写进备忘录的清出勾选，没写成的留着方便直接重试。
    ///
    /// 判据只能用 `imported` 标记：新建成功的会变成 true → 清掉；失败的仍是 false →
    /// 留在勾选里。覆盖的成功与否从标记上区分不了（它本来就是 true），这里按「已处理」
    /// 对待——真失败的话引擎的状态条会显示原因。
    private func clearImportedSelection() {
        let stillUnimported = Set(pull.notes.filter { !$0.imported && $0.hasBody }.map(\.id))
        importSelection.formIntersection(stillUnimported)
    }

    /// 切换文件夹时，若详情栏里那条笔记不在新文件夹里就取消选中。
    private func clearOffscreenSelection() {
        guard let id = selectedNoteID else { return }
        if !currentNotes.contains(where: { $0.id == id }) {
            selectedNoteID = nil
        }
    }

    // MARK: - 辅助

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
        // 停下来之后（完成 / 取消）用引擎日志的最后一句话作说明：
        // 它带着「成功几条、复用几条、缺几张图」这类结论，比我另拼一句更准。
        // 与标题完全相同的行就不重复显示了。
        if !pull.isRunning, let last = pull.logLines.last, last != pullPhaseTitle {
            return last
        }
        return "本地已有 \(pull.notes.count) 条笔记 · \(pull.folders.count) 个文件夹"
    }

    /// 左栏要不要留着这条状态条。
    ///
    /// 跑着的时候当然要；停下来之后**失败和「刚被停止」也要看得见**——
    /// 不然用户点了停止，界面上什么都没留下。成功则不必占位：
    /// 文件夹条数与「已导入」小标已经把结果说清楚了。
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
        // 停下来之后用引擎日志的最后一句话作说明——「N 条已进入「备忘录」」
        // 这类结论出自引擎，比界面自己拼一句更准。与标题相同的行不重复显示。
        if !importer.isRunning, let last = importer.logLines.last, last != importPhaseTitle {
            return last
        }
        if progress.total > 0 {
            return "已处理 \(progress.completed)/\(progress.total) 条"
        }
        return "在中栏勾选要写入的笔记，然后点「导入选中项」。"
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

// MARK: - 笔记列表行

/// 中栏的一行：勾选框 + 标题 + 摘要 + 状态小标。
private struct NoteRow: View {
    let note: CachedNote
    @Binding var isChecked: Bool

    /// 唯一的硬条件是「有正文」。已导入的笔记**也能勾**——
    /// 那表示「按小米侧的版本覆盖更新」，导入前会逐条让用户确认。
    private var selectable: Bool { note.hasBody }

    private var checkboxHelp: String {
        if !note.hasBody { return "正文不是最新版本，先点「拉取」" }
        if note.imported {
            return isChecked
                ? "取消勾选"
                : "已经导入过——勾选后会先出变更计划，覆盖更新要你逐条确认"
        }
        return isChecked ? "取消勾选" : "勾选后点左栏的「导入选中项」"
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
                    if note.aiModified {
                        NoteBadge(text: "AI 已重构", tint: DS.Palette.accent)
                    }
                    if !note.hasBody {
                        NoteBadge(text: "正文非最新", tint: DS.Status.warn)
                    }
                    Spacer(minLength: 0)
                }
                Text(note.snippet)
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
}

/// 状态小标（「已导入」「正文非最新」这类）。
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

// MARK: - 设置

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var onboarding: OnboardingState
    @State private var automation: AutomationStatus = .notDetermined
    @State private var checking = true
    @State private var showingPermissions = false
    @State private var showingAISettings = false
    /// 补登录弹窗（用户从引导页「先跳过」进来时用）
    @State private var showingLogin = false
    /// 读配置状态用于展示，同时保证设置改完这里能立刻刷新。
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
            _ = await NotesBridge.ensureNotesRunning()
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
                    // 用户可能是从引导页「先跳过」进来的。这里是补登录的入口，
                    // **没有它的话，跳过登录就等于把自己困在未登录态里再也登不上**。
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
        // 挂在 accountCard 上而不是外层 VStack：那一层已经挂了两个 .sheet，
        // 同一个视图上叠多个 sheet 在 SwiftUI 里有互相顶掉的风险。
        .sheet(isPresented: $showingLogin) { loginSheet }
    }

    /// 补登录。**直接复用引导流程里的登录页**，不另做一套界面。
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

// MARK: - 权限清单（兑现协议第 5E 条）

/// 如实列出申请过的权限、用途与撤销方式。
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
            _ = await NotesBridge.ensureNotesRunning()
            automation = NotesBridge.automationStatus(askUser: false)
        }
    }
}

// MARK: - 变更审批（红绿灯）

/// 导入前的变更审批。**这是用户唯一能看清并逐条放行「会写掉什么」的地方。**
///
/// 分档思路与 Trae 的权限系统一致——例外驱动，而不是每条都弹卡：
///   - 低危（新建 / 归入文件夹）：可逆，批量放行，只列类别与条数；
///   - 高危（覆盖已有笔记的正文）：写掉找不回来，逐条一张卡，各自「覆盖 / 跳过」；
///     不想一条条点，可以点「全部覆盖」一次性批准**剩下所有还没决定的**。
///
/// 「全部覆盖」的作用域就是当前这份计划：审批状态全部留在内存（sheet 自己的 @State）
/// 里，不落盘。关掉或重新导入都会拿一份新计划、重新审一遍。
///
/// 执行不了的（`blockedReason != nil`）单独列一块，把原因原文摆出来——
/// 用户有权知道哪些选了却不会被做、为什么，**不允许默默吞掉**。
private struct ImportApprovalSheet: View {
    let plan: ChangePlan
    /// 点「执行」时回调。参数是用户逐条批准覆盖的 noteId；
    /// 不在这个集合里的 overwrite（跳过的、还没决定的、执行不了的）一律不执行。
    let onExecute: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 已批准覆盖的 noteId
    @State private var approved: Set<String> = []
    /// 已明确跳过的 noteId。与「还没决定」是两回事：
    /// 「全部覆盖」只批准剩下未决定的，不动已经跳过的。
    @State private var skipped: Set<String> = []

    // MARK: 数据切片

    private var executableCreates: [PlannedChange] {
        plan.creates.filter { $0.blockedReason == nil }
    }

    private var executableMoves: [PlannedChange] {
        plan.moves.filter { $0.blockedReason == nil }
    }

    /// 能执行的低危变更（新建 / 归入文件夹）。点「执行」会一并放行。
    private var lowRiskChanges: [PlannedChange] {
        executableCreates + executableMoves
    }

    /// 还没决定的覆盖（既没批准，也没跳过）。
    private var pendingOverwrites: [PlannedChange] {
        plan.needsApproval.filter { !approved.contains($0.id) && !skipped.contains($0.id) }
    }

    /// 「执行」能不能点：**至少要有东西可执行**。
    /// 一条都没批准、又没有低危变更时禁用——别让按钮可点却没反应。
    private var canExecute: Bool {
        !lowRiskChanges.isEmpty || !approved.isEmpty
    }

    // MARK: 文案

    /// 顶部摘要：先用一句话说清这次会改什么。
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

    /// 底部说明：实时反映用户做了哪些决定，也解释「执行」为什么不能点。
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

    /// 会用到哪些文件夹。沿用旧确认框的透明度：让用户知道备忘录里会多出哪些文件夹。
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

    // MARK: - 界面

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

    /// 低危变更：不逐条列，说清楚类别与条数，随「执行」批量放行。
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

    /// 高危变更：逐条一张卡，卡上看得见「将要被替换掉的是什么」。
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
                    Text("将被替换掉的正文（「备忘录」里这条笔记现在的样子）")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                    if change.preview.isEmpty {
                        Text("（这条笔记暂时没有可预览的正文）")
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

    /// 执行不了的：如实列出原因，别让用户以为「选了就会做」。
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

    // MARK: - 动作

    /// 「全部覆盖」= 一次性批准剩下所有还没决定的覆盖。已经跳过的不动。
    private func approveAllPending() {
        approved.formUnion(pendingOverwrites.map(\.id))
    }

    /// 把一条改回「待确认」。
    private func reset(_ noteId: String) {
        approved.remove(noteId)
        skipped.remove(noteId)
    }

    /// 去重、保序、剔掉空名（空 = 没有归属文件夹，留在「导入的备忘录」）。
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
