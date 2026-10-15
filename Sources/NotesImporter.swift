import Foundation

// MARK: - 数据结构

/// 「备忘录」里的一条笔记在 Swift 侧的轻量投影。
///
/// 只保留迁移流程真正需要的字段：
/// - `id` 是 AppleScript `id of note` 返回的稳定标识（形如 `x-coredata://…`），
///   也是后续「通道二」覆盖更新时唯一定位一条笔记的钥匙，务必原样保存；
/// - `bodyLength` 是 HTML 源码的字符数（含标签），不是可见文字长度，仅用于粗筛变化。
struct AppleNote: Sendable {
    var id: String
    var name: String
    var folder: String
    var created: Date?
    var modified: Date?
    var bodyLength: Int
}

/// 「备忘录」里的一个文件夹在 Swift 侧的轻量投影。
///
/// `id` 取自 AppleScript `id of folder`（形如 `x-coredata://…/ICFolder/p394`）。
/// 复用已有文件夹时靠 `name` 匹配，新建时返回的 `id` 可用于后续定位。
struct AppleFolder: Sendable {
    var id: String
    var name: String
}

// MARK: - 错误

/// 桥接层对外暴露的错误。把 AppleScript 抛出的原始错误码翻译成有意义的中文提示。
enum NotesImportError: LocalizedError {
    /// 没有「备忘录」的自动化权限（AppleScript 错误码 -1743）
    case notAuthorized
    /// 「备忘录」进程没在运行（AppleScript 错误码 -600）
    case notesNotRunning
    /// 找不到对象：文件夹或笔记 id 不存在（AppleScript 错误码 -1728）。
    /// 关联值是 AppleScript 的原始报错文本，便于定位到底是哪一步。
    case objectNotFound(String)
    /// 该版本「备忘录」不支持这个 AppleScript 命令（错误码 -1708）
    case commandNotHandled(String)
    /// 返回值无法解析（例如计数结果不是整数）
    case invalidData(String)
    /// 临时文件读写失败
    case tempFileIO(String)
    /// 其它未分类的脚本错误
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "尚未获得「备忘录」的自动化权限，请在「系统设置 › 隐私与安全性 › 自动化」中勾选本应用。"
        case .notesNotRunning:
            return "「备忘录」当前没有运行，请先打开它再重试。"
        case .objectNotFound(let detail):
            return "在「备忘录」中找不到对应的文件夹或笔记（可能已被移动或删除）。原始信息：\(detail)"
        case .commandNotHandled(let detail):
            return "当前版本的「备忘录」不支持该操作。原始信息：\(detail)"
        case .invalidData(let detail):
            return "「备忘录」返回的数据无法解析：\(detail)"
        case .tempFileIO(let detail):
            return "临时文件读写失败：\(detail)"
        case .scriptError(let detail):
            return "AppleScript 执行出错：\(detail)"
        }
    }
}

// MARK: - 导入器

/// 与「备忘录」交互的读/写封装。
///
/// 职责边界：
/// - 所有脚本一律交给 `NotesBridge.run(_:)` 在后台线程执行，本类不自己起 `Process`；
/// - 本类不做 UI，也不 import SwiftUI；纯逻辑，方便被同步引擎调用。
///
/// 两条迁移通道的分工：
/// - **通道一（新笔记）**：生成 `.enex` 交给「备忘录」导入，本类不参与写入；
///   但导入后需要 `countNotes` / `listNotes` / `findNoteIDsByTitle` 回读配对，
///   建立「小米 noteId ↔ 备忘录 id」的映射。
/// - **通道二（已导入后被改过的笔记）**：用 `setBody(id:html:)` 直接覆盖正文。
///
/// ⚠️ `setBody` 与 `createNote` 会真实修改用户的「备忘录」数据，其余方法只读。
enum NotesImporter {

    // MARK: 分隔符

    /// 字段分隔符：ASCII Unit Separator (U+001F)。
    /// 用它而不是逗号，是因为标题/文件夹名里可能含逗号，会撞车；US 几乎不可能出现在正文里。
    private static let fieldSeparator: Character = "\u{1F}"

    /// 记录分隔符：ASCII Record Separator (U+001E)。
    /// 一条笔记一行用 US 拼字段，多条笔记之间用 RS 连接，双向都不会歧义。
    private static let recordSeparator: Character = "\u{1E}"

    // MARK: 日期

    /// 解析 AppleScript 端拼出来的 `yyyy-MM-dd'T'HH:mm:ss`（本地时区、无时区后缀）。
    private static let isoLocalFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    // MARK: - 只读：文件夹

    /// 列出「备忘录」里所有文件夹的名字（跨所有账户）。
    /// 只读，不会改动任何数据。
    static func listFolders() async throws -> [String] {
        let script = """
        set US to (character id 31)
        set outStr to ""
        tell application "Notes"
            repeat with f in folders
                set outStr to outStr & ((name of f) as string) & US
            end repeat
        end tell
        return outStr
        """
        let raw = try await runClassified(script, context: "列出文件夹")
        guard !raw.isEmpty else { return [] }
        return raw
            .split(separator: fieldSeparator, omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// 列出「备忘录」里所有文件夹及其 id（跨所有账户）。
    ///
    /// 与 `listFolders()` 的区别只有一个：多带回 `id of folder`。
    /// 保留小米文件夹结构时，先靠名字匹配复用已有文件夹，只有确实不存在才新建，
    /// 这样反复同步也不会把同名文件夹越建越多。
    ///
    /// 记录格式固定为 `id US name RS`；`name` 为空的记录（异常情况）直接跳过。
    /// 只读，不会改动任何数据。
    static func listFoldersWithIDs() async throws -> [AppleFolder] {
        let script = """
        set US to (character id 31)
        set RS to (character id 30)
        set outStr to ""
        tell application "Notes"
            repeat with f in folders
                set fid to ""
                try
                    set fid to (id of f) as string
                end try
                set fname to ""
                try
                    set fname to (name of f) as string
                end try
                set outStr to outStr & fid & US & fname & RS
            end repeat
        end tell
        return outStr
        """
        let raw = try await runClassified(script, context: "列出文件夹（含 id）")
        guard !raw.isEmpty else { return [] }
        var result: [AppleFolder] = []
        for record in raw.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            let fields = record
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 2, !fields[1].isEmpty else { continue }
            result.append(AppleFolder(id: fields[0], name: fields[1]))
        }
        return result
    }

    // MARK: - 只读：计数（用于「数数确认」）

    /// 数一数笔记条数。
    ///
    /// - Parameter folder: 传文件夹名只数该文件夹；传 `nil` 数全部笔记。
    /// - Returns: 笔记条数。
    ///
    /// 迁移流程用它做「导入前后数一遍，涨够了才算成功」的验收判断。
    /// 只读，不会改动任何数据。
    static func countNotes(inFolder folder: String?) async throws -> Int {
        let script: String
        if let folder {
            script = """
            tell application "Notes"
                return (count of notes of folder "\(escapeForAppleScript(folder))") as string
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                return (count of notes) as string
            end tell
            """
        }
        let raw = try await runClassified(script, context: "统计笔记条数")
        guard let n = Int(raw) else {
            throw NotesImportError.invalidData("计数结果不是整数：\(raw)")
        }
        return n
    }

    // MARK: - 只读：列出笔记

    /// 列出笔记及其内部 id。
    ///
    /// - Parameters:
    ///   - folder: 传文件夹名只列该文件夹；传 `nil` 列全部笔记。
    ///   - includeBodyLength: 是否顺便取正文长度。**默认为 false，这一点很重要**：
    ///     取长度要求 AppleScript 逐条读取完整 `body`，而 AppleScript 的属性访问很慢，
    ///     上千条笔记会跑到几十秒。建立映射、回读配对都只需要 id 和标题，
    ///     所以默认不取；只有确实需要粗筛变化时才打开。
    /// - Returns: `AppleNote` 数组，其中 `id` 取自 AppleScript `id of note`，是后续定位笔记的唯一稳定标识。
    ///
    /// 只读，不会改动任何数据。
    static func listNotes(inFolder folder: String?,
                          includeBodyLength: Bool = false) async throws -> [AppleNote] {
        let script = makeListScript(folderFilter: folder,
                                    titleFilter: nil,
                                    includeBodyLength: includeBodyLength)
        let raw = try await runClassified(script, context: "列出笔记")
        return parseAppleNotes(raw)
    }

    /// 按标题精确查找笔记，用于导入后回读配对。
    ///
    /// 「备忘录」的 `name` 由笔记正文首行推导而来，所以这里对 `name` 做区分大小写的精确比较。
    /// `includeBodyLength` 默认关闭，原因同 `listNotes`。只读，不会改动任何数据。
    static func findNoteIDsByTitle(_ title: String,
                                   inFolder folder: String? = nil,
                                   includeBodyLength: Bool = false) async throws -> [AppleNote] {
        let script = makeListScript(folderFilter: folder,
                                    titleFilter: title,
                                    includeBodyLength: includeBodyLength)
        let raw = try await runClassified(script, context: "按标题查找笔记")
        return parseAppleNotes(raw)
    }

    // MARK: - 只读：正文

    /// 取某条笔记的正文（HTML）。
    ///
    /// - Parameter id: 笔记的内部 id（形如 `x-coredata://…`）。
    ///
    /// 注意：返回值会被 `NotesBridge.run` 去掉首尾空白与换行，对 HTML 而言无实质影响。
    /// 只读，不会改动任何数据。
    static func noteBody(id: String) async throws -> String {
        let script = """
        tell application "Notes"
            return body of note id "\(escapeForAppleScript(id))"
        end tell
        """
        return try await runClassified(script, context: "读取笔记正文")
    }

    // MARK: - 写操作（会修改用户的备忘录）

    /// ⚠️ **写操作**：直接覆盖「备忘录」中指定笔记的正文，不可撤销。
    ///
    /// 这是「通道二」的核心——已经导入过、但在小米端被修改过的笔记，用这个方式原地更新。
    /// 只允许对已经建立映射、且确认过归属的笔记 id 调用；不要拿它去改用户手写的笔记。
    ///
    /// 实现上把 HTML 先写到临时文件、再由 AppleScript `read` 读入：正文往往很长，
    /// 直接嵌进 osascript 命令行参数会撞长度上限，走文件可以完全绕开这个问题。
    ///
    /// - Parameters:
    ///   - id: 目标笔记的内部 id。
    ///   - html: 新的正文，HTML 片段。
    static func setBody(id: String, html: String) async throws {
        let tmp = try writeTempHTML(html)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let script = """
        set f to POSIX file "\(escapeForAppleScript(tmp.path))"
        set theHTML to read f as «class utf8»
        tell application "Notes"
            set body of note id "\(escapeForAppleScript(id))" to theHTML
        end tell
        """
        _ = try await runClassified(script, context: "覆盖笔记正文")
    }

    /// ⚠️ **写操作**：在「备忘录」中新建一个文件夹，不可撤销（本函数不提供删除）。
    ///
    /// - Parameter name: 文件夹名。
    /// - Returns: 新文件夹的 id。
    ///
    /// **幂等**：若已存在同名文件夹，「备忘录」会报错 `重复的文件夹名称 (-10000)`；
    /// 此时不抛错，而是回查该文件夹的 id 直接复用。这样调用方不必先查后建，
    /// 也天然避免了同名文件夹越建越多。
    ///
    /// 实测（2026-10-15, macOS 27）：新建的文件夹落在「备忘录」账户根层，
    /// 与 ENEX 导入笔记所去的「导入的备忘录」同属一个账户。
    static func createFolder(named name: String) async throws -> String {
        let script = """
        tell application "Notes"
            set newFolder to make new folder with properties {name:"\(escapeForAppleScript(name))"}
            return (id of newFolder) as string
        end tell
        """
        do {
            let id = try await runClassified(script, context: "新建文件夹")
            guard !id.isEmpty else {
                throw NotesImportError.invalidData("新建文件夹后没有取回 id")
            }
            return id
        } catch NotesImportError.scriptError(let msg)
                    where msg.contains("重复的文件夹名称") || msg.contains("-10000") {
            if let existing = try await listFoldersWithIDs().first(where: { $0.name == name }) {
                return existing.id
            }
            throw NotesImportError.scriptError(msg)
        }
    }

    /// ⚠️ **写操作**：把「备忘录」中的一条笔记移动到指定文件夹，不可撤销。
    ///
    /// - Parameters:
    ///   - id: 目标笔记的内部 id（形如 `x-coredata://…/ICNote/pNNN`）。用 id 定位而非标题，
    ///     避免同名笔记歧义。
    ///   - folder: 目标文件夹名。需已存在（先用 `createFolder(named:)` 确保）。
    ///
    /// 实测（2026-10-15, macOS 27）：移动**不会改变笔记的 id**，也**不影响正文**，
    /// 因此可以在配对建立映射之后放心移动。
    static func moveNote(id: String, toFolder folder: String) async throws {
        let script = """
        tell application "Notes"
            move note id "\(escapeForAppleScript(id))" to folder "\(escapeForAppleScript(folder))"
        end tell
        """
        _ = try await runClassified(script, context: "移动笔记到文件夹")
    }

    /// ⚠️ **写操作**：在「备忘录」中新建一条笔记，不可撤销。
    ///
    /// - Parameters:
    ///   - folder: 目标文件夹名；传 `nil` 时由「备忘录」放入默认位置。
    ///   - html: 笔记正文，HTML 片段。
    /// - Returns: 新建笔记的内部 id。
    ///
    /// 与 `setBody` 相同，正文经临时文件传入，避免命令行参数长度限制。
    static func createNote(folder: String?, html: String) async throws -> String {
        let tmp = try writeTempHTML(html)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let makeLine: String
        if let folder {
            makeLine = "set newNote to make new note at folder \"\(escapeForAppleScript(folder))\" with properties {body:theHTML}"
        } else {
            makeLine = "set newNote to make new note with properties {body:theHTML}"
        }

        let script = """
        set f to POSIX file "\(escapeForAppleScript(tmp.path))"
        set theHTML to read f as «class utf8»
        tell application "Notes"
            \(makeLine)
            return id of newNote
        end tell
        """
        let id = try await runClassified(script, context: "新建笔记")
        guard !id.isEmpty else {
            throw NotesImportError.invalidData("新建笔记后没有取回 id")
        }
        return id
    }

    // MARK: - AppleScript 组装

    /// 生成「遍历一批笔记、按 RS/US 拼接成一条字符串返回」的脚本。
    ///
    /// **文件夹的取法（实测修正）**：脚本改为「外层遍历文件夹、内层遍历笔记」，
    /// 直接把外层循环变量当成这条笔记的文件夹名。
    ///
    /// 原因是 2026-10-14 在 macOS 27 上实测发现：`name of container of n` 与
    /// `name of folder of n` 都返回空字符串，而 `notes of folder` 完全正常。
    /// 也就是说从「笔记」这一侧反查文件夹在本版本上不可靠，从「文件夹」这一侧正查才是稳的。
    ///
    /// - Parameters:
    ///   - folderFilter: 非 nil 时只遍历该文件夹。
    ///   - titleFilter: 非 nil 时只保留 `name` 与之精确相等的笔记（区分大小写）。
    ///   - includeBodyLength: 是否逐条读取 `body` 以取得长度。
    ///     这是整个脚本里**唯一昂贵的操作**——AppleScript 每取一次 `body` 都要跨进程往返，
    ///     1000 条笔记可能要几十秒。因此默认关闭，只在确实需要时打开。
    ///
    /// 每条记录格式固定为：`id US name US folder US created US modified US bodyLength RS`。
    /// 其它关键点：
    /// - `id of n` 必须取到，它是后续 `setBody(id:)` 定位笔记的唯一钥匙；
    /// - 日期由脚本里的 `isoLocal` 处理器拼成固定格式，避免受系统区域设置影响；
    /// - 每项的取值都包在 `try` 里，单条笔记取不到字段时降级为空串，不连累整批。
    private static func makeListScript(folderFilter: String?,
                                       titleFilter: String?,
                                       includeBodyLength: Bool) -> String {
        let appendLine = "set outStr to outStr & theId & US & theName & US & theFolder & US & theCreated & US & theModified & US & theLenStr & RS"

        let emitBlock: String
        if let titleFilter {
            emitBlock = """
                        considering case
                            if theName is "\(escapeForAppleScript(titleFilter))" then
                                \(appendLine)
                            end if
                        end considering
            """
        } else {
            emitBlock = "        \(appendLine)"
        }

        // 只在需要时才把「读 body」这段塞进脚本
        let lengthBlock: String
        if includeBodyLength {
            lengthBlock = """
                        set theLenStr to "0"
                        try
                            set theLenStr to (length of (body of n)) as string
                        end try
            """
        } else {
            lengthBlock = "        set theLenStr to \"0\""
        }

        // 指定文件夹时，只对该文件夹生效
        let folderGuard: String
        if let folderFilter {
            folderGuard = """
                    if fName is "\(escapeForAppleScript(folderFilter))" then
            """
        } else {
            folderGuard = "        if true then"
        }

        return """
        on isoLocal(d)
            set mo to (month of d) as integer
            set dy to day of d
            set hh to hours of d
            set mi to minutes of d
            set ss to seconds of d
            if mo < 10 then
                set moS to "0" & (mo as string)
            else
                set moS to mo as string
            end if
            if dy < 10 then
                set dyS to "0" & (dy as string)
            else
                set dyS to dy as string
            end if
            if hh < 10 then
                set hhS to "0" & (hh as string)
            else
                set hhS to hh as string
            end if
            if mi < 10 then
                set miS to "0" & (mi as string)
            else
                set miS to mi as string
            end if
            if ss < 10 then
                set ssS to "0" & (ss as string)
            else
                set ssS to ss as string
            end if
            return ((year of d) as integer as string) & "-" & moS & "-" & dyS & "T" & hhS & ":" & miS & ":" & ssS
        end isoLocal

        set US to (character id 31)
        set RS to (character id 30)
        set outStr to ""
        tell application "Notes"
            repeat with f in folders
                set fName to ""
                try
                    set fName to (name of f) as string
                end try
        \(folderGuard)
                    repeat with n in notes of f
                        set theId to ""
                        try
                            set theId to (id of n) as string
                        end try
                        set theName to ""
                        try
                            set theName to (name of n) as string
                        end try
                        set theFolder to fName
                        set theCreated to ""
                        try
                            set theCreated to my isoLocal(creation date of n)
                        end try
                        set theModified to ""
                        try
                            set theModified to my isoLocal(modification date of n)
                        end try
        \(lengthBlock)
        \(emitBlock)
                    end repeat
                end if
            end repeat
        end tell
        return outStr
        """
    }

    /// 把 AppleScript 返回的 RS/US 记录串解析成 `AppleNote` 数组。
    private static func parseAppleNotes(_ raw: String) -> [AppleNote] {
        guard !raw.isEmpty else { return [] }
        var result: [AppleNote] = []
        for record in raw.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            let fields = record
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            // 正常是 6 个字段；字段数不对说明这条记录损坏，跳过而不是让整批失败。
            guard fields.count >= 6 else { continue }
            result.append(AppleNote(
                id: fields[0],
                name: fields[1],
                folder: fields[2],
                created: isoLocalFormatter.date(from: fields[3]),
                modified: isoLocalFormatter.date(from: fields[4]),
                bodyLength: Int(fields[5]) ?? 0
            ))
        }
        return result
    }

    // MARK: - 转义与临时文件

    /// 把 Swift 字符串安全地嵌进 AppleScript 字符串字面量。
    ///
    /// AppleScript 字符串用双引号包裹，反斜杠是转义前导符，所以只有两个字符必须处理：
    /// - `\` → `\\`
    /// - `"` → `\"`
    ///
    /// 顺序上逐字符扫描天然正确（先处理反斜杠再处理引号不会互相污染）。
    /// HTML 正文里几乎必然出现双引号（如 `<div style="…">`），转义漏一处就会直接语法错误，
    /// 因此凡是把外部文本拼进脚本的地方都必须经过本函数。
    private static func escapeForAppleScript(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for ch in s {
            switch ch {
            case "\\":
                out += "\\\\"
            case "\"":
                out += "\\\""
            default:
                out.append(ch)
            }
        }
        return out
    }

    /// 把大段 HTML 写到临时文件并返回路径。
    ///
    /// 之所以不把正文直接拼进脚本：osascript 是通过命令行参数（`-e`）接收脚本的，
    /// 参数长度有上限，而笔记正文动辄几十上百 KB，直接嵌入会被截断或直接报参数过长。
    /// 写到临时文件后，脚本里只留一条短短的路径，再用 `read … as «class utf8»` 把内容读进来。
    private static func writeTempHTML(_ html: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minotebridge-\(UUID().uuidString).html")
        guard let data = html.data(using: .utf8) else {
            throw NotesImportError.tempFileIO("正文无法以 UTF-8 编码")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw NotesImportError.tempFileIO(error.localizedDescription)
        }
        return url
    }

    // MARK: - 执行与错误分类

    /// 统一入口：交给 `NotesBridge.run` 执行，并把底层错误翻译成 `NotesImportError`。
    private static func runClassified(_ script: String, context: String) async throws -> String {
        do {
            return try await NotesBridge.run(script)
        } catch let e as NotesBridgeError {
            throw classify(e)
        } catch {
            throw NotesImportError.scriptError("\(context)：\(error.localizedDescription)")
        }
    }

    /// 把 `NotesBridgeError` 映射成更具体的 `NotesImportError`。
    ///
    /// 已知的 AppleScript 错误码：
    /// - `-1743` 无自动化权限
    /// - `-600`  目标进程（备忘录）未运行
    /// - `-1728` 找不到对象（文件夹或笔记 id 不存在）
    /// - `-1708` 事件不被支持（版本差异）
    private static func classify(_ error: NotesBridgeError) -> NotesImportError {
        switch error {
        case .notAuthorized:
            return .notAuthorized
        case .scriptFailed(let msg):
            if let code = extractErrorCode(msg) {
                switch code {
                case -1743: return .notAuthorized
                case -600: return .notesNotRunning
                case -1728: return .objectNotFound(msg)
                case -1708: return .commandNotHandled(msg)
                default: break
                }
            }
            if msg.localizedCaseInsensitiveContains("Not authorized")
                || msg.localizedCaseInsensitiveContains("not allowed assistive")
                || msg.localizedCaseInsensitiveContains("没有权限") {
                return .notAuthorized
            }
            if msg.localizedCaseInsensitiveContains("isn't running")
                || msg.localizedCaseInsensitiveContains("not running") {
                return .notesNotRunning
            }
            return .scriptError(msg)
        }
    }

    /// 从 AppleScript 报错文本里抠出括号中的数字错误码，例如 `… (-1728)` → -1728。
    private static func extractErrorCode(_ message: String) -> Int? {
        let pattern = "\\(\\s*(-?[0-9]{3,5})\\s*\\)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = re.firstMatch(in: message, options: [], range: range),
              match.numberOfRanges >= 2,
              let codeRange = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return Int(message[codeRange])
    }
}
