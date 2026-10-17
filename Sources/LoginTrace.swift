import Foundation

/// 登录链路的诊断日志。
///
/// 只在设置了环境变量 `MINB_LOGIN_TRACE=1` 时生效，把每一步追加到
/// `/tmp/minb_login.log`。做法照 `LayoutProbe`：登录这类必须靠人来回操作
/// 才能复现的问题，猜没有用，得拿到真实的时间线与错误原文。
///
/// 用法：
/// ```
/// MINB_LOGIN_TRACE=1 ./build/MiNoteBridge.app/Contents/MacOS/MiNoteBridge
/// tail -f /tmp/minb_login.log
/// ```
///
/// **绝不记录 Cookie 内容、账号、密码**——只记步骤、耗时和错误描述。
/// 凭证这类东西一旦写进日志文件，就等于把它从 0600 的凭证文件里搬了出来。
enum LoginTrace {

    static let enabled = ProcessInfo.processInfo.environment["MINB_LOGIN_TRACE"] == "1"

    private static let url = URL(fileURLWithPath: "/tmp/minb_login.log")

    /// 时间戳格式器。
    ///
    /// **刻意每次新建，不用 static 缓存**：`DateFormatter` 不是线程安全的，
    /// 而 `log` 会被主线程（视图）和后台线程（轮询 Task）同时调用。
    /// 日志量只有几十条，这点开销远小于一次并发格式化引发的崩溃/乱码。
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

    /// 轮询结果的**安全**描述：只报状态名，成功时只报凭证长度。
    static func describe(_ outcome: MiLoginOutcome) -> String {
        switch outcome {
        // 不能写成"还没扫码"：`.waiting` 同时来自超时、408/504、以及连接抖动。
        // 用户明明扫过了、日志却写"还没扫码"，排查时会被直接带偏。
        case .waiting:
            return "waiting（无变化/未确认/连接抖动）"
        case .unexpected(let why):
            return "unexpected（\(why)）"
        case .succeeded(let cookie):
            // 只记长度，不记内容。用 utf8.count 而不是 count：
            // 后者是字符数，作为"有多大"的指标会偏小且不稳定。
            return "succeeded（凭证 \(cookie.utf8.count) 字节）"
        }
    }
}
