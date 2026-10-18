import Foundation

/// 内置工具（MCP 的 tools/list + tools/call 语义）。
///
/// 不接外部 MCP server：那要起进程、走 JSON-RPC over stdio，
/// 对一个桌面笔记应用来说运维成本远大于收益。
/// 这里把「AI 能对笔记做什么」收敛成一组本地工具，协议形状与 MCP 一致，
/// 以后要接真 MCP server 时，替换执行器即可。
struct AITool {
    var name: String
    var description: String
    /// JSON Schema（OpenAI function calling 的 parameters）
    var parameters: [String: Any]

    /// 转成 OpenAI tools 数组里的一项
    var payload: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }
}

/// 工具执行结果：回填给模型的一段文本。
struct AIToolResult {
    var text: String
}

/// 工具注册表。所有工具都在主线程执行，因为它们要读缓存、改界面状态。
@MainActor
final class AIToolRegistry {

    static let shared = AIToolRegistry()

    private var handlers: [String: ([String: Any]) async -> AIToolResult] = [:]
    private(set) var tools: [AITool] = []

    private init() {
        registerDefaults()
    }

    func register(_ tool: AITool, handler: @escaping ([String: Any]) async -> AIToolResult) {
        tools.append(tool)
        handlers[tool.name] = handler
    }

    func call(name: String, arguments: [String: Any]) async -> String {
        guard let handler = handlers[name] else {
            return "没有名为 \(name) 的工具。"
        }
        return await handler(arguments).text
    }

    private func registerDefaults() {
        // 1. 搜索笔记
        register(
            AITool(
                name: "search_notes",
                description: "按关键词搜索本地缓存的笔记标题和摘要，返回最匹配的若干条（含 id 与标题）。用户问“我之前记过什么”时用它。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "搜索关键词"],
                        "limit": ["type": "integer", "description": "最多返回几条，默认 8"],
                    ],
                    "required": ["query"],
                ]
            )
        ) { args in
            let query = (args["query"] as? String ?? "").lowercased()
            let limit = min(max(args["limit"] as? Int ?? 8, 1), 20)
            guard !query.isEmpty else { return AIToolResult(text: "关键词为空。") }

            let (notes, _) = mainViewNoteCache.loadIndex()
            let hits = notes
                .filter { $0.title.lowercased().contains(query) || $0.snippet.lowercased().contains(query) }
                .prefix(limit)

            if hits.isEmpty { return AIToolResult(text: "没有匹配「\(query)」的笔记。") }

            let lines = hits.map { "- [\($0.id)] \($0.title)：\($0.snippet)" }
            return AIToolResult(text: "找到 \(hits.count) 条：\n" + lines.joined(separator: "\n"))
        }

        // 2. 读某条笔记的正文
        register(
            AITool(
                name: "read_note",
                description: "读取一条笔记的完整正文（HTML 片段）。需要引用具体内容时先用 search_notes 拿到 id，再用它。",
                parameters: [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "string", "description": "search_notes 返回的 id"],
                    ],
                    "required": ["note_id"],
                ]
            )
        ) { args in
            guard let id = args["note_id"] as? String,
                  let content = mainViewNoteCache.content(for: id) else {
                return AIToolResult(text: "找不到这条笔记的正文。")
            }
            // 正文可能很长，截断避免把上下文撑爆
            let plain = content.html.count > 6000 ? String(content.html.prefix(6000)) + "…" : content.html
            return AIToolResult(text: plain)
        }

        // 3. 列出文件夹
        register(
            AITool(
                name: "list_folders",
                description: "列出本地缓存里的所有文件夹及各自笔记数量。用户问“我有哪些分类”时用它。",
                parameters: ["type": "object", "properties": [:]]
            )
        ) { _ in
            let (_, folders) = mainViewNoteCache.loadIndex()
            if folders.isEmpty { return AIToolResult(text: "还没有文件夹。") }
            let lines = folders.map { "- \($0.name)（\($0.noteCount) 条）" }
            return AIToolResult(text: lines.joined(separator: "\n"))
        }
    }
}
