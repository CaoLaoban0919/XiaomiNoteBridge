import Foundation

/// 本地凭证与状态存储。
///
/// 协议第 2B(i) 条承诺：登录凭证保存在 `~/Library/Application Support/MiNoteBridge/`，
/// 文件权限 `0600`。这里就是兑现那条承诺的地方——写入后立刻收紧权限，
/// 保证只有当前用户账户可读。
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
            // 上面那句的 attributes **只在新建目录时生效**；目录已存在时不会改权限。
            // 所以这里必须再显式收紧一次 —— 否则早先以 755 建出来的目录会一直留着，
            // 别的本地用户就能列出目录里的文件名（文件本身仍是 0600，内容读不到）。
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
            return true
        } catch {
            return false
        }
    }

    /// 保存登录凭证，并立刻把文件权限收紧到 0600
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

    /// 凭证文件的当前权限，用于「权限清单」页面如实展示
    static func cookieFilePermission() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cookieURL.path),
              let mode = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return String(format: "%03o", mode.intValue)
    }
}
