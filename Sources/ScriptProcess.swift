import Foundation
import Darwin

/// 自动化进程在后台等待；输出写入文件，避免 stdout/stderr 管道互相阻塞。
final class ScriptProcess: @unchecked Sendable {
    struct Output { let status: Int32; let stdout: String; let stderr: String }
    enum Failure: LocalizedError {
        case timedOut, cancelled
        var errorDescription: String? {
            switch self {
            case .timedOut: return "外部操作响应超时，请检查备忘录是否有待确认的窗口。"
            case .cancelled: return "操作已取消。"
            }
        }
    }
    private let lock = NSLock()
    private var process: Process?
    private var failure: Failure?

    static func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Output {
        let execution = ScriptProcess()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try execution.run(executable, arguments, timeout)) }
                    catch Failure.cancelled { continuation.resume(throwing: CancellationError()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { execution.stop(.cancelled) }
    }

    private func stop(_ reason: Failure) {
        lock.lock()
        if failure == nil { failure = reason }
        let running = process
        if let running, running.isRunning { running.terminate() }
        lock.unlock()
        // 某些自动化进程不响应 SIGTERM，仍须保证超时/取消能结束等待。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            lock.lock(); defer { lock.unlock() }
            if let running = process, running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    private func run(_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) throws -> Output {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minote-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout"), errURL = directory.appendingPathComponent("stderr")
        try Data().write(to: outURL); try Data().write(to: errURL)
        let stdout = try FileHandle(forWritingTo: outURL), stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdout.close(); try? stderr.close() }
        let child = Process()
        child.executableURL = executable; child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout; child.standardError = stderr
        lock.lock()
        if let failure { lock.unlock(); throw failure }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        let timeoutWork = DispatchWorkItem { [weak self] in self?.stop(.timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout), execute: timeoutWork)
        child.waitUntilExit()
        timeoutWork.cancel()
        lock.lock()
        let reason = failure
        process = nil
        lock.unlock()
        if let reason { throw reason }
        return Output(status: child.terminationStatus,
                      stdout: String(decoding: try Data(contentsOf: outURL), as: UTF8.self),
                      stderr: String(decoding: try Data(contentsOf: errURL), as: UTF8.self))
    }
}
