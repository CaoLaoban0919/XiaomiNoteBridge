import Foundation
import Combine

private enum NoteAILimit {
    static let bodyCharacters = 80_000
    static let imageCount = 8
    static let imageBytes = 4 * 1024 * 1024
    static let totalImageBytes = 12 * 1024 * 1024
}

private struct NoteAIPayload: Decodable {
    var summary: String?
    var html: String?
}

enum NoteAIApplyError: LocalizedError {

    case notLinked

    var errorDescription: String? {
        switch self {
        case .notLinked:
            return "这条笔记还没有和「备忘录」建立对应关系（可能尚未同步完成），暂时无法写入。请先同步一次，成功后再回来重构。"
        }
    }
}

@MainActor
final class NoteAI: ObservableObject, NoteAIProtocol {

    private let provider: AIProviderProtocol

    private let cache: NoteCacheProtocol

    @Published private(set) var isWorking = false

    init(provider: AIProviderProtocol, cache: NoteCacheProtocol = NoteCache()) {
        self.provider = provider
        self.cache = cache
    }

    func rewriteNote(noteId: String,
                     title: String,
                     body: String,
                     images: [AIImage],
                     instruction: String?) async throws -> NoteAIResult {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBody.isEmpty || !images.isEmpty else {
            throw NoteAIError.nothingToDo
        }

        try validateSize(body: trimmedBody, images: images)

        guard provider.config.isUsable else {
            throw AIError.notConfigured
        }

        isWorking = true
        defer { isWorking = false }

        let messages = buildMessages(title: title,
                                     body: trimmedBody,
                                     images: images,
                                     instruction: instruction)

        // 重构走单轮：它要的是确定的 HTML 输出，不需要模型调工具
        let completion = try await provider.complete(messages, tools: [])
        return parse(completion.text)
    }

    func applyResult(_ result: NoteAIResult, toNoteId noteId: String) async throws {
        var state = SyncStateStore.load()

        guard let appleId = state.notes[noteId]?.appleId,
              !appleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteAIApplyError.notLinked
        }

        if let current = cache.content(for: noteId) {
            try? cache.saveOriginalIfAbsent(current, for: noteId)
        }

        let (withoutImages, embeddedImages) = Self.splitEmbeddedImages(result.html)

        let cleaned = NotesHTMLSanitizer.sanitizeWithReport(withoutImages)
        try await NotesImporter.setBody(id: appleId, html: cleaned.html)

        if !embeddedImages.isEmpty {
            var urls: [URL] = []
            for (index, data) in embeddedImages.enumerated() {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("minb-embed-\(index)-\(UUID().uuidString).png")
                if (try? data.write(to: url)) != nil { urls.append(url) }
            }
            defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

            do {
                _ = try await NotesImporter.insertImages(id: appleId, fileURLs: urls)
            } catch {

            }
        }

        state.notes[noteId]?.aiModified = true
        try SyncStateStore.save(state)

        try? cache.saveContent(CachedNoteContent(html: cleaned.html, images: [:]), for: noteId)

        let latest = cache.loadIndex()
        var notes = latest.notes
        if let index = notes.firstIndex(where: { $0.id == noteId }) {
            notes[index].aiModified = true
            try? cache.saveIndex(notes: notes, folders: latest.folders)
        }
    }

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

        return finish(html: cleaned,
                      summary: "模型没有按结构化格式返回，已把它的原始输出原样作为正文。请仔细核对后再决定是否写入。",
                      degraded: true)
    }

    private func finish(html: String, summary: String, degraded: Bool) -> NoteAIResult {
        let stripped = Self.removingImages(from: html)
        var finalSummary = summary
        if stripped.removed {

            finalSummary += "（提示：模型输出里含有图片，已按写回通道的限制移除，正文因此少了图片内容。）"
        } else if degraded {
            finalSummary += "（提示：本次未按结构化格式解析。）"
        }
        return NoteAIResult(html: stripped.text, summary: finalSummary)
    }

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

        let summary = Self.quotedValue(forKey: "summary", in: raw)
        let html = Self.quotedValue(forKey: "html", in: raw)
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NoteAIPayload(summary: summary, html: html)
        }
        return nil
    }

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

    private static func braceSubstring(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }

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

    static func splitEmbeddedImages(_ html: String) -> (html: String, images: [Data]) {
        guard html.lowercased().contains("data:image") else { return (html, []) }

        let pattern = "<img[^>]*src=\"data:image/[^\"]+;base64,([^\"]+)\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (html, [])
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (html, []) }

        var images: [Data] = []
        for match in matches where match.numberOfRanges > 1 {
            if let data = Data(base64Encoded: ns.substring(with: match.range(at: 1))) {
                images.append(data)
            }
        }

        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "<p>[图片已转存为附件]</p>")
        }

        return (mutable as String, images)
    }
}
