import SwiftUI
import AppKit

struct PermissionStepView: View {
    let onContinue: () -> Void

    enum Phase: Equatable {
        case checking
        case notYetAsked
        case awaitingSystemDialog
        case granted
        case denied
        case notCompleted
        case systemAppMissing
        case unknown(OSStatus)

        var isBusy: Bool { self == .checking || self == .awaitingSystemDialog }
        var isGranted: Bool { self == .granted }
    }

    @State private var phase: Phase = .checking

    var body: some View {
        VStack(spacing: 0) {
            DSScreenHeader(
                title: "授权「备忘录」",
                subtitle: "接下来 macOS 会询问是否允许米记桥控制「备忘录」。本应用只用它做下面三件事。"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    usesCard
                    DSStatusBar(
                        icon: icon,
                        tint: tint,
                        title: title,
                        detail: detail,
                        busy: phase.isBusy
                    )
                    if phase == .awaitingSystemDialog { dialogHint }
                    if phase == .denied || phase == .notCompleted { manualHelp }
                }
                .padding(.horizontal, DS.Space.screen)
                .padding(.bottom, DS.Space.s)
            }

            Divider()

            DSFooter(note: "没有这项权限，导入仍可进行，但上面三项功能会不可用。") {
                if phase.isGranted {
                    Button("继续") { onContinue() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("暂不授权") { onContinue() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(phase == .awaitingSystemDialog)

                    Button(primaryTitle) { request() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(phase.isBusy)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .task { await refresh() }
    }

    private var usesCard: some View {
        DSCard(title: "这项权限的用途", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                DSBulletRow(icon: "checkmark.seal",
                            title: "核验导入结果",
                            detail: "导入完成后数一遍「导入的备忘录」里的条数，确认真的写进去了，而不是假设成功。")
                DSBulletRow(icon: "link",
                            title: "建立笔记对应关系",
                            detail: "记住备忘录里的哪一条对应小米里的哪一条，下次同步才不会重复导入。")
                DSBulletRow(icon: "arrow.triangle.2.circlepath",
                            title: "同步已修改的笔记",
                            detail: "你在小米端改过一条已导入的笔记时，用它更新备忘录里的那一条。")
            }
        }
    }

    private var icon: String {
        switch phase {
        case .checking, .awaitingSystemDialog: return "clock"
        case .notYetAsked: return "questionmark.circle.fill"
        case .granted: return "checkmark.circle.fill"
        case .denied, .notCompleted: return "xmark.circle.fill"
        case .systemAppMissing, .unknown: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .checking: return DS.Status.idle
        case .awaitingSystemDialog: return DS.Status.warn
        case .notYetAsked: return DS.Status.warn
        case .granted: return DS.Status.ok
        case .denied, .notCompleted: return DS.Status.bad
        case .systemAppMissing, .unknown: return DS.Status.warn
        }
    }

    private var title: String {
        switch phase {
        case .checking: return "正在检测授权状态…"
        case .notYetAsked: return "尚未授权"
        case .awaitingSystemDialog: return "等待你在系统弹窗中作出选择"
        case .granted: return "已获得授权"
        case .denied: return "授权已被拒绝"
        case .notCompleted: return "授权没有完成"
        case .systemAppMissing: return "无法启动「备忘录」"
        case .unknown(let code): return "状态未知（错误码 \(code)）"
        }
    }

    private var detail: String? {
        switch phase {
        case .checking:
            return "正在确认你此前是否已经授权过。"
        case .notYetAsked:
            return "点「授权」后，macOS 会弹出系统对话框询问你。"
        case .awaitingSystemDialog:
            return "已向 macOS 发出授权请求。请在弹出的对话框中选择「允许」或「不允许」。"
                + "选择后这里会自动更新。"
        case .granted:
            return "三项功能均已可用。"
        case .denied:
            return "系统已记住你的拒绝。可按下面的方式手动开启，然后点「重新检测」。"
        case .notCompleted:
            return "请求已经发出，但系统没有给出结果——通常意味着弹窗被取消了。"
                + "可按下面的方式手动开启，或再点一次「重新检测」。"
        case .systemAppMissing:
            return "请确认这台 Mac 上已安装「备忘录」应用。"
        case .unknown:
            return "可点「重新检测」，或到系统设置中手动检查。"
        }
    }

    private var primaryTitle: String {
        switch phase {
        case .checking: return "检测中…"
        case .awaitingSystemDialog: return "等待你的选择…"
        case .notYetAsked: return "授权"
        default: return "重新检测"
        }
    }

    private var dialogHint: some View {
        DSCard(title: "没看到弹窗？", icon: "questionmark.circle") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("macOS 的授权对话框有时会出现在其它窗口后面。请按 ⌘+Tab 切换到"
                     + "「米记桥」，或直接到系统设置里手动勾选。")
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开系统设置手动勾选") { NotesBridge.openAutomationSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var manualHelp: some View {
        DSCard(title: "手动开启的方法", icon: "gearshape") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("系统设置 → 隐私与安全性 → 自动化 → 找到「米记桥」→ 勾选「备忘录」。")
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开系统设置") { NotesBridge.openAutomationSettings() }
                    .controlSize(.small)
            }
        }
    }

    private func request() {

        NSApp.activate(ignoringOtherApps: true)
        phase = .awaitingSystemDialog
        Task {
            _ = await NotesBridge.ensureNotesRunning()
            let result = await NotesBridge.requestAutomationAccess()
            phase = classify(result, asked: true)
        }
    }

    private func refresh() async {
        phase = .checking

        try? await Task.sleep(nanoseconds: 250_000_000)

        let status = NotesBridge.automationStatus(askUser: false)
        if status == .targetNotRunning {
            phase = .systemAppMissing
            return
        }
        phase = classify(status, asked: false)
    }

    private func classify(_ status: AutomationStatus, asked: Bool) -> Phase {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return asked ? .notCompleted : .notYetAsked
        case .targetNotRunning: return .systemAppMissing
        case .unknown(let code): return .unknown(code)
        }
    }
}
