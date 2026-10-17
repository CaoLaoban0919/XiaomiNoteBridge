import Foundation
import AppKit
import Carbon

enum NotesBridgeError: LocalizedError {
    case notAuthorized
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "尚未获得「备忘录」的自动化权限。"
        case .scriptFailed(let msg): return "AppleScript 执行失败：\(msg)"
        }
    }
}

/// 自动化权限的四种状态
enum AutomationStatus: Equatable {
    case authorized
    case denied
    case notDetermined
    case targetNotRunning
    case unknown(OSStatus)
}

/// 与「备忘录」沟通的唯一出口。
enum NotesBridge {

    static let notesBundleID = "com.apple.Notes"

    // Carbon 的返回码
    private static let errAEEventNotPermitted: OSStatus = -1743
    private static let errAEEventWouldRequireUserConsent: OSStatus = -1744
    private static let procNotFound: OSStatus = -600

    // MARK: - 权限

    /// 查询（或请求）控制「备忘录」的自动化权限。
    ///
    /// 这里用的是系统原生的 `AEDeterminePermissionToAutomateTarget`，而不是跑一段
    /// AppleScript 去试探。原因有两个：
    /// 1. 它可以直接区分「尚未决定」和「已被拒绝」，AppleScript 试探做不到；
    /// 2. 授权弹窗会归属于本应用。若改用 `/usr/bin/osascript` 子进程发送 Apple 事件，
    ///    弹窗会显示成「"osascript" 想要控制"备忘录"」，用户根本不知道那是谁。
    ///
    /// - Parameter askUser: true 时若尚未决定会弹出系统授权对话框
    static func automationStatus(askUser: Bool) -> AutomationStatus {
        // **先纯本地判断目标是否在运行，绝不为了"查权限"去碰它。**
        //
        // `AEDeterminePermissionToAutomateTarget` 对**未运行**的目标行为不稳定：
        // 在部分系统版本 / 事件类组合下，它会去唤醒目标应用来完成权限判定，
        // 而「备忘录」一旦被唤醒就会自己 activate，把键盘焦点从本应用抢走。
        // 用户看到的就是「一启动就伴随备忘录打开、输入框打不进字」。
        //
        // 主界面、设置页、权限页三处 `.task` 调这里时都是 askUser == false，
        // 在这一层挡掉之后，**启动路径上不可能再发出任何 Apple Event**。
        // 只有用户主动点「授权」（askUser == true）时才允许 AE 去拉起它。
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).isEmpty
        if !running && !askUser {
            print("[NotesBridge] automationStatus: 未运行且未请求授权 → targetNotRunning（未发出任何 Apple Event）")
            return .targetNotRunning
        }

        var target = AEAddressDesc()
        let bundleBytes: [UInt8] = Array(notesBundleID.utf8)

        let created: OSErr = bundleBytes.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) -> OSErr in
            AECreateDesc(typeApplicationBundleID, buf.baseAddress, buf.count, &target)
        }
        guard created == noErr else { return .unknown(OSStatus(created)) }
        defer { AEDisposeDesc(&target) }

        let cls = AEEventClass(0x2A2A2A2A)   // '****'
        let eid = AEEventID(0x2A2A2A2A)      // '****'
        let status = AEDeterminePermissionToAutomateTarget(&target, cls, eid, askUser)
        print("[NotesBridge] automationStatus: running=\(running) askUser=\(askUser) → \(status)")

        switch status {
        case noErr: return .authorized
        case errAEEventNotPermitted: return .denied
        case errAEEventWouldRequireUserConsent: return .notDetermined
        case procNotFound: return .targetNotRunning
        default: return .unknown(status)
        }
    }

    /// 确保「备忘录」已启动——未启动时权限查询会返回 procNotFound
    static func ensureNotesRunning(timeout: TimeInterval = 6) async -> Bool {
        if automationStatus(askUser: false) != .targetNotRunning { return true }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notesBundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.addsToRecentItems = false
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                    cont.resume()
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if automationStatus(askUser: false) != .targetNotRunning { return true }
        }
        return false
    }

    /// 拉起系统授权流程，并在后台线程等待用户作出选择（避免阻塞界面）
    static func requestAutomationAccess() async -> AutomationStatus {
        await Task.detached(priority: .userInitiated) {
            automationStatus(askUser: true)
        }.value
    }

    /// 打开系统设置的「自动化」面板，方便用户手动勾选
    static func openAutomationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
        ]
        for s in candidates {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    // MARK: - 执行 AppleScript

    /// 通过 `/usr/bin/osascript` 子进程执行脚本。
    /// 取权限用上面的原生 API，这里只负责拿到权限之后真正干活的项目。
    static func run(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try runSync(script)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func runSync(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() }
        catch { throw NotesBridgeError.scriptFailed(error.localizedDescription) }

        // 先读空管道再等退出，避免写满导致死锁
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            if errStr.contains("-1743") || errStr.localizedCaseInsensitiveContains("Not authorized") {
                throw NotesBridgeError.notAuthorized
            }
            let detail = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NotesBridgeError.scriptFailed(detail.isEmpty ? "退出码 \(process.terminationStatus)" : detail)
        }
        return outStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
