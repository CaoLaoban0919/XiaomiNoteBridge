import Foundation

struct AIConfig: Codable, Equatable {

    var baseURL: String
    var apiKey: String

    var model: String

    var visionModel: String

    var enabled: Bool

    static let empty = AIConfig(baseURL: "", apiKey: "", model: "",
                                visionModel: "", enabled: false)

    var effectiveVisionModel: String {
        visionModel.trimmingCharacters(in: .whitespaces).isEmpty ? model : visionModel
    }

    var isUsable: Bool {
        enabled
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum AIMessage {
    case system(String)
    case user(String)

    case userWithImages(text: String, images: [AIImage])

    case assistant(String)

    /// 模型决定调用工具：content 可能为空，真正的内容在 calls 里。
    case assistantToolCalls(text: String?, calls: [AIToolCall])

    /// 工具执行结果，按 id 回填给模型。
    case toolResult(id: String, content: String)
}

/// 一次工具调用请求。
struct AIToolCall {
    var id: String
    var name: String
    /// 原始 JSON 字符串（OpenAI 把 arguments 作为字符串返回）
    var arguments: String

    /// 解析成字典；解析失败返回空字典，让工具自己报「参数缺失」。
    var argumentObject: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

/// 把任意 JSON 值包成 Encodable，用于工具参数 schema。
///
/// 不用 `[String: Any]` 直接编码：`JSONEncoder` 不支持 `Any`，
/// 而工具 schema 天然是嵌套字典 + 数组 + 基础类型。
enum JSONValue: Encodable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(_ any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .integer(value)
        case let value as Double: self = .number(value)
        case let value as [Any]: self = .array(value.map(JSONValue.init))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct AIImage {
    var data: Data

    var mimeType: String

    init(data: Data, mimeType: String = "image/png") {
        self.data = data
        self.mimeType = mimeType
    }
}

struct AICompletion {
    var text: String
    var model: String
    /// 模型要求调用的工具。为空表示这是最终回答。
    var toolCalls: [AIToolCall] = []
}

enum AIError: LocalizedError {
    case notConfigured
    case badURL(String)
    case http(Int, String)
    case emptyResponse
    case network(String)

    case missingAPIKey

    case modelListUnsupported

    case modelListEmpty

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没有配置 AI 服务。请在「设置 → AI」里填写地址、密钥与模型。"
        case .badURL(let u): return "服务地址无法解析：\(u)"
        case .http(let code, let body): return "服务返回 HTTP \(code)：\(body)"
        case .emptyResponse: return "模型返回了空内容。"
        case .network(let m): return "网络异常：\(m)"
        case .missingAPIKey: return "还没有填写 API Key，无法读取模型列表。"
        case .modelListUnsupported: return "这个服务没有提供 /models 接口，请手动填写模型名。"
        case .modelListEmpty: return "服务返回的模型列表是空的，请手动填写模型名。"
        }
    }

    var suggestsManualEntry: Bool {
        switch self {
        case .modelListUnsupported, .modelListEmpty: return true
        default: return false
        }
    }
}

protocol AIProviderProtocol: AnyObject {
    var config: AIConfig { get }
    func update(_ config: AIConfig)

    func complete(_ messages: [AIMessage], tools: [AITool]) async throws -> AICompletion

    func testConnection() async throws -> String

    func fetchModels() async throws -> [String]
}

struct NoteAIResult {

    var html: String

    var summary: String
}

enum NoteAIError: LocalizedError {
    case tooLarge(String)
    case nothingToDo

    var errorDescription: String? {
        switch self {
        case .tooLarge(let what): return "\(what)太大，超出可发送的范围。"
        case .nothingToDo: return "这条笔记没有可处理的内容。"
        }
    }
}

protocol NoteAIProtocol: AnyObject {

    func rewriteNote(noteId: String,
                     title: String,
                     body: String,
                     images: [AIImage],
                     instruction: String?) async throws -> NoteAIResult

    func applyResult(_ result: NoteAIResult, toNoteId: String) async throws
}
