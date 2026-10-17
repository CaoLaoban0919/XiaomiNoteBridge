import Foundation
import SwiftUI

// MARK: - 消息

/// 对话里的一条消息。
struct AIChatMessage: Identifiable, Equatable {

    enum Role: Equatable {
        case user
        case assistant
    }

    enum State: Equatable {
        /// 正常完成（用户消息恒为它）
        case done
        /// 正在等模型
        case sending
        /// 失败，附带可读原因
        case failed(String)
    }

    let id: UUID
    let role: Role
    var text: String
    var attachments: [ChatAttachment]
    var state: State
    let createdAt: Date

    init(id: UUID = UUID(),
         role: Role,
         text: String,
         attachments: [ChatAttachment] = [],
         state: State = .done,
         createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.state = state
        self.createdAt = createdAt
    }
}

// MARK: - 附件

/// 用户附给对话的一份资料。
///
/// 图片走 `rawData`（交给视觉模型），表格/文本先转成 `extractedText`
/// 再拼进消息正文——这样同一条链路上既能看截图又能做数据对比。
struct ChatAttachment: Identifiable, Equatable {

    enum Kind: Equatable {
        case image
        case spreadsheet
        case text
    }

    let id: UUID
    let kind: Kind
    let displayName: String
    /// 给模型看的文本：表格转成的制表符文本、文本文件原文。图片为空。
    var extractedText: String
    /// 原始字节，仅图片使用。
    var rawData: Data?
    var mimeType: String?

    init(id: UUID = UUID(),
         kind: Kind,
         displayName: String,
         extractedText: String = "",
         rawData: Data? = nil,
         mimeType: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.extractedText = extractedText
        self.rawData = rawData
        self.mimeType = mimeType
    }

    var kindLabel: String {
        switch kind {
        case .image: return "图片"
        case .spreadsheet: return "表格"
        case .text: return "文本"
        }
    }

    var symbolName: String {
        switch kind {
        case .image: return "photo"
        case .spreadsheet: return "tablecells"
        case .text: return "doc.text"
        }
    }

    /// 气泡/待发区上的一行摘要
    var summaryLine: String {
        switch kind {
        case .image:
            let kb = max(1, (rawData?.count ?? 0) / 1024)
            return "\(displayName) · \(kb) KB"
        case .spreadsheet, .text:
            let lines = extractedText.isEmpty
                ? 0
                : extractedText.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(displayName) · \(lines) 行"
        }
    }

    /// 拼进用户消息正文时的块
    var promptBlock: String {
        switch kind {
        case .image:
            return ""
        case .spreadsheet:
            return "【表格 \(displayName)】\n\(extractedText)"
        case .text:
            return "【资料 \(displayName)】\n\(extractedText)"
        }
    }
}

// MARK: - 会话

/// 一次对话的状态与请求编排。
///
/// 刻意做得很薄：只管「消息列表 + 发送 + 重试」，不碰界面、不碰笔记。
/// 界面（`AIChatView`）和附件读取（`AttachmentReader`）各自独立，靠这里的数据类型对接。
@MainActor
final class AIChatSession: ObservableObject {

    @Published var messages: [AIChatMessage] = []
    @Published var draft: String = ""
    /// 已选中、还没发出去的附件
    @Published var pending: [ChatAttachment] = []
    @Published var isSending: Bool = false

    /// 当前正在看的笔记（标题 + 正文）。
    ///
    /// **没有它，模型只能盲答**：用户说"总结这篇""把第二段改成表格"，
    /// 它不知道"这篇""第二段"指的是什么，只能反问或者瞎猜。
    /// 界面在切换笔记时设置，会话不需要知道笔记是怎么来的。
    var noteContext: NoteContext?

    struct NoteContext {
        var title: String
        var html: String
    }

    private let provider: AIProvider

    /// 送进上下文的历史条数上限。
    ///
    /// 不做精确 token 计算：笔记动辄几万字，估错反而浪费一次请求。
    /// 按条数 + 单条字数双上限，粗但不会失控。
    private static let maxHistoryMessages = 12
    private static let maxMessageCharacters = 30_000

    init(provider: AIProvider = .shared) {
        self.provider = provider
    }

    // MARK: 附件

    func attach(_ items: [ChatAttachment]) {
        pending.append(contentsOf: items)
    }

    func removePending(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    // MARK: 状态

    var canSend: Bool {
        guard !isSending else { return false }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty || !pending.isEmpty
    }

    /// 末尾是失败态时，输入区给一个「重试」
    var canRetry: Bool {
        guard !isSending, let last = messages.last else { return false }
        if case .failed = last.state { return true }
        return false
    }

    var isEmpty: Bool { messages.isEmpty }

    // MARK: 发送

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pending
        draft = ""
        pending = []
        messages.append(AIChatMessage(role: .user, text: text, attachments: attachments))
        Task { await run() }
    }

    func retry() {
        guard canRetry else { return }
        if let last = messages.last, last.role == .assistant {
            messages.removeLast()
        }
        Task { await run() }
    }

    func clear() {
        guard !isSending else { return }
        messages.removeAll()
        pending.removeAll()
        draft = ""
    }

    // MARK: 请求

    private func run() async {
        isSending = true
        messages.append(AIChatMessage(role: .assistant, text: "", state: .sending))
        let index = messages.count - 1

        do {
            let payload = buildMessages()
            let completion = try await provider.complete(payload)
            let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AIError.emptyResponse }
            messages[index].text = text
            messages[index].state = .done
        } catch {
            messages[index].state = .failed(Self.describe(error))
        }
        isSending = false
    }

    private func buildMessages() -> [AIMessage] {
        var out: [AIMessage] = [.system(Self.systemPrompt)]

        // **把当前笔记塞进上下文。**
        // 放在 system 而不是 user：它是"背景信息"，不是用户说的话；
        // 混进 user 会让模型以为用户重复贴了一遍正文。
        if let context = noteContext {
            out.append(.system("""
            当前正在查看的笔记是《\(context.title)》。正文如下（已转成纯文本）：

            \(Self.plainText(from: context.html))
            """))
        }

        let recent = messages.suffix(Self.maxHistoryMessages + 1)
        for m in recent {
            switch m.role {
            case .user:
                let body = userBody(m)
                let images = m.attachments.compactMap { att -> AIImage? in
                    guard att.kind == .image, let data = att.rawData else { return nil }
                    return AIImage(data: data, mimeType: att.mimeType ?? "image/png")
                }
                out.append(images.isEmpty ? .user(body) : .userWithImages(text: body, images: images))
            case .assistant:
                // 失败/占位的回复不进上下文，否则会把错误信息当历史喂回去
                guard m.state == .done, !m.text.isEmpty else { continue }
                out.append(.assistant(clamp(m.text)))
            }
        }
        return out
    }

    private func userBody(_ m: AIChatMessage) -> String {
        var parts: [String] = []
        for att in m.attachments where att.kind != .image {
            parts.append(att.promptBlock)
        }
        if !m.text.isEmpty { parts.append(m.text) }
        return clamp(parts.joined(separator: "\n\n"))
    }

    private func clamp(_ s: String) -> String {
        guard s.count > Self.maxMessageCharacters else { return s }
        let head = s.prefix(Self.maxMessageCharacters)
        return String(head) + "\n\n…（内容过长，已截断 \(s.count - Self.maxMessageCharacters) 字）"
    }

    // MARK: 文案

    static func describe(_ error: Error) -> String {
        if let e = error as? AIError {
            switch e {
            case .notConfigured:
                return "还没有配置 AI 服务。打开「设置 › AI 服务」填地址和密钥。"
            case .badURL(let m):
                return "服务地址不对：\(m)"
            case .http(let code, let body):
                let brief = body.replacingOccurrences(of: "\n", with: " ")
                let head = String(brief.prefix(160))
                return "服务端返回 HTTP \(code)" + (head.isEmpty ? "" : "：\(head)")
            case .emptyResponse:
                return "模型返回了空内容，可以点重试再来一次。"
            case .network(let m):
                return "网络错误：\(m)"
            case .missingAPIKey:
                return "缺少 API Key。打开「设置 › AI 服务」补上。"
            case .modelListUnsupported:
                return "这个服务地址不支持列出模型，请手动填写模型名。"
            case .modelListEmpty:
                return "服务端没有返回可用模型，请手动填写。"
            }
        }
        return error.localizedDescription
    }

    /// HTML → 纯文本。只用于喂给模型。
    ///
    /// 标签对模型理解没有帮助，反而白占 token（一篇带样式的中文笔记，
    /// 标签能占掉一半篇幅）。块级标签转成换行，其余直接去掉。
    static func plainText(from html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p>|</div>|</li>|</h[1-6]>|</tr>",
                                   with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let systemPrompt = """
    你是配合「笔记」使用的助手。用户会把你给出的内容复制回自己的笔记，或者让你处理他附上的资料。

    你能做的事：
    - 阅读用户附上的图片（截图、表格照片）；
    - 阅读用户附上的表格数据，做数据对比、查找差异、批量替换、格式整理；
    - 改写、精简、扩写笔记正文。

    回答要求：
    - 直接给结论或可直接复制的内容。不要写"好的，我将为您…"这类开场。
    - 给表格时用 Markdown 表格；给替换方案时，用「原值 → 新值」两列列清楚。
    - 信息不足以判断时，先问一个最关键的问题，不要猜。
    """
}
