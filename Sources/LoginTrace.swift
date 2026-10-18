import Foundation

enum LoginTrace {

    static let enabled = ProcessInfo.processInfo.environment["MINB_LOGIN_TRACE"] == "1"

    private static let url = URL(fileURLWithPath: "/tmp/minb_login.log")

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    static func log(_ message: String) {
        guard enabled else { return }
        let line = "[\(stamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func describe(_ outcome: MiLoginOutcome) -> String {
        switch outcome {

        case .waiting:
            return "waiting（无变化/未确认/连接抖动）"
        case .unexpected(let why):
            return "unexpected（\(why)）"
        case .succeeded(let cookie):

            return "succeeded（凭证 \(cookie.utf8.count) 字节）"
        }
    }
}
