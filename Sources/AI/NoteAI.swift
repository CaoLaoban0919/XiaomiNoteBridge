import Foundation
import Combine

// 「用 AI 分析重构一条笔记」的实现。
//
// 这一层是**纯逻辑**：组提示词、调 `AIProviderProtocol`、解析返回、结果落盘。
// 它只依赖 `AIContract.swift` 里的契约，不认识具体的模型厂商，也不 import SwiftUI。
// 界面（`MainView`）只通过 `NoteAIProtocol` 与它交互。
//
// 两条铁律，任何改动都不能破坏：
//   1. **重构结果不含图片。** 写回备忘录的通道（`NotesImporter.setBody`）写不进图片
//      —— 实测会变成字面的 `base64,(null)`，等于把内容弄丢。所以提示词里硬性禁止，
//      代码里**再兜底剥一次**：模型不听指挥时，宁可掉图也不能把废数据写进用户笔记。
//   2. **只产出、不落盘。** `rewriteNote` 永远不碰用户的备忘录；
//      只有用户点过「写入备忘录」、调用 `applyResult` 时才真正写。

// MARK: - 规模上限

/// 一次请求允许携带的最大规模。
///
/// 数值不是随手取的，依据是「上下文预算 + 请求体大小」两件事：
/// - **正文 80_000 字符**：中文在主流分词器里大致 1 字 ≈ 0.6~1 token，80k 字约 50k~80k
///   token，叠上系统提示词和输出仍能塞进 128k 上下文；再往上逼近上限时，
///   与其发出去被截断（模型会丢掉尾巴却不报错），不如本地明确拒绝。
/// - **图片最多 8 张 / 单张 4MB / 合计 12MB**：视觉模型对多图的注意力会明显衰减，
///   8 张之后基本是噪声；图片按 base64 编码进请求会膨胀约 1/3，12MB 原图 → ~16MB 请求体，
///   是多数服务默认请求体上限以内比较稳的量级。
private enum NoteAILimit {
    static let bodyCharacters = 80_000
    static let imageCount = 8
    static let imageBytes = 4 * 1024 * 1024
    static let totalImageBytes = 12 * 1024 * 1024
}

// MARK: - 返回解析的中间结构

/// 期望模型返回的 JSON 结构。字段都可选——模型少给一个字段时，
/// 我们要能降级处理而不是整体判失败。
private struct NoteAIPayload: Decodable {
    var summary: String?
    var html: String?
}

// MARK: - 写回阶段的错误

/// `applyResult` 特有的错误。
///
/// 为什么不塞进 `NoteAIError`：那是契约文件（`AIContract.swift`）里定义的类型，
/// 由别人维护，加 case 会破坏契约；而且语义上也不同——
/// `NoteAIError` 描述「这条笔记能不能处理」，这里描述「处理完了能不能写回去」。
enum NoteAIApplyError: LocalizedError {
    /// 小米侧的这条笔记还没映射到备忘录里的具体笔记，没有可写目标。
    case notLinked

    var errorDescription: String? {
        switch self {
        case .notLinked:
            return "这条笔记还没有和「备忘录」建立对应关系（可能尚未同步完成），暂时无法写入。请先同步一次，成功后再回来重构。"
        }
    }
}

// MARK: - 主体

/// 用模型分析、重构一条笔记。
///
/// `@MainActor`：它是被 SwiftUI 直接驱动的对象，`@Published` 状态只在主线程更新。
/// 真正的网络往返发生在 `provider.complete` 内部，`await` 期间不占用主线程。
@MainActor
final class NoteAI: ObservableObject, NoteAIProtocol {

    /// 模型客户端。只依赖协议，因此可以换成任何 OpenAI 兼容实现，也方便测试时替身。
    private let provider: AIProviderProtocol

    /// 缓存索引。写回时要同步更新它的 `aiModified`，理由见 `applyResult`。
    private let cache: NoteCacheProtocol

    /// 当前是否正在请求模型。界面用它显示进度。
    @Published private(set) var isWorking = false

    init(provider: AIProviderProtocol, cache: NoteCacheProtocol = NoteCache()) {
        self.provider = provider
        self.cache = cache
    }

    // MARK: - 重构（只产出，不落盘）

    func rewriteNote(noteId: String,
                     title: String,
                     body: String,
                     images: [AIImage],
                     instruction: String?) async throws -> NoteAIResult {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // 正文和图片都空 → 没有任何可分析的东西，直接说清楚，别浪费一次请求。
        guard !trimmedBody.isEmpty || !images.isEmpty else {
            throw NoteAIError.nothingToDo
        }

        try validateSize(body: trimmedBody, images: images)

        // 双重保险：界面本应禁用未配置时的按钮，但真到这一步也不能发出无效请求。
        guard provider.config.isUsable else {
            throw AIError.notConfigured
        }

        isWorking = true
        defer { isWorking = false }

        let messages = buildMessages(title: title,
                                     body: trimmedBody,
                                     images: images,
                                     instruction: instruction)

        let completion = try await provider.complete(messages)
        return parse(completion.text)
    }

    // MARK: - 写回 + 标记

    func applyResult(_ result: NoteAIResult, toNoteId noteId: String) async throws {
        var state = SyncStateStore.load()

        // 没有 appleId 就说明这条笔记还没真正进过「备忘录」，没有可写目标。
        guard let appleId = state.notes[noteId]?.appleId,
              !appleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteAIApplyError.notLinked
        }

        // **改写前留一份原文**（只留第一次），供详情栏的「显示原文」使用。
        // 必须在 `setBody` 与缓存覆盖之前做，否则拿到的已经是改写后的版本。
        if let current = cache.content(for: noteId) {
            try? cache.saveOriginalIfAbsent(current, for: noteId)
        }

        // **内嵌图片先落成临时文件。**
        // 备忘录的正文 HTML 写不进 data URI（实测会变成 base64,(null)），
        // 但 `make new attachment with data` 可以。所以正文里只留占位文字，
        // 图片走附件通道单独插入。
        let (withoutImages, embeddedImages) = Self.splitEmbeddedImages(result.html)

        // **写入前先规范化。**
        // 备忘录对 HTML 的容忍度远低于浏览器：`script`/`style` 会让整条写失败、
        // data URI 图片会让 AppleScript 直接报错、flex/grid 布局会让排版整段崩掉。
        // 在这里过一遍，把"写不进去"的内容提前处理掉，而不是等它抛错再猜原因。
        let cleaned = NotesHTMLSanitizer.sanitizeWithReport(withoutImages)
        if !cleaned.fixes.isEmpty {
            print("[NoteAI] HTML 已规范化：\(cleaned.fixes.joined(separator: "；"))")
        }
        try await NotesImporter.setBody(id: appleId, html: cleaned.html)

        // 图片在正文写完之后插入。Notes 会把文件复制进自己的库，
        // 所以临时文件用完就能删。
        if !embeddedImages.isEmpty {
            var urls: [URL] = []
            for (index, data) in embeddedImages.enumerated() {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("minb-embed-\(index)-\(UUID().uuidString).png")
                if (try? data.write(to: url)) != nil { urls.append(url) }
            }
            defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

            do {
                let cids = try await NotesImporter.insertImages(id: appleId, fileURLs: urls)
                print("[NoteAI] 已插入 \(cids.count) 张图片（正文占位 \(embeddedImages.count) 处）")
            } catch {
                // 图片插不进去不该让整次写入失败：文字部分已经落盘了
                print("[NoteAI] 插入图片失败：\(error.localizedDescription)")
            }
        }

        // 标记为「被 AI 改过」，同步时会跳过它。
        // 这一步不能省：否则小米侧下次有改动，`set body` 会把用户的重构成果直接冲掉。
        state.notes[noteId]?.aiModified = true
        try SyncStateStore.save(state)

        // **缓存正文也要跟上。** 只改 SyncState 的话，MainView 写回后会
        // `reloadFromCache()` + `loadBody()`，正文立刻退回重构前的版本——
        // 用户看到"已写入备忘录"却读着旧内容，会以为写入失败，
        // 于是再点一次重构，第二次又基于旧正文生成，真正写进去的那版就被盖掉了。
        // AI 结果按硬约束不含图片，`images` 传空是符合预期的（与 set body 写进去的一致）。
        // **必须存规范化之后的版本**，不是 `result.html`。
        // 缓存和备忘录里那份是给用户看的同一份东西；存原文会出现
        // "界面显示带图/带样式，备忘录里却是被清理过的样子"这种对不上的情况。
        try? cache.saveContent(CachedNoteContent(html: cleaned.html, images: [:]), for: noteId)

        // **两份账本都要标。**
        //   - state.json 是「同步时该不该跳过」的依据；
        //   - 缓存索引是**界面**显示「已被 AI 重构」的依据（MainView 的 noteAIModified）。
        // 只写前者的话，界面一 reloadFromCache 就把标记冲掉，用户会以为重构白做了，
        // 甚至会再重构一遍。
        let latest = cache.loadIndex()
        var notes = latest.notes
        if let index = notes.firstIndex(where: { $0.id == noteId }) {
            notes[index].aiModified = true
            try? cache.saveIndex(notes: notes, folders: latest.folders)
        }
    }

    /// 清除「被 AI 改过」标记（state 与缓存索引**两份都要清**）。
    ///
    /// 用户点「以此为准」时调用：他已经明确表示这份内容由自己定。
    /// 再挂着这个标记，界面就会一直显示「显示原文」，
    /// 而那份原文此刻已经和正文一致，没有查看的意义。
    func clearAIModified(noteId: String) {
        var state = SyncStateStore.load()
        state.notes[noteId]?.aiModified = false
        try? SyncStateStore.save(state)

        let latest = cache.loadIndex()
        var notes = latest.notes
        if let index = notes.firstIndex(where: { $0.id == noteId }) {
            notes[index].aiModified = false
            try? cache.saveIndex(notes: notes, folders: latest.folders)
        }
    }

    // MARK: - 提示词
    /// 系统提示词。**全文写死在代码里**，不放进资源文件——它和下面 `buildMessages`
    /// 里「图片怎么给」的约定是一体的，拆开容易改漏。
    ///
    /// 三条要点，缺一不可：
    ///   1. 说清来源（小米笔记迁移而来）与目标（**忠实重构**，不是创作，不许臆造）；
    ///   2. 明确「不许出图」这条硬约束，并解释原因，让模型有动机遵守；
    ///   3. 规定结构化输出（JSON），且给出**只允许的标签白名单**，
    ///      这样 `NoteHTML.parse` 才能把结果稳定地渲染出来。
    private static let systemPrompt = """
    你是「米记桥」应用里的笔记整理助手，负责把一条从「小米笔记」迁移过来的笔记**忠实重构**一遍。

    【背景】
    - 这条笔记原本写在小米笔记里，现已迁移到 Apple 备忘录。
    - 你拿到的正文是一段 HTML 片段（不是完整网页），可能包含标题、段落、列表、引用、代码、链接、待办，以及手写或截图。
    - 如果你收到了图片，那是原笔记里的手绘、截图或照片。

    【目标：忠实重构，不是创作】
    1. 补齐结构：把混乱的层级理清楚——该是标题的做成标题，该是列表的做成列表，该分段的正确分段。
    2. 整理表达：把潦草、口语化、随手记的内容写通顺，修正明显的错别字与语病，把省略号、箭头、缩写串讲清楚。
    3. 补必要说明：只在上下文足以确定时才把含糊处补完整（例如「周会上说的那个」补成「周会上提到的 XXX」）；拿不准就保留原样，可加「（原文如此）」。
    4. 保留信息：人名、数字、日期、链接、待办事项一律原样保留，不要删减。
    5. **绝对不要臆造笔记里没有的事实。** 不确定的内容宁可留着，也不要编。

    【硬约束 —— 违反会导致内容丢失】
    - 输出的正文里**不允许包含任何图片**：不要输出 <img> 标签，不要输出 base64 数据，不要输出 Markdown 图片语法 ![](...)，也不要输出图片链接或截图。写回备忘录的通道不支持图片，含图会导致内容丢失。
    - 如果原笔记里有图片，请用一句文字说明它原本是什么（例如「（此处原有一张手绘流程图）」），而不是把图片带出来。
    - 只输出 HTML 片段本身，不要输出 <html> / <head> / <body> 这类外层标签。
    - 正文只允许使用这些标签：<h1> <h2> <h3> <p> <div> <ul> <ol> <li> <blockquote> <pre> <code> <strong> <em> <u> <del> <hr> <br> <table> <thead> <tbody> <tr> <th> <td>。不要使用 <script>、<style>、<iframe>。

    【输出格式】
    只输出**一个 JSON 对象**，不要带任何解释文字，不要用 Markdown 代码块包裹：
    {"summary": "一句话说明你改了什么", "html": "<div>重构后的正文 HTML 片段</div>"}
    - summary：给用户看的一句话，说明本轮改动的重点。
    - html：重构后的正文，作为 JSON 字符串（换行、引号按 JSON 规则转义）。
    """

    /// 拼出发给模型的消息。
    ///
    /// 有图走 `userWithImages`（图片与正文一起发，模型才能对着图整理文字），
    /// 没图走纯文本 `user`——别给不需要图的请求平白增加体积。
    private func buildMessages(title: String,
                               body: String,
                               images: [AIImage],
                               instruction: String?) -> [AIMessage] {
        var text = """
        笔记标题：\(title.isEmpty ? "（无标题）" : title)

        正文 HTML 片段：
        \(body)
        """

        if let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += """


            我的额外要求（优先级最高）：
            \(instruction)
            """
        }

        if images.isEmpty {
            return [.system(Self.systemPrompt), .user(text)]
        }
        return [.system(Self.systemPrompt), .userWithImages(text: text, images: images)]
    }

    // MARK: - 规模校验

    private func validateSize(body: String, images: [AIImage]) throws {
        if body.count > NoteAILimit.bodyCharacters {
            throw NoteAIError.tooLarge("正文（\(body.count) 字，上限 \(NoteAILimit.bodyCharacters)）")
        }
        if images.count > NoteAILimit.imageCount {
            throw NoteAIError.tooLarge("图片数量（\(images.count) 张，上限 \(NoteAILimit.imageCount)）")
        }
        var total = 0
        for image in images {
            if image.data.count > NoteAILimit.imageBytes {
                throw NoteAIError.tooLarge("单张图片（\(image.data.count / 1024) KB，上限 \(NoteAILimit.imageBytes / 1024) KB）")
            }
            total += image.data.count
        }
        if total > NoteAILimit.totalImageBytes {
            throw NoteAIError.tooLarge("图片总量（\(total / 1024) KB，上限 \(NoteAILimit.totalImageBytes / 1024) KB）")
        }
    }

    // MARK: - 返回解析与降级

    /// 把模型输出解析成 `NoteAIResult`。
    ///
    /// **降级是这条链路里最容易被忽略、也最危险的一环**：模型不按格式返回是常态
    /// （包在 ```json 里、前后加一句寒暄、少给 summary……）。这里的原则是
    /// **能救就救，救不了也要说清楚，绝不给用户一个「看起来成功」的假象**。
    ///
    /// 结构化解析尝试的顺序（依次放宽）：
    ///   1. 整串直接当 JSON 解；
    ///   2. 去掉 ``` 代码围栏后再解；
    ///   3. 取第一个 `{` 到最后一个 `}` 之间的子串再解（对付前后寒暄）；
    ///   4. 第 3 步的子串再去围栏后解；
    ///   5. 正则逐字段抠 `"summary"` / `"html"` 的字符串值（对付局部不合法的 JSON）。
    /// 全部失败 → 降级：把整段输出当作正文，并在 `summary` 里**如实说明**这是降级结果。
    ///
    /// 无论走哪条路，最后都会再兜底剥一次图片（见 `removingImages`），
    /// 并把「剥掉了图」这件事如实写进 `summary`。
    private func parse(_ raw: String) -> NoteAIResult {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let payload = extractPayload(cleaned),
           let html = payload.html,
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summary = (payload.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return finish(html: html,
                          summary: summary.isEmpty ? "已重构这条笔记。" : summary,
                          degraded: false)
        }

        // 降级：连结构都拿不到，就把整段输出当正文。宁可让用户看到「模型没按格式来」，
        // 也不要凭空造一个空的成功结果——那会让用户以为写入的是重构后的笔记。
        return finish(html: cleaned,
                      summary: "模型没有按结构化格式返回，已把它的原始输出原样作为正文。请仔细核对后再决定是否写入。",
                      degraded: true)
    }

    /// 收尾：剥图片 + 拼最终的 summary。
    private func finish(html: String, summary: String, degraded: Bool) -> NoteAIResult {
        let stripped = Self.removingImages(from: html)
        var finalSummary = summary
        if stripped.removed {
            // 如实反映：模型违反约束输出了图片，我们把它剥掉了。
            finalSummary += "（提示：模型输出里含有图片，已按写回通道的限制移除，正文因此少了图片内容。）"
        } else if degraded {
            finalSummary += "（提示：本次未按结构化格式解析。）"
        }
        return NoteAIResult(html: stripped.text, summary: finalSummary)
    }

    /// 依次放宽候选人，找到第一个能解出非空 html 的结果。
    private func extractPayload(_ raw: String) -> NoteAIPayload? {
        var candidates: [String] = [raw]
        let unfenced = Self.strippingFences(raw)
        if unfenced != raw { candidates.append(unfenced) }
        let braced = Self.braceSubstring(raw)
        if let braced, braced != raw { candidates.append(braced) }
        if let braced, let bracedUnfenced = Self.braceSubstring(unfenced), bracedUnfenced != braced {
            candidates.append(bracedUnfenced)
        }

        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let payload = try? JSONDecoder().decode(NoteAIPayload.self, from: data),
               let html = payload.html,
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return payload
            }
        }

        // 最后一道：JSON 局部不合法时，逐字段正则抠。
        let summary = Self.quotedValue(forKey: "summary", in: raw)
        let html = Self.quotedValue(forKey: "html", in: raw)
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NoteAIPayload(summary: summary, html: html)
        }
        return nil
    }

    // MARK: - 文本工具（纯函数）

    /// 去掉 Markdown 代码围栏：开头的 ``` 或 ```json 与结尾的 ```。
    private static func strippingFences(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
            break
        }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
            break
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 取第一个 `{` 到最后一个 `}` 之间的子串（含两端）。找不到返回 nil。
    private static func braceSubstring(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }

    /// 抠出 `"key": "…"` 里的值，并按 JSON 转义规则还原。
    ///
    /// 正则该片段 `(?:[^"\\]|\\.)*` 能正确跨过被转义的引号；还原交给 `JSONDecoder`
    /// 处理 `\n`、`\"`、`\uXXXX`，不自己写反解，避免和 JSON 规范走偏。
    private static func quotedValue(forKey key: String, in text: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let rawValue = String(text[valueRange])
        let quoted = "\"\(rawValue)\""
        guard let data = quoted.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else {
            return rawValue
        }
        return value
    }

    /// 兜底剥离所有图片形态。返回 (处理后文本, 是否剥掉了东西)。
    ///
    /// 处理三种模型可能漏出来的写法：
    ///   - HTML：`<img …>`（含自闭合）、`<picture>…</picture>`、`<figure>…</figure>`；
    ///   - Markdown：`![alt](url)`；
    ///   - 残留的 `data:image/…;base64,…`（极少数情况下会脱离 img 标签裸奔）。
    private static func removingImages(from html: String) -> (text: String, removed: Bool) {
        var out = html
        let patterns = [
            "<img\\b[^>]*/?>",
            "<picture\\b[^>]*>[\\s\\S]*?</picture>",
            "<figure\\b[^>]*>[\\s\\S]*?</figure>",
            "!\\[[^\\]]*\\]\\([^)]*\\)",
            "data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\\s]+"
        ]
        var removed = false
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern,
                                                    options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                continue
            }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            if re.firstMatch(in: out, options: [], range: range) != nil {
                removed = true
            }
            out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "")
        }
        return (out, removed)
    }

    /// 把 HTML 里的 `data:` 图片抽出来，正文位置留占位文字。
    ///
    /// 备忘录的 `set body` 写不进 data URI（实测会变成 `base64,(null)`），
    /// 但附件的 `make new attachment with data` 可以。两件事必须拆开：
    /// 正文只留占位，图片单独走附件通道。
    static func splitEmbeddedImages(_ html: String) -> (html: String, images: [Data]) {
        guard html.lowercased().contains("data:image") else { return (html, []) }

        let pattern = "<img[^>]*src=\"data:image/[^\"]+;base64,([^\"]+)\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (html, [])
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (html, []) }

        // 先按出现顺序收集图片数据
        var images: [Data] = []
        for match in matches where match.numberOfRanges > 1 {
            if let data = Data(base64Encoded: ns.substring(with: match.range(at: 1))) {
                images.append(data)
            }
        }

        // 再从后往前替换：反过来做，前面的替换才不会让后面的 range 失效
        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "<p>[图片已转存为附件]</p>")
        }

        return (mutable as String, images)
    }
}
