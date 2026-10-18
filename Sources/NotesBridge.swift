import Foundation
import AppKit
import Carbon

enum NotesBridgeError: LocalizedError {
    case notAuthorized
    case scriptFailed(String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "尚未获得「备忘录」的自动化权限。"
        case .scriptFailed(let msg): return "AppleScript 执行失败：\(msg)"
        case .timedOut(let seconds): return "「备忘录」在 \(Int(seconds)) 秒内没有响应。请先关闭备忘录中的导入确认或其他弹窗，再重试；若已导入，请先核对结果，避免重复导入。"
        }
    }
}

enum AutomationStatus: Equatable {
    case authorized
    case denied
    case notDetermined
    case targetNotRunning
    case unknown(OSStatus)
}

enum NotesBridge {

    static let notesBundleID = "com.apple.Notes"

    private static let errAEEventNotPermitted: OSStatus = -1743
    private static let errAEEventWouldRequireUserConsent: OSStatus = -1744
    private static let procNotFound: OSStatus = -600

    static func automationStatus(askUser: Bool) -> AutomationStatus {

        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).isEmpty
        if !running && !askUser {
            return .targetNotRunning
        }

        var target = AEAddressDesc()
        let bundleBytes: [UInt8] = Array(notesBundleID.utf8)

        let created: OSErr = bundleBytes.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt8>) -> OSErr in
            AECreateDesc(typeApplicationBundleID, buf.baseAddress, buf.count, &target)
        }
        guard created == noErr else { return .unknown(OSStatus(created)) }
        defer { AEDisposeDesc(&target) }

        let cls = AEEventClass(0x2A2A2A2A)
        let eid = AEEventID(0x2A2A2A2A)
        let status = AEDeterminePermissionToAutomateTarget(&target, cls, eid, askUser)

        switch status {
        case noErr: return .authorized
        case errAEEventNotPermitted: return .denied
        case errAEEventWouldRequireUserConsent: return .notDetermined
        case procNotFound: return .targetNotRunning
        default: return .unknown(status)
        }
    }

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

    static func requestAutomationAccess() async -> AutomationStatus {
        await Task.detached(priority: .userInitiated) {
            automationStatus(askUser: true)
        }.value
    }

    static func openAutomationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
        ]
        for s in candidates {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    static func run(_ script: String, timeout: TimeInterval = 30) async throws -> String {
        let result: ScriptProcess.Output
        do {
            result = try await ScriptProcess.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                                 arguments: ["-e", script], timeout: timeout)
        } catch ScriptProcess.Failure.timedOut { throw NotesBridgeError.timedOut(timeout) }
        catch ScriptProcess.Failure.cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw NotesBridgeError.scriptFailed(error.localizedDescription) }
        let outStr = result.stdout, errStr = result.stderr
        guard result.status == 0 else {
            if errStr.contains("-1743") || errStr.localizedCaseInsensitiveContains("Not authorized") {
                throw NotesBridgeError.notAuthorized
            }
            let detail = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NotesBridgeError.scriptFailed(detail.isEmpty ? "退出码 \(result.status)" : detail)
        }
        return outStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
