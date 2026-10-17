import SwiftUI
import Foundation
import AppKit

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
    /// 正文编辑的防抖句柄（停止输入 600ms 后才落盘）
    @State private var bodySaveTask: Task<Void, Never>?
    /// 是否正在看 AI 改写前的原文
    @State private var showingOriginal = false
    /// 原文 HTML（切到原文态时才读一次，不在每次重绘时读盘）
    @State private var originalHTML: String = ""
    /// 正文 WebView 量出来的实际高度（0 表示还没量到）
    @State private var noteBodyHeight: CGFloat = 0
    /// 原文 WebView 量出来的实际高度
    @State private var originalBodyHeight: CGFloat = 0
    /// 正文编辑器的工具栏指令（加粗、插图…），执行后编辑器自己清空
    @State private var editorCommand: NoteEditorCommand?
    /// 用户手动拖出来的 AI 区高度。为 nil 时走自动计算。
    ///
    /// 为什么不直接改自动公式：用户一旦手动定过高度，说明他对"多少够用"
    /// 有自己的判断；此时再让公式随消息条数涨落，等于把他刚调好的位置又推走。
    @State private var aiHeightOverride: CGFloat?
    /// 拖动开始时的基准高度（gesture 的 translation 是累计值，必须自己记起点）
    @State private var dragStartHeight: CGFloat?

    /// 临时提示气泡（带撤销）。几秒后自动消失。
    @State private var toast: ToastState?

    private struct ToastState: Identifiable {
        let id = UUID()
        var text: String
        var undo: (() -> Void)?
    }
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

    /// 对话式 AI 会话。与当前选中的笔记绑定，切笔记时清空。
    @StateObject private var chat = AIChatSession()

    /// 拖拽悬停的区域。
    ///
    /// 同一份文件拖到不同区域会有不同结果，没有视觉反馈用户无法预判松手会发生什么。
    @State private var hoveredZone: DropZone?

    private enum DropZone: Equatable {
        /// 拖到笔记区：作为这条笔记的素材
        case note
        /// 拖到对话区：直接交给 AI 分析
        case ai
    }

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
            // **不要在这里拉起「备忘录」。**（主界面 / 设置页 / 权限清单页三处同理）
            //
            // `ensureNotesRunning()` 会在这些页面一出现时就把备忘录启动起来，
            // 而备忘录启动后自己会 activate，把键盘焦点从本应用抢走——
            // 用户看到的就是「一开软件就跳出记事本、输入框打不进字」。
            // 这三处只需要读本地缓存、查询权限状态，都不需要备忘录在运行；
            // 真正需要它的是「导入」和「核验导入结果」，到那一步再由 `ImportEngine`
            // 自己确保运行。
            //
            // 另外 `automationStatus` 现在会先查进程表：未运行且用户没点「授权」时
            // 直接返回 `.targetNotRunning`，**不会发出任何 Apple Event**，
            // 因此也不会把备忘录唤起来。
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
        VStack(spacing: 0) {
            // **上半：笔记**。自己滚动，AI 不再占用它的高度。
            //
            // 原来是「标题 + AI 区 + 正文」全塞进一个 ScrollView，
            // 结果 AI 那 340 点高度直接把正文挤到屏幕外——
            // 而用户打开笔记，第一件事是看笔记。
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(note.title).font(DS.Fonts.screenTitle)

                        Spacer(minLength: DS.Space.m)

                        // 「显示原文」放在标题行右下角：它是这条笔记的属性，
                        // 不属于正文内容，放在正文顶部会和第一段文字抢视线。
                        // 只有被 AI 改过的笔记才有"原文"这个概念，其它笔记不显示。
                        if note.aiModified {
                            Button(showingOriginal ? "显示当前" : "显示原文") {
                                if showingOriginal {
                                    showingOriginal = false
                                } else {
                                    originalHTML = cache.originalContent(for: note.id) ?? ""
                                    // 历史笔记（在备份机制之前被 AI 改过的）没有原文。
                                    // 此时不切换状态——否则按钮会变成「显示当前」，
                                    // 而正文仍然是当前版本，用户点回去也没变化。
                                    if !originalHTML.isEmpty { showingOriginal = true }
                                }
                            }
                            .controlSize(.small)
                            .help(showingOriginal ? "回到 AI 改写后的正文"
                                                  : "查看 AI 改写前的原文")
                        }
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
            // **笔记区不挂 drop 目标。**
            //
            // 挂上之后整块区域变成投放区，会拦截 hover、文字选中和点击——
            // 而它对应的功能（把图插进正文）其实还没实现，只是把文件丢进对话。
            // 用一个只挡交互、不兑现承诺的 drop 区换掉一块本该能选中复制的正文，不划算。
            // 拖拽入口保留在下方 AI 区，语义也更明确：拖进来就是交给 AI 处理。

            // 可拖动的分隔条：向上拖 AI 变高，向下拖 AI 变矮。
            aiResizeHandle

            // **下半：AI，固定在底部，高度随内容变化。**
            // 空时只有一行输入框；有消息后长高；拖拽悬停时再临时加高。
            aiSection(note)
                .frame(height: aiPanelHeight)
                // **不加高度过渡动画。**
                // 附件预览条出现/消失时高度会跳变，配 0.18 秒动画会让整块区域滑一下，
                // 视觉上像多出一层浮动的面板。高度直接跳，反而干净。
                .dropDestination(for: URL.self) { urls, _ in
                    handleDrop(urls, into: .ai)
                } isTargeted: { targeted in
                    // 同上：只在轮到自己时才动 `hoveredZone`，
                    // 否则两个区域的回调会互相覆盖，谁都亮不起来。
                    if targeted {
                        hoveredZone = .ai
                    } else if hoveredZone == .ai {
                        hoveredZone = nil
                    }
                }
                .overlay { dropOverlay(for: .ai) }
        }
        .navigationTitle(note.title)
        // 底部居中的临时提示：写入、撤销这类"刚发生"的反馈放这里，
        // 不打断操作，也不占用正文位置。
        .overlay(alignment: .bottom) { toastOverlay }
        // id 绑定到笔记本身：切换笔记时重新从缓存读一次，同一笔记不会重复读。
        .task(id: note.id) {
            // 换了笔记，上一条的 AI 输入与预览/结果都不该带过来。
            aiState = .idle
            aiInstruction = ""
            aiRunningNoteId = nil
            // 对话也要清空：上一轮的上下文与这条笔记无关，
            // 留着会让模型把 A 笔记的内容当成 B 笔记的背景。
            chat.clear()
            // 原文视图同理，不能带着上一条笔记的状态
            showingOriginal = false
            originalHTML = ""
            // 高度是上一条笔记量出来的，必须清零：
            // 否则新笔记会先用旧高度撑一屏，再突然缩回去。
            noteBodyHeight = 0
            originalBodyHeight = 0
            loadBody(note)
            // **把这条笔记交给会话。**
            // 没有这一步，模型看不到正文，用户说"总结这篇""改第二段"时它只能反问。
            chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)
        }
        .onChange(of: noteHTML) { _, newValue in
            // 换笔记时 `loadBody` 会把 noteHTML 重设一遍，那次不该触发落盘；
            // 只处理"当前这条笔记"的编辑。
            guard !newValue.isEmpty, selectedNote?.id == note.id else { return }
            scheduleBodySave(newValue, note: note)
            // 编辑之后同步给会话，否则 AI 眼里还是改动前的正文
            chat.noteContext = AIChatSession.NoteContext(title: note.title, html: newValue)
        }
    }

    /// 正文区域。数据全部来自本地缓存，**这个视图不会发出任何网络请求**。
    @ViewBuilder
    private func bodySection(_ note: CachedNote) -> some View {
        // 原文视图优先：它是只读的、且与当前正文是完全两套内容，
        // 不该走下面"可编辑 / 缓存 / 读取失败"那套分支。
        if showingOriginal, !originalHTML.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Text("AI 改写前的原文（可直接修改）")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    // 原文本身是"历史版本"，改它不会自动生效——
                    // 必须给一个明确的落点，否则用户改了半天不知道去哪了。
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
                // 读不到正文时至少把本地已有的摘要显示出来，别留一片空白
                Text(note.plainSnippet)
                    .font(DS.Fonts.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !noteBlocks.isEmpty {
                // **网页就地编辑（方案 A）。**
                // 直接编辑 HTML：改一个字只有那个字变，`<h1>`/`<img fileid>` 等标签
                // 字节级原样保留——不像 NSTextView 方案那样整篇往返重写
                // （字体变 Times、`<br>` 变段落、颜色漂移）。
                // 图片：fileid 进编辑器换成内联图显示，导出按字节指纹换回 fileid，
                // 删图 = 输出里没有对应标签 = 写回时真的删除。
                editorToolbar

                WebNoteEditor(html: $noteHTML,
                              images: noteImages,
                              contentHeight: $noteBodyHeight,
                              command: $editorCommand)
                    // **高度必须用页面量出来的值。**
                    // 写成 `.frame(minHeight: 240)` 时，WKWebView 因为没有固有高度
                    // 就只占 240，剩下的正文被关进它自己的内部滚动区，
                    // 外层看到的是一块 240 高的盒子、下面一大片空白。
                    .frame(height: max(noteBodyHeight, 240))
            } else {
                Text(note.plainSnippet)
                    .font(DS.Fonts.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if noteBlocks.isEmpty {
            // 缓存里连旧版本都没有 → 这条笔记的正文一次都没拉下来过
            DSStatusBar(icon: "arrow.down.circle",
                        tint: DS.Status.warn,
                        title: "正文还没拉到本地",
                        detail: "点左栏的「拉取」把这条笔记的正文与图片下载下来，之后在这里离线也能看。")
            Text(note.plainSnippet)
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

    /// 正文编辑落盘：防抖 600ms，**只写本地缓存**。
    ///
    /// 不自动写备忘录，是因为用户可能只是改了几个字还没定稿；
    /// 而写备忘录走 AppleScript，会直接覆盖原版，失败了也不好恢复。
    /// 真正写回走显式入口（导入 / AI 写回）。
    private func scheduleBodySave(_ html: String, note: CachedNote) {
        bodySaveTask?.cancel()
        bodySaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            try? cache.saveContent(CachedNoteContent(html: html, images: noteImages), for: note.id)
        }
    }

    /// 把 AI 的一条回复写成这条笔记的正文。
    ///
    /// 模型给的是纯文本（可能带 Markdown 痕迹），不是 HTML：
    /// 按空行分段包成 `<p>`，段内换行转 `<br/>`，再交给 sanitizer
    /// 过一遍——它顺手清掉备忘录不认的标签与样式。
    private func applyAIResult(_ text: String, to note: CachedNote) {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>" + $0.replacingOccurrences(of: "\n", with: "<br/>") + "</p>" }

        guard !paragraphs.isEmpty else { return }
        let html = NotesHTMLSanitizer.sanitize(paragraphs.joined())
        // 撤销要回到"这次写入之前"的版本，所以先把当前正文记下来
        let previous = noteHTML

        Task {
            do {
                try await noteAI.applyResult(
                    NoteAIResult(html: html, summary: "由对话写入"),
                    toNoteId: note.id
                )
                // 写回后重读缓存：界面显示的必须是备忘录里真正那份
                loadBody(note)
                chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)

                showToast("已写入这条笔记") { [previous] in
                    // 撤销 = 把刚才那版原样写回去。
                    // 这里**不用**原文备份（`originalContent`）：那是"AI 第一次改写前"的版本，
                    // 而用户此刻想撤销的是**这一次**的写入。
                    Task {
                        try? await noteAI.applyResult(
                            NoteAIResult(html: previous, summary: "撤销写入"),
                            toNoteId: note.id
                        )
                        loadBody(note)
                        chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)
                    }
                }
            } catch {
                print("[MainView] 写入笔记失败：\(error.localizedDescription)")
                showToast("写入失败：\(error.localizedDescription)")
            }
        }
    }

    /// 正文编辑工具栏。
    ///
    /// 放在正文正上方而不是窗口工具栏：它只作用于正文，
    /// 挂到窗口级会让人以为能改 AI 消息或列表。
    private var editorToolbar: some View {
        HStack(spacing: DS.Optical.snug) {
            toolButton("bold", "加粗") { editorCommand = .bold }
            toolButton("italic", "斜体") { editorCommand = .italic }
            toolButton("underline", "下划线") { editorCommand = .underline }

            Divider().frame(height: 14)

            toolButton("textformat.size.larger", "标题 1") { editorCommand = .heading1 }
            toolButton("textformat.size", "标题 2") { editorCommand = .heading2 }
            toolButton("textformat", "正文") { editorCommand = .paragraph }

            Divider().frame(height: 14)

            toolButton("list.bullet", "无序列表") { editorCommand = .bulletList }
            toolButton("list.number", "有序列表") { editorCommand = .orderedList }

            Divider().frame(height: 14)

            toolButton("photo.badge.plus", "插入图片") { editorCommand = .insertImage }
            toolButton("arrow.triangle.2.circlepath", "替换选中的图片") { editorCommand = .replaceImage }
            toolButton("trash", "删除选中的图片") { editorCommand = .deleteImage }

            Spacer(minLength: 0)

            toolButton("arrow.uturn.backward", "撤销") { editorCommand = .undo }
            toolButton("arrow.uturn.forward", "重做") { editorCommand = .redo }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Optical.compact)
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
                .font(.system(size: 11))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
        VStack(alignment: .leading, spacing: 0) {
            // **不再显示「已被 AI 重构」提示条。**
            // AI 改完之后，这条笔记对用户来说就是一条普通笔记；
            // 反复提醒"它被机器动过"只会让人怀疑内容是否可信。
            // `aiModified` 这个**数据**仍然保留——它是同步时"不覆盖用户成果"的依据，
            // 只是不该出现在界面上。

            // 高度由外层固定，这里只负责撑满剩余空间。
            // 对话区自己内部滚动，不会把整个详情栏撑高。
            AIChatView(session: chat) { text in
                applyAIResult(text, to: note)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Palette.surface)
    }

    /// AI 区与笔记之间的可拖动分隔条。
    ///
    /// 拖动改变的是**用户自己的偏好高度**，一旦动过就不再走自动公式——
    /// 否则发一条消息公式一涨，刚调好的位置又被推走，等于白拖。
    /// 想回到自动，双击分隔条即可（清掉 override）。
    private var aiResizeHandle: some View {
        ZStack {
            // 可见的只是一条 3pt 细线，但命中区域放到 9pt：
            // 3pt 的线用鼠标很难抓准，拖半天拖不动会让人以为功能坏了。
            Color.clear
            Capsule()
                .fill(DS.Palette.stroke)
                .frame(width: 40, height: 3)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = aiPanelHeight }
                    let start = dragStartHeight ?? aiPanelHeight
                    // 向上拖 translation 为负 → AI 区变高
                    aiHeightOverride = max(120, start - value.translation.height)
                }
                .onEnded { _ in dragStartHeight = nil }
        )
        .onTapGesture(count: 2) {
            // 双击恢复自动高度：用户调乱之后需要一个不费脑的回头路
            aiHeightOverride = nil
        }
    }

    /// 底部居中的临时提示气泡。
    ///
    /// 用气泡而不是 alert：这类反馈（写入了、撤销了）不需要用户确认，
    /// 弹窗反而要额外点一下才能继续干活。4 秒自动消失，带撤销时留够操作时间。
    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Status.ok)

                Text(toast.text)
                    .font(DS.Fonts.label)

                if let undo = toast.undo {
                    Button("撤销") {
                        undo()
                        withAnimation { self.toast = nil }
                    }
                    .buttonStyle(.link)
                    .font(DS.Fonts.label)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Palette.stroke, lineWidth: 1))
            .padding(.bottom, DS.Space.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(true)
        }
    }

    /// 把「原文」写回当前正文（覆盖 AI 改写的版本）。
    ///
    /// 走的是和 AI 写回同一条链路：sanitizer → setBody → 缓存。
    /// 不另开一条写回路径：格式规范、失败处理、缓存同步必须只有一套行为，
    /// 否则两边迟早会在某条边界上打架。
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
                showingOriginal = false
                loadBody(note)
                chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)

                showToast("已用原文替换当前正文") { [previous] in
                    Task {
                        try? await noteAI.applyResult(
                            NoteAIResult(html: previous, summary: "撤销恢复"),
                            toNoteId: note.id
                        )
                        loadBody(note)
                        chat.noteContext = AIChatSession.NoteContext(title: note.title, html: noteHTML)
                    }
                }
            } catch {
                showToast("恢复失败：\(error.localizedDescription)")
            }
        }
    }

    /// 显示提示气泡。`undo` 为 nil 时只是一个确认。
    private func showToast(_ text: String, undo: (() -> Void)? = nil) {
        let state = ToastState(text: text, undo: undo)
        withAnimation(.easeOut(duration: 0.18)) { toast = state }

        // 只让"最新那条"负责关闭：否则连续两次操作时，
        // 第一条的定时器会把第二条刚弹出来的气泡提前收掉。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if toast?.id == state.id {
                withAnimation(.easeIn(duration: 0.15)) { toast = nil }
            }
        }
    }

    // MARK: - 拖拽

    /// AI 区的高度：跟着内容走，不再固定占一块。
    ///
    /// 空的时候只留一行输入框（56 点），用户看到的就是一条输入栏，不压正文；
    /// 有消息后按条数长高，但封顶 240 —— 再高就该用户自己拉窗口，而不是我们替他决定。
    /// 拖拽悬停时临时多给 40，让「这里可以投放」除了变色还有尺寸上的反馈。
    private var aiPanelHeight: CGFloat {
        // 用户拖过就听用户的。只做一次下限保护：再小也要放得下输入框。
        if let override = aiHeightOverride {
            return max(120, override)
        }

        // 68 是下限：输入区自带 padding 与按钮高度，给 56 会装不下、内容被裁，
        // 看起来就是"错位"。这个数是从 composer 的实际高度量出来的，不要再往下调。
        var height: CGFloat = 68
        // 附件缩略图那一排（44 点 + 上边距）：不加就把预览条裁掉了
        if !chat.pending.isEmpty { height += 60 }
        if !chat.messages.isEmpty {
            // 每条按 46 点估，但**上限要够用**：原来封顶 184 只放得下 4 条，
            // 对话稍长就只剩一小条可视区，看起来像"下面被挡住"。
            // 现在给到 340，等于 7 条左右的余量；再多就靠区里自己滚。
            height += min(CGFloat(chat.messages.count) * 46, 340)
        }
        if hoveredZone == .ai { height += 40 }
        return height
    }

    /// 拖拽提示的两层渐变。
    ///
    /// **第一层**：一旦开始拖拽（指针进入任一区域），两个区域同时亮起浅色——
    /// 意思是"这里和那里都能放"。**没有拖拽时一点都不画**，界面保持干净。
    /// **第二层**：指针停在哪，哪个区域加深并显示文字。
    ///
    /// 用「任一区域 targeted」代表"正在拖拽"，是因为拖进窗口必然落在两个区域之一；
    /// 窗口外的情况本来也不需要提示。
    @ViewBuilder
    private func dropOverlay(for zone: DropZone) -> some View {
        if let hovered = hoveredZone {
            let active = (hovered == zone)
            ZStack {
                LinearGradient(
                    colors: [DS.Palette.accent.opacity(active ? 0.22 : 0.06),
                             DS.Palette.accent.opacity(active ? 0.02 : 0.0)],
                    startPoint: .top,
                    endPoint: .bottom)

                if active {
                    Text(zone == .note ? "松手，添加到笔记素材" : "松手，交给 AI 分析")
                        .font(DS.Fonts.rowTitle)
                        .foregroundStyle(DS.Palette.accent)
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, DS.Space.s)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// 处理拖入的文件。
    ///
    /// 两个区域最终都汇入 `chat.attach`——区别在提示语和用户心智：
    /// 拖到笔记区是「这条笔记的素材」，拖到对话区是「让 AI 处理这份东西」。
    /// 但素材同样要进对话才能真正被 AI 用起来；如果分成两套队列，
    /// 用户反而不知道自己刚拖的文件去了哪。
    private func handleDrop(_ urls: [URL], into zone: DropZone) -> Bool {
        hoveredZone = nil
        let items = urls.compactMap { AttachmentReader.make(from: $0) }
        guard !items.isEmpty else { return false }
        chat.attach(items)
        return true
    }

    /// 拖拽悬停时的渐变提示（已并入 `dropOverlay`）。

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
            clearAppliedSelection()
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
    /// 导入成功之后该清哪批，由 `clearAppliedSelection` 专门负责。
    private func afterCacheChanged() {
        let valid = Set(pull.notes.filter(canSelectForImport).map(\.id))
        importSelection.formIntersection(valid)

        if let id = selectedNoteID, !pull.notes.contains(where: { $0.id == id }) {
            selectedNoteID = nil
        }
    }

    /// 一次导入跑完之后收尾：**只清这次真正写成功的那些勾选**，失败的、跳过的、拦下的
    /// 全都留在勾选里，方便用户回头直接再处理。
    ///
    /// 判据用引擎的 `lastAppliedNoteIds`，不猜 `imported` 标记——
    /// 覆盖的笔记本来就是 `imported == true`，失败了也还是 true，从标记上区分不出来。
    private func clearAppliedSelection() {
        importSelection.subtract(importer.lastAppliedNoteIds)
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
                Text(note.plainSnippet)
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
            // **不要在这里拉起「备忘录」。**（主界面 / 设置页 / 权限清单页三处同理）
            //
            // `ensureNotesRunning()` 会在这些页面一出现时就把备忘录启动起来，
            // 而备忘录启动后自己会 activate，把键盘焦点从本应用抢走——
            // 用户看到的就是「一开软件就跳出记事本、输入框打不进字」。
            // 这三处只需要读本地缓存、查询权限状态，都不需要备忘录在运行；
            // 真正需要它的是「导入」和「核验导入结果」，到那一步再由 `ImportEngine`
            // 自己确保运行。
            //
            // 另外 `automationStatus` 现在会先查进程表：未运行且用户没点「授权」时
            // 直接返回 `.targetNotRunning`，**不会发出任何 Apple Event**，
            // 因此也不会把备忘录唤起来。
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
            // **不要在这里拉起「备忘录」。**（主界面 / 设置页 / 权限清单页三处同理）
            //
            // `ensureNotesRunning()` 会在这些页面一出现时就把备忘录启动起来，
            // 而备忘录启动后自己会 activate，把键盘焦点从本应用抢走——
            // 用户看到的就是「一开软件就跳出记事本、输入框打不进字」。
            // 这三处只需要读本地缓存、查询权限状态，都不需要备忘录在运行；
            // 真正需要它的是「导入」和「核验导入结果」，到那一步再由 `ImportEngine`
            // 自己确保运行。
            //
            // 另外 `automationStatus` 现在会先查进程表：未运行且用户没点「授权」时
            // 直接返回 `.targetNotRunning`，**不会发出任何 Apple Event**，
            // 因此也不会把备忘录唤起来。
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
                    // 标签必须如实：preview 装的是**小米侧将要写入的新版本**，
                    // 不是「备忘录」里那条现在的样子（plan 是同步的，读不到旧正文）。
                    // 标成「将被替换掉的正文」会让用户把判断依据看反。
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
