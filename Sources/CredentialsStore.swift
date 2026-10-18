import Foundation

enum CredentialsStore {

    static let appFolderName = "MiNoteBridge"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    private static var cookieURL: URL { directory.appendingPathComponent("credentials.json") }

    private struct Payload: Codable {
        var cookie: String
        var savedAt: Date
    }

    @discardableResult
    static func ensureDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])

            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
            return true
        } catch {
            return false
        }
    }

    static func saveCookie(_ cookie: String) throws {
        _ = ensureDirectory()
        let data = try JSONEncoder().encode(Payload(cookie: cookie, savedAt: Date()))
        try data.write(to: cookieURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: cookieURL.path)
    }

    static func loadCookie() -> String? {
        guard let data = try? Data(contentsOf: cookieURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.cookie.isEmpty
        else { return nil }
        return payload.cookie
    }

    static func clearCookie() {
        try? FileManager.default.removeItem(at: cookieURL)
    }

    static func cookieFilePermission() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cookieURL.path),
              let mode = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return String(format: "%03o", mode.intValue)
    }
}
