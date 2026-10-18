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

    func complete(_ messages: [AIMessage]) async throws -> AICompletion

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
