import Foundation
import SwiftUI

// 「内置 AI」这条链路的第一段：**可配置的 OpenAI 兼容客户端 + 配置存储 + 设置界面**。
//
// 设计原则（来自契约）：**不预设厂商。** baseURL / apiKey / 模型名全部由用户填写。
// 所以这里没有 `case .deepseek` 这类分支，也不给任何一家写默认地址——
// DeepSeek、OpenAI、Moonshot、本地 Ollama / LM Studio 走的是同一条代码路径，
// 差别只体现在用户填的那几个字符串上。
//
// 依赖：只依赖 `AIContract.swift`（共享契约）、`CredentialsStore`（存放位置与权限约定）、
// `DS`（设计系统）。不 import 任何第三方。

// MARK: - 配置存储

/// AI 配置的落盘位置与权限。
///
/// 和登录凭证（`CredentialsStore`）同一套规矩：Application Support 下的 MiNoteBridge 目录，
/// 目录 0700、文件 **0600**、原子写。区别只是文件名不同。
///
/// 之所以单独一个文件而不是塞进 `credentials.json`：两者生命周期不同——
/// 退出登录会清凭证，但不该顺手把用户填的模型配置也删掉。
///
/// ⚠️ `apiKey` 只存在于这个文件里。它**不进 UserDefaults、不进日志、不进错误信息**。
enum AIConfigStore {

    static let fileName = "ai-config.json"

    /// 与凭证同目录（`CredentialsStore` 已经定义了「MiNoteBridge 放哪、权限怎么给」）
    static var directory: URL { CredentialsStore.directory }

    static var fileURL: URL { directory.appendingPathComponent(fileName, isDirectory: false) }

    /// 读配置。文件不存在、读不动、解析失败都返回 nil——
    /// 这几种情况对调用方是同一件事：「还没配好」。
    static func load() -> AIConfig? {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data)
        else { return nil }
        return config
    }

    /// 写配置。原子写 + 立刻收紧到 0600。
    static func save(_ config: AIConfig) throws {
        _ = CredentialsStore.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: [.atomic])
        // 与 CredentialsStore.saveCookie 一致：写完立刻收紧权限，不依赖 umask。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    /// 删掉配置文件（「清除配置」走这里）。清掉之后 `load()` 返回 nil，语义闭环。
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 当前文件权限的三位八进制表示（例如 `600`），供设置界面如实展示；文件不存在时为 nil。
    static func filePermission() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mode = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return String(format: "%03o", mode.intValue)
    }
}

// MARK: - 客户端

/// OpenAI 兼容客户端。**同一个类接所有家。**
///
/// 只有 `shared` 这个共享实例需要留意：UI 与「笔记 AI」读的是同一份配置，
/// 否则设置界面改了地址、发请求的却是另一份旧值，那是很难查的 bug。
final class AIProvider: ObservableObject, AIProviderProtocol {

    static let shared = AIProvider()

    /// 请求超时。60 秒：本机模型冷启动也够，云端慢到 60 秒以上就该报错而不是干等。
    static let requestTimeout: TimeInterval = 60

    @Published private(set) var config: AIConfig

    /// 最近一次写盘失败的原因。**只含系统给的错误描述，不含 API Key。**
    /// 设置界面据此显示「未保存」，而不是假装保存成功了。
    @Published private(set) var lastSaveError: String?

    private let session: URLSession

    /// - Parameters:
    ///   - config: 显式传入时不读盘（设置界面的「测试连接」用它试一份还没保存的草稿）。
    ///             传 nil 则读盘。
    ///   - session: 仅测试用。
    init(config: AIConfig? = nil, session: URLSession? = nil) {
        self.config = config ?? AIConfigStore.load() ?? .empty
        if let session {
            self.session = session
        } else {
            // ephemeral：不落磁盘缓存。请求里带 API Key，不该在本地留下副本。
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = AIProvider.requestTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 更新配置并写盘。
    ///
    /// 空配置（`AIConfig.empty`）等同于「没有配置」，所以走删除而不是写一个空文件——
    /// 「清除配置」因此可以只是 `update(.empty)`，不需要第二套 API。
    func update(_ config: AIConfig) {
        self.config = config
        do {
            if config == .empty {
                AIConfigStore.clear()
            } else {
                try AIConfigStore.save(config)
            }
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    // MARK: 请求地址归一化

    /// 把用户填的 baseURL 拼成**真正要请求的** `/chat/completions` 地址。
    ///
    /// 用户会填出各种形态：带不带尾斜杠、带不带 `/v1`、甚至直接把完整接口地址抄进来。
    /// 与其要求用户填对，不如统一在这里归一化，并在设置界面把结果**显示出来**让他核对。
    ///
    /// 规则（自上而下第一条命中即返回）：
    /// 1. 空 → `badURL`。
    /// 2. 没有 `://` 时补协议：本机（`localhost` / `127.0.0.1` / `0.0.0.0` / `::1`）补 `http://`，
    ///    其余补 `https://`。
    /// 3. 路径去尾斜杠。
    /// 4. 路径已经以 `/chat/completions` 结尾 → 原样用（用户填的是完整接口，别重复追加）。
    /// 5. 路径最后一段是 `v<数字>`（`/v1`、`/openai/v2`）→ 追加 `/chat/completions`。
    /// 6. 其余（只有主机名，或 `/openai` 这种没有版本段的前缀）→ 追加 `/v1/chat/completions`。
    static func endpointURL(for baseURL: String) throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw AIError.badURL(baseURL) }

        let withScheme: String
        if raw.contains("://") {
            withScheme = raw
        } else {
            let host = raw.split(separator: "/").first.map(String.init) ?? raw
            let isLocal = host.hasPrefix("localhost")
                || host.hasPrefix("127.0.0.1")
                || host.hasPrefix("0.0.0.0")
                || host.hasPrefix("[::1]")
            withScheme = (isLocal ? "http://" : "https://") + raw
        }

        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.host, !host.isEmpty
        else { throw AIError.badURL(baseURL) }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }

        let lowercasedPath = path.lowercased()
        if !lowercasedPath.hasSuffix("/chat/completions") {
            let lastSegment = lowercasedPath.split(separator: "/").last.map(String.init) ?? ""
            let isVersionSegment = lastSegment.range(of: "^v[0-9]+$", options: .regularExpression) != nil
            path += isVersionSegment ? "/chat/completions" : "/v1/chat/completions"
        }

        var resolved = components
        resolved.percentEncodedPath = path
        resolved.query = nil
        resolved.fragment = nil
        guard let url = resolved.url else { throw AIError.badURL(baseURL) }
        return url
    }

    // MARK: 发请求

    /// 发一轮对话。纯文本走 `config.model`，带图的消息走 `config.effectiveVisionModel`。
    func complete(_ messages: [AIMessage]) async throws -> AICompletion {
        let config = self.config
        guard config.isUsable else { throw AIError.notConfigured }

        let url = try AIProvider.endpointURL(for: config.baseURL)

        let carriesImages = messages.contains { message in
            if case .userWithImages(_, let images) = message { return !images.isEmpty }
            return false
        }
        let model = (carriesImages ? config.effectiveVisionModel : config.model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AIProvider.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model, messages: messages.map(WireMessage.init))
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIError.network("服务返回的不是 HTTP 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 错误体可能很大（有些网关会把整页 HTML 吐回来），截断后再放进错误里。
            throw AIError.http(http.statusCode, AIProvider.preview(of: data))
        }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw AIError.network("无法解析服务响应：\(AIProvider.preview(of: data))")
        }

        let text = (decoded.choices?.first?.message?.content?.plainText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.emptyResponse }

        return AICompletion(text: text, model: decoded.model ?? model)
    }

    /// 连通性测试：发一句最短的话，返回一句给人看的结果（含模型名与耗时）。
    ///
    /// 走的是同一条 `complete` 路径——测通了就能真的用，不存在「测试用一条特殊通道」。
    func testConnection() async throws -> String {
        let started = Date()
        let completion = try await complete([.user("你好")])
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return "\(completion.model) 响应正常，耗时 \(milliseconds) ms。"
    }

    /// 响应体的可读预览：压平换行 + 截断。错误信息里绝不能带上请求头（含 API Key）。
    private static func preview(of data: Data, limit: Int = 300) -> String {
        guard let raw = String(data: data, encoding: .utf8) else {
            return "（响应体不是 UTF-8 文本，\(data.count) 字节）"
        }
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "（响应体为空）" }
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }
}

// MARK: - 线上格式

// OpenAI 的 wire 格式。单独拆出来是因为 `content` 有**两种形态**：
// 纯文本时是字符串，带图时是块数组。用 `Encodable` 的自定义编码避开 `[String: Any]`。

private struct ChatRequest: Encodable {
    var model: String
    var messages: [WireMessage]
}

private struct WireMessage: Encodable {
    var role: String
    var content: WireContent

    init(_ message: AIMessage) {
        switch message {
        case .system(let text):
            role = "system"
            content = .plain(text)
        case .user(let text):
            role = "user"
            content = .plain(text)
        case .userWithImages(let text, let images):
            role = "user"
            // 没有图时退回纯文本：别发一个只有文字块的块数组，有些服务端不认。
            content = images.isEmpty
                ? .plain(text)
                : .blocks(WireContent.blocks(text: text, images: images))
        }
    }
}

private enum WireContent: Encodable {
    case plain(String)
    case blocks([Block])

    struct Block: Encodable {
        var type: String
        var text: String?
        var image_url: ImageURL?

        struct ImageURL: Encodable { var url: String }

        static func text(_ value: String) -> Block {
            Block(type: "text", text: value, image_url: nil)
        }

        static func image(_ data: Data, mimeType: String) -> Block {
            let url = "data:\(mimeType);base64,\(data.base64EncodedString())"
            return Block(type: "image_url", text: nil, image_url: ImageURL(url: url))
        }
    }

    static func blocks(text: String, images: [AIImage]) -> [Block] {
        var blocks = [Block.text(text)]
        blocks.append(contentsOf: images.map { Block.image($0.data, mimeType: $0.mimeType) })
        return blocks
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let text): try container.encode(text)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }
}

// MARK: 响应

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: FlexibleContent?
        }
        var message: Message?
    }
    var choices: [Choice]?
    var model: String?
}

/// 响应的 `content` 同样可能是字符串或块数组（有些服务端带图时回块数组）。
/// 两种都收下，统一取纯文本部分。
private enum FlexibleContent: Decodable {
    case plain(String)
    case blocks([TextBlock])

    struct TextBlock: Decodable {
        var type: String?
        var text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .plain(text)
        } else if let blocks = try? container.decode([TextBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .plain("")
        }
    }

    var plainText: String {
        switch self {
        case .plain(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { $0.text }.joined()
        }
    }
}

// MARK: - 设置界面

/// AI 设置弹窗。无参构造（`AISettingsSheet()`）即可，由 `SettingsSheet` 引用。
///
/// 这个界面存在的意义只有一条：**让用户能自己核对发出去的到底是什么。**
/// 所以除了几个输入框，必须显示出归一化之后的最终请求地址——配置错了，一眼就能看出来。
struct AISettingsSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// 默认用共享实例；显式传入时便于测试。
    @ObservedObject private var provider: AIProvider

    @State private var draft: AIConfig
    @State private var test: TestState = .idle
    @State private var confirmingClear = false
    @State private var pendingSave: Task<Void, Never>?

    init(provider: AIProvider = .shared) {
        self.provider = provider
        _draft = State(initialValue: provider.config)
    }

    private enum TestState {
        case idle
        case running
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI 服务").font(DS.Fonts.screenTitle)
                Spacer()
                Button("完成") {
                    // 收尾：把最后一次改动落盘，别让用户输完立刻关窗就丢了。
                    pendingSave?.cancel()
                    provider.update(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    statusBar
                    enableCard
                    serviceCard
                    modelCard
                    testCard
                }
                .padding(DS.Space.xl)
            }

            Divider()

            DSFooter(note: "配置保存在 \(AIConfigStore.fileURL.path)，文件权限 0600。") {
                Button("清除配置", role: .destructive) { confirmingClear = true }
                    .controlSize(.small)
                    .disabled(draft == .empty)
            }
        }
        .frame(width: DS.windowSize.width, height: DS.windowSize.height)
        .confirmationDialog("清除 AI 配置？", isPresented: $confirmingClear) {
            Button("清除", role: .destructive) {
                draft = .empty   // 触发下面的 onChange → update(.empty) → 删掉配置文件
                test = .idle
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机保存的服务地址、API Key 与模型名。")
        }
        .onChange(of: draft) { _, newValue in
            // 不在每次按键就写盘，停手之后再落盘；同时「未保存」这个状态才是真的。
            // 关窗不取消它：弹窗关了，最后那次改动照样要落地。
            pendingSave?.cancel()
            pendingSave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: AISettingsSheet.saveDelayNanoseconds)
                guard !Task.isCancelled else { return }
                provider.update(newValue)
            }
        }
    }

    private static let saveDelayNanoseconds: UInt64 = 400_000_000

    // MARK: 状态条

    @ViewBuilder
    private var statusBar: some View {
        if let error = provider.lastSaveError {
            DSStatusBar(icon: "exclamationmark.triangle.fill", tint: DS.Status.bad,
                        title: "配置写入失败", detail: error)
        } else if draft == .empty {
            DSStatusBar(icon: "circle.dashed", tint: DS.Status.idle,
                        title: "尚未配置 AI 服务",
                        detail: "填入服务地址、API Key 与模型名即可开始使用。")
        } else if isDirty {
            DSStatusBar(icon: "pencil.circle.fill", tint: DS.Status.warn,
                        title: "有未保存的更改",
                        detail: "停止输入后会自动写入本地配置文件。")
        } else if draft.enabled && !draft.isUsable {
            DSStatusBar(icon: "exclamationmark.triangle.fill", tint: DS.Status.warn,
                        title: "已启用，但配置不完整",
                        detail: "服务地址、API Key、文本模型三项都填好才能真正发请求。")
        } else if draft.enabled {
            DSStatusBar(icon: "checkmark.circle.fill", tint: DS.Status.ok,
                        title: "已启用并保存", detail: savedDetail)
        } else {
            DSStatusBar(icon: "pause.circle.fill", tint: DS.Status.idle,
                        title: "已保存，但 AI 功能处于关闭状态", detail: savedDetail)
        }
    }

    private var savedDetail: String {
        guard let permission = AIConfigStore.filePermission() else { return "尚未写入磁盘。" }
        return "本地文件权限 \(permission)。"
    }

    private var isDirty: Bool { draft != provider.config }

    // MARK: 卡片

    private var enableCard: some View {
        DSCard(title: "启用", icon: "switch.2") {
            Toggle("启用 AI 功能", isOn: $draft.enabled)
                .toggleStyle(.switch)
                .font(DS.Fonts.label)
            Text("关闭后完全不联网，也不显示 AI 相关入口。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var serviceCard: some View {
        DSCard(title: "服务", icon: "network") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                labeledField("服务地址") {
                    TextField("https://api.deepseek.com 或 http://localhost:11434/v1",
                              text: $draft.baseURL)
                }
                labeledField("API Key") {
                    SecureField("粘贴服务商给的密钥", text: $draft.apiKey)
                }
                endpointRow
            }
        }
    }

    /// 归一化后的完整请求地址。**这是这个界面最重要的信息**——
    /// 用户填的地址五花八门，出问题时第一件事就是看这里拼成了什么。
    private var endpointRow: some View {
        let endpoint = (try? AIProvider.endpointURL(for: draft.baseURL))?.absoluteString
        return VStack(alignment: .leading, spacing: DS.Optical.snug) {
            Text("最终请求地址").font(DS.Fonts.label).foregroundStyle(.secondary)
            Text(endpoint ?? "无法从当前地址拼出请求地址")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(endpoint == nil ? DS.Status.warn : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelCard: some View {
        DSCard(title: "模型", icon: "cpu") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                labeledField("文本模型") {
                    TextField("例如 deepseek-chat、gpt-4o-mini、qwen2.5:7b", text: $draft.model)
                }
                labeledField("视觉模型") {
                    TextField("留空则用文本模型", text: $draft.visionModel)
                }
                DSInfoRow(label: "看图时使用",
                          value: draft.effectiveVisionModel.isEmpty ? "未填写" : draft.effectiveVisionModel,
                          mono: true)
            }
        }
    }

    private var testCard: some View {
        DSCard(title: "连接测试", icon: "bolt.horizontal") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                testStatus
                HStack(spacing: DS.Space.s) {
                    Button("测试连接") { runTest() }
                        .controlSize(.small)
                        .disabled(!canTest || isTesting)
                    Text(canTest
                         ? "会真的发一句话给服务商，但不会改动任何笔记。"
                         : "填好服务地址、API Key 与文本模型后可测试。")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch test {
        case .idle:
            DSStatusBar(icon: "circle.dashed", tint: DS.Status.idle,
                        title: "尚未测试", detail: "测试通过不代表配置永久有效，服务商侧仍可能变动。")
        case .running:
            DSStatusBar(icon: "bolt.horizontal", tint: DS.Palette.accent,
                        title: "测试中…", busy: true)
        case .ok(let detail):
            DSStatusBar(icon: "checkmark.circle.fill", tint: DS.Status.ok,
                        title: "连接正常", detail: detail)
        case .failed(let detail):
            DSStatusBar(icon: "xmark.circle.fill", tint: DS.Status.bad,
                        title: "连接失败", detail: detail)
        }
    }

    private func labeledField<Content: View>(_ label: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Optical.snug) {
            Text(label).font(DS.Fonts.label).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: 动作

    /// 三项齐了就可以测——不要求「启用」开关先打开，否则用户得先开开关才能验证配置对不对。
    private var canTest: Bool {
        !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isTesting: Bool {
        if case .running = test { return true }
        return false
    }

    private func runTest() {
        guard canTest else { return }
        // 用草稿测：用户还没保存也应该能先验证。enabled 在这里强制为真，绕开「未启用」的短路。
        var probeConfig = draft
        probeConfig.enabled = true
        let probe = AIProvider(config: probeConfig)

        test = .running
        Task { @MainActor in
            do {
                test = .ok(try await probe.testConnection())
            } catch {
                test = .failed(AISettingsSheet.describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let aiError = error as? AIError, let text = aiError.errorDescription { return text }
        return error.localizedDescription
    }
}
