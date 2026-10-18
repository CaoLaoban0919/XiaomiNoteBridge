import Foundation

struct CachedNote: Identifiable, Codable, Equatable {

    var id: String
    var title: String
    var snippet: String
    var folderId: String
    var folderName: String

    var createDate: Double
    var modifyDate: Double

    var fileIds: [String]

    var imageFileIds: [String]

    var hasBody: Bool

    var imported: Bool

    var appleId: String?

    var aiModified: Bool
}

struct CachedFolder: Identifiable, Codable, Equatable {
    var id: String
    var name: String

    var noteCount: Int
}

extension CachedNote {

    var plainSnippet: String {
        var s = snippet
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CachedNoteContent {
    var html: String

    var images: [String: Data]
}

struct PullProgress {
    enum Phase: Equatable {
        case idle
        case fetchingList
        case fetchingBodies
        case downloadingImages
        case finished
        case failed(String)
    }
    var phase: Phase = .idle
    var currentTitle: String?
    var completed = 0
    var total = 0
    var notesPulled = 0
    var imagesDownloaded = 0
    var imagesFailed = 0
}

struct ImportProgress {
    enum Phase: Equatable {
        case idle
        case preparing
        case writing
        case awaitingImport
        case organizingFolders
        case finished
        case failed(String)
    }
    var phase: Phase = .idle
    var currentTitle: String?
    var completed = 0
    var total = 0
}

protocol NoteCacheProtocol: AnyObject {

    func loadIndex() -> (notes: [CachedNote], folders: [CachedFolder])
    func saveIndex(notes: [CachedNote], folders: [CachedFolder]) throws

    func content(for noteId: String) -> CachedNoteContent?
    func saveContent(_ content: CachedNoteContent, for noteId: String) throws

    func saveHTML(_ html: String, for noteId: String) throws

    func saveOriginalIfAbsent(_ content: CachedNoteContent, for noteId: String) throws

    func originalContent(for noteId: String) -> String?

    func removeNote(id noteId: String) throws

    func imageData(fileId: String) -> Data?

    func clearAll() throws
}

@MainActor
protocol PullEngineProtocol: AnyObject {
    var progress: PullProgress { get }
    var logLines: [String] { get }
    var notes: [CachedNote] { get }
    var folders: [CachedFolder] { get }
    var isRunning: Bool { get }

    func reloadFromCache() async

    func pull() async

    func cancel()
}

enum ChangeKind: String, Codable {

    case create

    case moveToFolder

    case overwrite

    var label: String {
        switch self {
        case .create: return "新建"
        case .moveToFolder: return "归入文件夹"
        case .overwrite: return "覆盖正文"
        }
    }
}

enum ChangeRisk: String, Codable {
    case low
    case high
}

struct PlannedChange: Identifiable, Codable, Equatable {
    var id: String { noteId }

    var noteId: String
    var title: String
    var kind: ChangeKind
    var risk: ChangeRisk

    var targetFolder: String

    var preview: String

    var blockedReason: String?
}

struct ChangePlan {

    var creates: [PlannedChange] = []

    var moves: [PlannedChange] = []

    var overwrites: [PlannedChange] = []

    var total: Int { creates.count + moves.count + overwrites.count }
    var isEmpty: Bool { total == 0 }

    var needsApproval: [PlannedChange] {
        overwrites.filter { $0.blockedReason == nil }
    }

    var blocked: [PlannedChange] {
        (creates + moves + overwrites).filter { $0.blockedReason != nil }
    }
}

@MainActor
protocol ImportEngineProtocol: AnyObject {
    var progress: ImportProgress { get }
    var logLines: [String] { get }
    var isRunning: Bool { get }

    func plan(noteIds: [String]) -> ChangePlan

    func start(noteIds: [String], approvedOverwrites: Set<String>) async

    func cancel()
}
