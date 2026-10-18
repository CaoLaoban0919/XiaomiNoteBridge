import SwiftUI

@MainActor
final class AIModelCatalog: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case loaded([String])

        case failed(message: String, allowsManualEntry: Bool)
    }

    @Published private(set) var state: State = .idle

    private var task: Task<Void, Never>?

    var models: [String] {
        if case .loaded(let list) = state { return list }
        return []
    }

    func load(baseURL: String, apiKey: String) {
        let base = baseURL.trimmed
        let key = apiKey.trimmed
        guard !base.isEmpty, !key.isEmpty else {
            reset()
            return
        }

        task?.cancel()
        state = .loading

        var probe = AIConfig.empty
        probe.baseURL = base
        probe.apiKey = key
        probe.enabled = true
        let provider = AIProvider(config: probe)

        task = Task { [weak self] in
            do {
                let list = try await provider.fetchModels()
                guard !Task.isCancelled else { return }
                self?.state = .loaded(list)
            } catch {
                guard !Task.isCancelled else { return }
                let allowsManual = (error as? AIError)?.suggestsManualEntry ?? false
                self?.state = .failed(message: aiMessage(for: error),
                                      allowsManualEntry: allowsManual)
            }
        }
    }

    func reset() {
        task?.cancel()
        state = .idle
    }
}

struct AISettingsSheet: View {

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var provider: AIProvider
    @StateObject private var catalog = AIModelCatalog()

    @State private var draft: AIConfig
    @State private var test: TestState = .idle
    @State private var confirmingClear = false
    @State private var pendingSave: Task<Void, Never>?

    @State private var alertItem: AlertItem?

    @State private var showsPicker = false

    @State private var manualEntry = false

    @State private var slot: ModelSlot = .text
    @State private var query = ""

    init(provider: AIProvider = .shared) {
        self.provider = provider
        _draft = State(initialValue: provider.config)
    }

    private enum ModelSlot: Hashable {
        case text
        case vision
    }

    private enum TestState {
        case idle
        case running
        case ok(String)
    }

    private struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var allowsManualEntry = false
    }

    private static let saveDelayNanoseconds: UInt64 = 400_000_000
    private static let pickerAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)
    private static let pickerAnchor = "ai.picker"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        statusLine
                        connectionCard

                        if showsPicker {
                            pickerPanel
                                .id(Self.pickerAnchor)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                ))
                        }
                    }
                    .padding(DS.Space.xl)
                }
                .onChange(of: showsPicker) { _, isOpen in
                    guard isOpen else { return }

                    withAnimation(AISettingsSheet.pickerAnimation) {
                        proxy.scrollTo(Self.pickerAnchor, anchor: .bottom)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: DS.aiSettingsWindowSize.width,
               height: DS.aiSettingsWindowSize.height)
        .confirmationDialog("清除 AI 配置？", isPresented: $confirmingClear) {
            Button("清除", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机保存的服务地址、API Key 与模型名。")
        }
        .alert(alertItem?.title ?? "",
               isPresented: alertPresented,
               presenting: alertItem) { item in
            if item.allowsManualEntry {
                Button("手动填写") { openManualEntry() }
                Button("取消", role: .cancel) {}
            } else {
                Button("知道了", role: .cancel) {}
            }
        } message: { item in
            Text(item.message)
        }
        .onChange(of: draft) { _, newValue in

            pendingSave?.cancel()
            pendingSave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: AISettingsSheet.saveDelayNanoseconds)
                guard !Task.isCancelled else { return }
                provider.update(newValue)
            }
        }
        .onChange(of: catalog.state) { _, newState in

            guard case .failed(let message, let allowsManual) = newState else { return }
            withAnimation(AISettingsSheet.pickerAnimation) { showsPicker = false }
            alertItem = AlertItem(title: "检索失败", message: message,
                                  allowsManualEntry: allowsManual)
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertItem != nil },
            set: { if !$0 { alertItem = nil } }
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Optical.snug) {
                Text("AI 服务").font(DS.Fonts.screenTitle)
                Text("填好地址与密钥，点「检索模型」从列表里直接选。")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .dsPrimaryButton()
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.l)
    }

    private var statusLine: some View {
        HStack(spacing: DS.Space.s) {
            Circle()
                .fill(statusTint)
                .frame(width: 7, height: 7)
            Text(statusTitle).font(DS.Fonts.rowTitle)
            Text(statusDetail)
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)

                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var statusTint: Color {
        if provider.lastSaveError != nil { return DS.Status.bad }
        if draft == .empty { return DS.Status.idle }
        if isDirty { return DS.Status.warn }
        if draft.enabled && !draft.isUsable { return DS.Status.warn }
        return draft.enabled ? DS.Status.ok : DS.Status.idle
    }

    private var statusTitle: String {
        if provider.lastSaveError != nil { return "配置写入失败" }
        if draft == .empty { return "尚未配置" }
        if isDirty { return "有未保存的更改" }
        if draft.enabled && !draft.isUsable { return "已启用，但配置不完整" }
        return draft.enabled ? "已启用" : "已保存，AI 处于关闭状态"
    }

    private var statusDetail: String {
        if let error = provider.lastSaveError { return error }
        if draft == .empty { return "填地址与密钥即可开始" }
        if isDirty { return "停手后自动保存" }
        guard let permission = AIConfigStore.filePermission() else { return "尚未写入磁盘" }
        return "本地文件权限 \(permission)"
    }

    private var isDirty: Bool { draft != provider.config }

    private var connectionCard: some View {
        DSCard(title: "连接", icon: "network") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                labeledField("服务地址") {
                    TextField("https://api.deepseek.com", text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                }

                labeledField("API Key") {
                    HStack(spacing: DS.Space.s) {
                        SecureField("粘贴服务商给的密钥", text: $draft.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button(isTesting ? "测试中…" : "测试连接") { runTest() }
                            .controlSize(.small)
                            .disabled(isTesting)
                    }
                }

                endpointRows

                testResult

                Divider()

                selectionSummary

                actionRow
            }
        }
    }

    private var endpointRows: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            monoLine(label: "聊天地址",
                     value: (try? AIProvider.endpointURL(for: draft.baseURL, resource: .chatCompletions))?.absoluteString)
            monoLine(label: "模型列表",
                     value: (try? AIProvider.endpointURL(for: draft.baseURL, resource: .models))?.absoluteString)
        }
    }

    private func monoLine(label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(label)
                .font(DS.Fonts.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Text(value ?? "无法从当前地址拼出")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(value == nil ? DS.Status.warn : .secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSInfoRow(label: "文本模型",
                      value: draft.model.isEmpty ? "未选择" : draft.model,
                      valueColor: draft.model.isEmpty ? .secondary : .primary,
                      mono: true)
            DSInfoRow(label: "视觉模型", value: visionSummary, mono: true)
        }
    }

    private var visionSummary: String {
        if !draft.visionModel.isEmpty { return draft.visionModel }
        if draft.model.isEmpty { return "未选择" }
        return "\(draft.model)（跟随文本）"
    }

    private var actionRow: some View {
        HStack(spacing: DS.Space.m) {
            Button {
                retrieveModels()
            } label: {
                Label("检索模型", systemImage: "magnifyingglass")
            }
            .dsPrimaryButton()
            .disabled(catalog.isLoading)

            Button("手动填写") { openManualEntry() }
                .buttonStyle(.plain)
                .font(DS.Fonts.label)
                .foregroundStyle(DS.Palette.accent)

            Spacer(minLength: 0)

            if catalog.isLoading {
                Text("检索中…")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.tertiary)
            } else if !catalog.models.isEmpty {
                Text("\(catalog.models.count) 个可用")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text("正在发一句「你好」…").font(DS.Fonts.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        case .ok(let detail):
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Status.ok)
                Text(detail).font(DS.Fonts.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var pickerPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Text(manualEntry ? "手动填写模型" : "选择模型")
                    .font(DS.Fonts.cardTitle)
                Spacer(minLength: 0)
                Button {
                    withAnimation(AISettingsSheet.pickerAnimation) { showsPicker = false }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("收起")
            }

            DSSegmented(selection: $slot, options: [
                (.text, "文本模型"),
                (.vision, "视觉模型")
            ])

            if manualEntry {
                TextField(manualPlaceholder, text: slotBinding)
                    .textFieldStyle(.roundedBorder)
                Text("手动填写的名字会原样发给服务端，不做校验。")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.tertiary)
            } else {
                searchField
                modelList
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsGlass(cornerRadius: DS.Radius.m, fallbackStroke: true)
    }

    private var searchField: some View {
        HStack(spacing: DS.Optical.compact) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("搜索模型", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Fonts.label)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Optical.compact)
        .background(DS.Palette.nest, in: RoundedRectangle(cornerRadius: DS.Radius.s))
    }

    private var visibleModels: [String] {
        let all = catalog.models
        let keyword = query.trimmed
        guard !keyword.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(keyword) }
    }

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {

                if slot == .vision {
                    row(title: draft.model.isEmpty ? "跟随文本模型（尚未选文本模型）" : "跟随文本模型",
                        detail: draft.model.isEmpty ? nil : draft.model,
                        selected: draft.visionModel.isEmpty,
                        monospaced: false) {
                        draft.visionModel = ""
                    }
                    Divider().padding(.leading, DS.Space.m)
                }

                ForEach(Array(visibleModels.enumerated()), id: \.element) { item in
                    if item.offset > 0 {
                        Divider().padding(.leading, DS.Space.m)
                    }
                    row(title: item.element,
                        detail: nil,
                        selected: isSelected(item.element),
                        monospaced: true) {
                        select(item.element)
                    }
                }

                if visibleModels.isEmpty {
                    Text(query.isEmpty ? "服务没有返回任何模型。" : "没有匹配「\(query)」的模型。")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.m)
                }
            }
        }
        .frame(height: 148)
        .background(DS.Palette.surfaceDeep, in: RoundedRectangle(cornerRadius: DS.Radius.s))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.s)
                .stroke(DS.Palette.stroke, lineWidth: 1)
        )
    }

    private func row(title: String,
                     detail: String?,
                     selected: Bool,
                     monospaced: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? DS.Palette.accent : Color.secondary.opacity(0.4))
                VStack(alignment: .leading, spacing: DS.Optical.snug) {
                    Text(title)
                        .font(monospaced ? .system(size: 12, design: .monospaced) : DS.Fonts.label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(DS.Fonts.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Optical.compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var manualPlaceholder: String {
        switch slot {
        case .text: return "例如 deepseek-flash"
        case .vision: return "留空则跟随文本模型"
        }
    }

    private var slotBinding: Binding<String> {
        switch slot {
        case .text: return $draft.model
        case .vision: return $draft.visionModel
        }
    }

    private func isSelected(_ id: String) -> Bool {
        switch slot {
        case .text: return draft.model == id
        case .vision: return draft.visionModel == id
        }
    }

    private func select(_ id: String) {
        switch slot {
        case .text: draft.model = id
        case .vision: draft.visionModel = id
        }
    }

    private var footer: some View {

        let shown = (AIConfigStore.fileURL.path as NSString).abbreviatingWithTildeInPath
        return DSFooter(note: "配置只保存在本机 \(shown)（权限 0600），不会上传。") {
            Button("清除配置", role: .destructive) { confirmingClear = true }
                .controlSize(.small)
                .disabled(draft == .empty)
        }
    }

    private func labeledField<Content: View>(_ label: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Optical.snug) {
            Text(label).font(DS.Fonts.label).foregroundStyle(.secondary)
            content()
        }
    }

    private var isTesting: Bool {
        if case .running = test { return true }
        return false
    }

    private var canTest: Bool {
        !draft.baseURL.trimmed.isEmpty
            && !draft.apiKey.trimmed.isEmpty
            && !draft.model.trimmed.isEmpty
    }

    private func retrieveModels() {
        let base = draft.baseURL.trimmed
        let key = draft.apiKey.trimmed

        guard !base.isEmpty else {
            alertItem = AlertItem(title: "无法检索",
                                  message: "还没有填写服务地址。例如 https://api.deepseek.com")
            return
        }
        guard !key.isEmpty else {
            alertItem = AlertItem(title: "无法检索",
                                  message: "还没有填写 API Key。模型列表接口需要鉴权，去服务商后台复制一个填进来。")
            return
        }
        guard (try? AIProvider.endpointURL(for: base, resource: .models)) != nil else {
            alertItem = AlertItem(title: "服务地址无法解析",
                                  message: "当前地址拼不出模型列表接口：\n\(base)\n\n检查一下是不是少了协议头，或者带了多余的路径。")
            return
        }

        manualEntry = false
        withAnimation(AISettingsSheet.pickerAnimation) { showsPicker = true }
        catalog.load(baseURL: base, apiKey: key)
    }

    private func openManualEntry() {
        manualEntry = true
        withAnimation(AISettingsSheet.pickerAnimation) { showsPicker = true }
    }

    private func runTest() {
        guard canTest else {
            alertItem = AlertItem(title: "无法测试",
                                  message: "测试连接要真的发一句话，需要先填好服务地址、API Key 和文本模型。")
            return
        }

        var probeConfig = draft
        probeConfig.enabled = true
        let probe = AIProvider(config: probeConfig)

        test = .running
        Task { @MainActor in
            do {
                test = .ok(try await probe.testConnection())
            } catch {
                test = .idle
                alertItem = AlertItem(title: "连接测试失败", message: aiMessage(for: error))
            }
        }
    }

    private func save() {
        pendingSave?.cancel()
        provider.update(draft)
        if let error = provider.lastSaveError {
            alertItem = AlertItem(title: "保存失败", message: error)
            return
        }
        catalog.reset()
        dismiss()
    }

    private func clearAll() {
        draft = .empty
        test = .idle
        query = ""
        manualEntry = false
        withAnimation(AISettingsSheet.pickerAnimation) { showsPicker = false }
        catalog.reset()
    }
}

private func aiMessage(for error: Error) -> String {
    if let aiError = error as? AIError, let text = aiError.errorDescription { return text }
    return error.localizedDescription
}

private extension AIModelCatalog {
    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
