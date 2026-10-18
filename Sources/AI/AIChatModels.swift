import Foundation
import SwiftUI

struct AIChatMessage: Identifiable, Equatable {

    enum Role: Equatable {
        case user
        case assistant
    }

    enum State: Equatable {

        case done

        case sending

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

struct ChatAttachment: Identifiable, Equatable {

    enum Kind: Equatable {
        case image
        case spreadsheet
        case text
    }

    let id: UUID
    let kind: Kind
    let displayName: String

    var extractedText: String

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

@MainActor
final class AIChatSession: ObservableObject {

    @Published var messages: [AIChatMessage] = []
    @Published var draft: String = ""

    @Published var pending: [ChatAttachment] = []
    @Published var isSending: Bool = false

    var noteContext: NoteContext?

    struct NoteContext {
        var title: String
        var html: String
    }

    private let provider: AIProvider

    private static let maxHistoryMessages = 12
    private static let maxMessageCharacters = 30_000

    init(provider: AIProvider = .shared) {
        self.provider = provider
    }

    func attach(_ items: [ChatAttachment]) {
        pending.append(contentsOf: items)
    }

    func removePending(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    var canSend: Bool {
        guard !isSending else { return false }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty || !pending.isEmpty
    }

    var canRetry: Bool {
        guard !isSending, let last = messages.last else { return false }
        if case .failed = last.state { return true }
        return false
    }

    var isEmpty: Bool { messages.isEmpty }

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pending
        draft = ""
        pending = []
        messages.append(AIChatMessage(role: .user, text: text, attachments: attachments))
        Task { await run() }
    }

    func removeAttachment(_ item: ChatAttachment) {
        pending.removeAll { $0.id == item.id }
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

    图表要求（重要）：
    - **凡是要画饼图、占比图、柱状图，一律用下面的 chart 代码块，不要用 mermaid，
      也不要用文字描述数据、不要画 ASCII 图。**客户端会把它渲染成真正的图表。
    - 格式（JSON，必须能被解析）：

    ```chart
    {"type":"pie","title":"可选标题","unit":"%","data":[{"label":"类别","value":30}]}
    ```

    - `type` 只能是 `pie`（饼图/环形图）或 `bar`（柱状图）。
    - `data` 里每项一个类别，`value` 是数字（占比就传百分数本身，不要带 % 号）。
    - 分类不超过 8 项；超过就合并成「其他」。

    数学公式要求（重要）：
    - **所有数学公式必须用 LaTeX 包裹：行内用单个 `$…$`，独立成行用 `$$…$$`。**
    - 客户端内置 KaTeX，会把它渲染成真正的数学排版；不包裹的话只会显示成普通文字。
    - 例：`$\\int_\\alpha^\\beta f(r\\cos\\theta, r\\sin\\theta)\\,r\\,dr$`
    - 独立公式例：
      $$\\iint_D f(x,y)\\,dx\\,dy = \\int_\\alpha^\\beta d\\theta \\int_{r_1(\\theta)}^{r_2(\\theta)} f(r\\cos\\theta, r\\sin\\theta)\\,r\\,dr$$
    - 不要用 Unicode 上下标（如 `r₁`、`x²`）来代替 LaTeX。
    """
}
