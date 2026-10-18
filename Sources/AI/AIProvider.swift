import Foundation
import SwiftUI

enum AIConfigStore {

    static let fileName = "ai-config.json"

    static var directory: URL { CredentialsStore.directory }

    static var fileURL: URL { directory.appendingPathComponent(fileName, isDirectory: false) }

    static func load() -> AIConfig? {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data)
        else { return nil }
        return config
    }

    static func save(_ config: AIConfig) throws {
        _ = CredentialsStore.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: [.atomic])

        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func filePermission() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mode = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return String(format: "%03o", mode.intValue)
    }
}

final class AIProvider: ObservableObject, AIProviderProtocol {

    static let shared = AIProvider()

    static let requestTimeout: TimeInterval = 60

    static let modelListTimeout: TimeInterval = 20

    @Published private(set) var config: AIConfig

    @Published private(set) var lastSaveError: String?

    private let session: URLSession

    init(config: AIConfig? = nil, session: URLSession? = nil) {
        self.config = config ?? AIConfigStore.load() ?? .empty
        if let session {
            self.session = session
        } else {

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = AIProvider.requestTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

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

    enum AIResource: String, CaseIterable {
        case chatCompletions = "chat/completions"
        case models = "models"
    }

    static func endpointURL(for baseURL: String,
                            resource: AIResource = .chatCompletions) throws -> URL {
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

        var lowercasedPath = path.lowercased()
        for known in AIResource.allCases {
            let marker = "/" + known.rawValue
            if lowercasedPath.hasSuffix(marker) {
                path.removeLast(marker.count)
                while path.hasSuffix("/") { path.removeLast() }
                lowercasedPath = path.lowercased()
                break
            }
        }

        let suffix = "/" + resource.rawValue
        let lastSegment = lowercasedPath.split(separator: "/").last.map(String.init) ?? ""
        let isVersionSegment = lastSegment.range(of: "^v[0-9]+$", options: .regularExpression) != nil
        path += isVersionSegment ? suffix : "/v1" + suffix

        var resolved = components
        resolved.percentEncodedPath = path
        resolved.query = nil
        resolved.fragment = nil
        guard let url = resolved.url else { throw AIError.badURL(baseURL) }
        return url
    }

    func complete(_ messages: [AIMessage], tools: [AITool] = []) async throws -> AICompletion {
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
            ChatRequest(model: model,
                        messages: messages.map(WireMessage.init),
                        tools: tools.isEmpty ? nil : tools.map(ToolWire.init))
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

        // 工具调用优先：模型这一轮可能只给了 tool_calls，content 是空的。
        let calls = (decoded.choices?.first?.message?.toolCalls ?? []).compactMap { raw -> AIToolCall? in
            guard let name = raw.function?.name, !name.isEmpty else { return nil }
            return AIToolCall(id: raw.id ?? UUID().uuidString,
                              name: name,
                              arguments: raw.function?.arguments ?? "{}")
        }

        if !calls.isEmpty {
            return AICompletion(text: text, model: decoded.model ?? model, toolCalls: calls)
        }

        guard !text.isEmpty else { throw AIError.emptyResponse }

        return AICompletion(text: text, model: decoded.model ?? model)
    }

    func testConnection() async throws -> String {
        let started = Date()
        let completion = try await complete([.user("你好")])
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return "\(completion.model) 响应正常，耗时 \(milliseconds) ms。"
    }

    func fetchModels() async throws -> [String] {
        let config = self.config
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw AIError.badURL(config.baseURL) }
        guard !key.isEmpty else { throw AIError.missingAPIKey }

        let url = try AIProvider.endpointURL(for: base, resource: .models)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = AIProvider.modelListTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

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

        if http.statusCode == 404 || http.statusCode == 405 {
            throw AIError.modelListUnsupported
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, AIProvider.preview(of: data))
        }

        let decoded: ModelListResponse
        do {
            decoded = try JSONDecoder().decode(ModelListResponse.self, from: data)
        } catch {
            throw AIError.network("无法解析模型列表：\(AIProvider.preview(of: data))")
        }

        var seen = Set<String>()
        let ids = (decoded.data ?? []).compactMap { entry -> String? in
            guard let raw = entry.id else { return nil }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
        guard !ids.isEmpty else { throw AIError.modelListEmpty }

        return ids.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

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

private struct ChatRequest: Encodable {
    var model: String
    var messages: [WireMessage]
    var tools: [ToolWire]?
}

/// 工具定义的线上格式（OpenAI function calling / MCP tools/list 同形）
private struct ToolWire: Encodable {
    var type: String = "function"
    var function: Function

    struct Function: Encodable {
        var name: String
        var description: String
        var parameters: JSONValue
    }

    init(_ tool: AITool) {
        function = Function(name: tool.name,
                            description: tool.description,
                            parameters: JSONValue(tool.parameters))
    }
}

/// 模型发起的工具调用（请求里回传历史时用）
private struct ToolCallWire: Encodable {
    var id: String
    var type: String = "function"
    var function: Function

    struct Function: Encodable {
        var name: String
        var arguments: String
    }

    init(_ call: AIToolCall) {
        id = call.id
        function = Function(name: call.name, arguments: call.arguments)
    }
}

private struct WireMessage: Encodable {
    var role: String
    var content: WireContent
    var toolCalls: [ToolCallWire]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(_ message: AIMessage) {
        switch message {
        case .system(let text):
            role = "system"
            content = .plain(text)
        case .user(let text):
            role = "user"
            content = .plain(text)
        case .assistant(let text):
            role = "assistant"
            content = .plain(text)
        case .userWithImages(let text, let images):
            role = "user"

            content = images.isEmpty
                ? .plain(text)
                : .blocks(WireContent.blocks(text: text, images: images))
        case .assistantToolCalls(let text, let calls):
            role = "assistant"
            content = .plain(text ?? "")
            toolCalls = calls.map(ToolCallWire.init)
        case .toolResult(let id, let content):
            role = "tool"
            self.content = .plain(content)
            toolCallID = id
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

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ToolCall: Decodable {
                var id: String?
                var function: Function?

                struct Function: Decodable {
                    var name: String?
                    var arguments: String?
                }
            }
            var content: FlexibleContent?
            var toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }
        var message: Message?
    }
    var choices: [Choice]?
    var model: String?
}

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

private struct ModelListResponse: Decodable {
    struct Entry: Decodable {
        let id: String?
    }
    let data: [Entry]?
}
