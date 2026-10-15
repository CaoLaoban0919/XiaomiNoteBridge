import Foundation

// 「内置 AI」这条链路的**共享契约**。三个部分各自依赖它、互不 import 对方：
//   - AIProvider   ：可配置的 OpenAI 兼容客户端 + 配置存储 + 设置界面
//   - NoteAI       ：用模型分析、重构一条笔记
//   - SyncEngine   ：跳过被 AI 改过的笔记，别把重构成果冲掉
//
// 设计原则：**不预设厂商。** baseURL / apiKey / 模型名全部由用户填写，
// 我们只提供框架。这样 DeepSeek、OpenAI、Moonshot、本地 Ollama / LM Studio
// 这些「OpenAI 兼容」的服务都能接，不需要为每家写适配。

// MARK: - 配置

/// 一个 OpenAI 兼容服务的配置。**不预设厂商。**
struct AIConfig: Codable, Equatable {
    /// 服务地址。用户可能填 `https://api.deepseek.com`，也可能填 `.../v1`，
    /// **统一由客户端负责拼出正确的 `/chat/completions`**，调用方不用管。
    var baseURL: String
    var apiKey: String
    /// 处理纯文本用的模型名，例如 `deepseek-chat`
    var model: String
    /// 处理图片用的模型名。留空表示与 `model` 相同。
    /// 例如 DeepSeek 只有 `deepseek-v4-flash-vision-exp` 能收图，就必须单独填。
    var visionModel: String
    /// 关掉之后就完全不联网、不显示 AI 相关入口
    var enabled: Bool

    static let empty = AIConfig(baseURL: "", apiKey: "", model: "",
                                visionModel: "", enabled: false)

    /// 实际用于看图的模型名（visionModel 为空时回落 model）
    var effectiveVisionModel: String {
        visionModel.trimmingCharacters(in: .whitespaces).isEmpty ? model : visionModel
    }

    /// 配置是否完整到可以发请求
    var isUsable: Bool {
        enabled
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 配置的持久化由 `AIProvider.swift` 实现（`AIConfigStore`）。
/// 要求：**0600 权限**，与登录凭证同放在 Application Support；
/// API Key 不进 UserDefaults、不进日志、不进错误信息。

// MARK: - 消息

/// 发给模型的一条消息。
enum AIMessage {
    case system(String)
    case user(String)
    /// 带图的消息 —— 笔记里的手绘图、截图走这条。
    /// 按 OpenAI 的 content blocks 形态发送（text block + 若干 image_url block）。
    case userWithImages(text: String, images: [AIImage])
}

/// 一张要发给模型的图
struct AIImage {
    var data: Data
    /// 例如 `image/png`。服务端通常按内容探测，但声明一下更稳。
    var mimeType: String

    init(data: Data, mimeType: String = "image/png") {
        self.data = data
        self.mimeType = mimeType
    }
}

/// 模型返回
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

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没有配置 AI 服务。请在「设置 → AI」里填写地址、密钥与模型。"
        case .badURL(let u): return "服务地址无法解析：\(u)"
        case .http(let code, let body): return "服务返回 HTTP \(code)：\(body)"
        case .emptyResponse: return "模型返回了空内容。"
        case .network(let m): return "网络异常：\(m)"
        }
    }
}

// MARK: - 客户端

protocol AIProviderProtocol: AnyObject {
    var config: AIConfig { get }
    func update(_ config: AIConfig)

    /// 发一条请求，返回模型输出。
    /// 纯文本走 `model`，带图的消息走 `effectiveVisionModel`，由实现自己选。
    func complete(_ messages: [AIMessage]) async throws -> AICompletion

    /// 连通性测试。发一句最短的话，成功时返回一句给人看的结果（含模型名）。
    func testConnection() async throws -> String
}

// MARK: - 笔记分析 / 重构

/// AI 处理一条笔记之后的结果。
struct NoteAIResult {
    /// 重构后的正文，**是可以直接交给 `NotesImporter.setBody` 的 HTML**。
    ///
    /// ⚠️ **只能包含文字、排版、表格这类内容，不能含图片**——
    /// `set body` 写不进图片（实测会变成 `base64,(null)`），
    /// 所以让模型产出图片是没意义的，提示词里要明确禁止。
    var html: String
    /// 给用户看的一句话说明（做了什么改动）
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

/// 笔记 AI 处理。UI 只依赖这个协议。
protocol NoteAIProtocol: AnyObject {
    /// 分析并重构一条笔记。**只产出结果，不落盘**——先给用户看，确认了才写。
    /// - Parameters:
    ///   - noteId: 小米侧的 noteId（用来定位这条笔记）
    ///   - title: 笔记标题
    ///   - body: 正文（已转成 HTML 片段）
    ///   - images: 笔记里的图片字节（用于让模型"看图"）
    ///   - instruction: 用户额外想说的话，可为空
    func rewriteNote(noteId: String,
                     title: String,
                     body: String,
                     images: [AIImage],
                     instruction: String?) async throws -> NoteAIResult

    /// 把重构结果写回备忘录，并在 `SyncState` 里把这条标记为 `aiModified`。
    ///
    /// 标记这一步**不能省**——否则小米侧下次有改动时，同步会用 `set body`
    /// 覆盖，把用户花时间做的重构冲掉。
    func applyResult(_ result: NoteAIResult, toNoteId: String) async throws
}
