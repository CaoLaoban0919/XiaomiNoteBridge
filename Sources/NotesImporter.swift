import Foundation

struct AppleNote: Sendable {
    var id: String
    var name: String
    var folder: String
    var created: Date?
    var modified: Date?
    var bodyLength: Int
}

struct AppleFolder: Sendable {
    var id: String
    var name: String
}

enum NotesImportError: LocalizedError {

    case notAuthorized

    case notesNotRunning

    case objectNotFound(String)

    case commandNotHandled(String)

    case invalidData(String)

    case tempFileIO(String)

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

enum NotesImporter {

    private static let fieldSeparator: Character = "\u{1F}"

    private static let recordSeparator: Character = "\u{1E}"

    private static let isoLocalFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

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

    static func listNotes(inFolder folder: String?,
                          includeBodyLength: Bool = false) async throws -> [AppleNote] {
        let script = makeListScript(folderFilter: folder,
                                    titleFilter: nil,
                                    includeBodyLength: includeBodyLength)
        let raw = try await runClassified(script, context: "列出笔记")
        return parseAppleNotes(raw)
    }

    static func findNoteIDsByTitle(_ title: String,
                                   inFolder folder: String? = nil,
                                   includeBodyLength: Bool = false) async throws -> [AppleNote] {
        let script = makeListScript(folderFilter: folder,
                                    titleFilter: title,
                                    includeBodyLength: includeBodyLength)
        let raw = try await runClassified(script, context: "按标题查找笔记")
        return parseAppleNotes(raw)
    }

    static func noteBody(id: String) async throws -> String {
        let script = """
        tell application "Notes"
            return body of note id "\(escapeForAppleScript(id))"
        end tell
        """
        return try await runClassified(script, context: "读取笔记正文")
    }

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

    static func insertImages(id: String, fileURLs: [URL]) async throws -> [String] {
        guard !fileURLs.isEmpty else { return [] }

        var cids: [String] = []
        for url in fileURLs {
            let script = """
            tell application "Notes"
                tell note id "\(escapeForAppleScript(id))"
                    set a to make new attachment with data POSIX file "\(escapeForAppleScript(url.path))"
                    return (content identifier of a) as string
                end tell
            end tell
            """
            let out = try await runClassified(script, context: "插入图片")
            cids.append(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return cids
    }

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

    static func moveNote(id: String, toFolder folder: String) async throws {
        let script = """
        tell application "Notes"
            move note id "\(escapeForAppleScript(id))" to folder "\(escapeForAppleScript(folder))"
        end tell
        """
        _ = try await runClassified(script, context: "移动笔记到文件夹")
    }

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

    private static func parseAppleNotes(_ raw: String) -> [AppleNote] {
        guard !raw.isEmpty else { return [] }
        var result: [AppleNote] = []
        for record in raw.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            let fields = record
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)

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

    private static func runClassified(_ script: String, context: String) async throws -> String {
        do {
            return try await NotesBridge.run(script)
        } catch let e as NotesBridgeError {
            throw classify(e)
        } catch {
            throw NotesImportError.scriptError("\(context)：\(error.localizedDescription)")
        }
    }

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
