import Foundation

struct NoteRecord: Codable {

    var noteId: String

    var modifyDate: Double

    var appleId: String?

    var bodyHash: String?

    var title: String?
    var snippet: String?

    var aiModified: Bool?

    var trashed: Bool?

    var status: Status

    enum Status: String, Codable {
        case synced
        case pending
        case skipped
        case userDeleted
    }
}

struct PendingBatch: Codable {
    var file: String
    var noteIds: [String]
    var expectedCount: Int
    var createdAt: Date
}

struct SyncState: Codable {
    var version: Int = 1
    var lastSyncAt: Date?
    var notes: [String: NoteRecord] = [:]
    var pendingBatch: PendingBatch?
    var userDeleted: [String] = []
}

enum SyncStateStore {

    static var url: URL { CredentialsStore.directory.appendingPathComponent("state.json") }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return state
    }

    static func save(_ state: SyncState) throws {
        _ = CredentialsStore.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])

        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    static func reset() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum NoteDecision {
    case new
    case updated(newModifyDate: Double)
    case unchanged
    case knownDeleted
}

extension SyncState {

    func decide(noteId: String, modifyDate: Double) -> NoteDecision {
        if userDeleted.contains(noteId) { return .knownDeleted }
        guard let record = notes[noteId] else { return .new }
        if record.modifyDate == modifyDate { return .unchanged }
        return .updated(newModifyDate: modifyDate)
    }
}
