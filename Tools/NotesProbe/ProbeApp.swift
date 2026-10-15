import SwiftUI
import AppKit

// 探针 6：补充验证
//  - 同名文件夹重复创建的行为（新建还是报错还是复用）
//  - 嵌套文件夹的几种语法变体（探针 5 用变量名 parent 触发了保留字冲突）
// 安全：只自建自测，不删除任何东西。

@MainActor
final class ProbeModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var finished = false
    private var report: [String: Any] = [:]

    func log(_ s: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("[\(ts)] \(s)")
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func run(_ script: String, _ label: String) async -> (ok: Bool, out: String, err: String) {
        do { return (true, try await NotesBridge.run(script), "") }
        catch { log("  ⚠️ \(label)：\(error.localizedDescription)"); return (false, "", error.localizedDescription) }
    }

    private func countFoldersNamed(_ name: String) async -> Int {
        let (ok, out, _) = await run("""
        tell application "Notes"
            set c to 0
            repeat with f in folders
                try
                    if (name of f as string) is "\(esc(name))" then set c to c + 1
                end try
            end repeat
            return c as string
        end tell
        """, "计数同名文件夹")
        if !ok { return -1 }
        return Int(out) ?? -1
    }

    func run() async {
        log("探针 6：同名文件夹 + 嵌套变体。")
        guard await NotesBridge.ensureNotesRunning(),
              NotesBridge.automationStatus(askUser: true) == .authorized else {
            log("❌ 未就绪/未授权"); finish(); return
        }

        // ── A. 同名重复创建 ──
        let dup = "MiNoteBridge 重复测试"
        log("")
        log("═══ A. 同名文件夹：「\(dup)」 ═══")
        let n0 = await countFoldersNamed(dup)
        log("  创建前同名数：\(n0)")
        let a1 = await run("""
        tell application "Notes"
            set f to make new folder with properties {name:"\(esc(dup))"}
            return (id of f) as string
        end tell
        """, "同名创建 #1")
        log("  第 1 次 ok=\(a1.ok) id 尾=\(a1.out.isEmpty ? "空" : String(a1.out.suffix(16)))")
        let a2 = await run("""
        tell application "Notes"
            set f to make new folder with properties {name:"\(esc(dup))"}
            return (id of f) as string
        end tell
        """, "同名创建 #2")
        log("  第 2 次 ok=\(a2.ok) id 尾=\(a2.out.isEmpty ? "空" : String(a2.out.suffix(16)))")
        let n1 = await countFoldersNamed(dup)
        log("  创建两次后同名数：\(n1)（同名 id 是否相同：\(a1.out == a2.out)）")
        report["dup"] = ["create1_ok": a1.ok, "create2_ok": a2.ok,
                         "id1": a1.out, "id2": a2.out,
                         "sameId": a1.out == a2.out,
                         "countBefore": n0, "countAfter": n1,
                         "err2": a2.err]

        // ── B. 按名字取已存在文件夹的 id（复用路径） ──
        log("")
        log("═══ B. 按名字取已有文件夹 id ═══")
        let lookup = await run("""
        tell application "Notes"
            repeat with f in folders
                try
                    if (name of f as string) is "\(esc("MiNoteBridge 测试文件夹"))" then
                        return (id of f) as string
                    end if
                end try
            end repeat
            return ""
        end tell
        """, "按名取 id")
        log("  查到「MiNoteBridge 测试文件夹」id=\(lookup.out.isEmpty ? "（无）" : String(lookup.out.suffix(20)))")
        report["lookupById"] = lookup.out

        // ── C. 嵌套变体 ──
        log("")
        log("═══ C. 嵌套文件夹语法变体 ═══")
        let parentName = "MiNoteBridge 测试文件夹"
        let variants: [(String, String)] = [
            ("var:nested", """
            tell application "Notes"
                set theParent to folder "\(esc(parentName))"
                set newSub to make new folder at theParent with properties {name:"MiNoteBridge 子A"}
                return (id of newSub) as string
            end tell
            """),
            ("direct", """
            tell application "Notes"
                set newSub to make new folder at folder "\(esc(parentName))" with properties {name:"MiNoteBridge 子B"}
                return (id of newSub) as string
            end tell
            """),
            ("in", """
            tell application "Notes"
                set newSub to make new folder in folder "\(esc(parentName))" with properties {name:"MiNoteBridge 子C"}
                return (id of newSub) as string
            end tell
            """),
        ]
        for (label, script) in variants {
            let r = await run(script, "嵌套-\(label)")
            log("  [\(label)] ok=\(r.ok) id 尾=\(r.out.isEmpty ? "空" : String(r.out.suffix(16)))")
            if !r.ok { log("     err=\(r.err)") }
            report["nest_" + label] = ["ok": r.ok, "id": r.out, "err": r.err]
        }

        // 建完后总文件夹数，看看嵌套是否真的进了 folders 列表
        let (okAll, allOut, _) = await run("""
        set US to (character id 31)
        set outStr to ""
        tell application "Notes"
            repeat with f in folders
                set nv to ""
                try
                    set nv to (name of f as string)
                end try
                set outStr to outStr & nv & US
            end repeat
        end tell
        return outStr
        """, "列全部文件夹名")
        log("  当前全部文件夹：\(okAll ? allOut : "（失败）")")
        report["allFolderNames"] = allOut

        log("")
        log("✅ 探针 6 完成")
        finish()
    }

    private func finish() {
        var payload = report
        payload["log"] = lines
        if let d = try? JSONSerialization.data(withJSONObject: payload,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? d.write(to: URL(fileURLWithPath: "/tmp/minotes_probe6.json"))
        }
        finished = true
    }
}

struct ProbeView: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !model.finished { ProgressView().controlSize(.small) }
                Text(model.finished ? "完成" : "正在测试…").font(.system(size: 14, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(12)
            }
            if model.finished {
                Divider()
                HStack {
                    Button("打开报告") { NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/minotes_probe6.json")) }
                    Button("退出") { NSApp.terminate(nil) }
                }.padding(14)
            }
        }
    }
}

@main
struct ProbeApp: App {
    @StateObject private var model = ProbeModel()
    var body: some Scene {
        WindowGroup("米记桥 · 文件夹补充测试") {
            ProbeView(model: model).frame(width: 820, height: 620).task { await model.run() }
        }
        .windowResizability(.contentSize)
    }
}
