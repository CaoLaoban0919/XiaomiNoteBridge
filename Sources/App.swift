import SwiftUI

@main
struct MiNoteBridgeApp: App {
    @StateObject private var onboarding = OnboardingState()
    /// 编辑快捷键的中转（见 `Shortcuts.swift`）。
    /// 必须观察它：菜单项要跟着「有没有可编辑的正文」置灰，不能点了没反应。
    @StateObject private var shortcuts = EditorShortcuts.shared

    init() {
        // **防"能点不能打"的一道保险。**
        //
        // 用 Xcode / SwiftPM 直接运行时会产出一个**没有 .app 包、没有 Info.plist**
        // 的裸可执行文件，LaunchServices 把它判成 `BackgroundOnly`：
        // 窗口能显示、按钮能点（鼠标事件照常投递），但永远成不了 Key 应用，
        // 键盘事件进不来——所有 TextField 都"点得进去、打不进字"。
        //
        // 主动提升为普通前台应用，让裸二进制也能正常接收键盘。
        // 正常从 .app 启动时这行是无害的（本来就是 .regular）。
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("米记桥") {
            RootView()
                .environmentObject(onboarding)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: DS.mainWindowSize.width,
                     height: DS.mainWindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {}
            menuCommands
        }
    }

    // MARK: - 菜单

    /// 全部快捷键集中在这里。
    ///
    /// 放菜单而不是散在视图里，有三个好处：用户能在菜单栏看到、键位冲突只有一处、
    /// 将来加指令只需要改这一个文件。
    @CommandsBuilder
    private var menuCommands: some Commands {
        // **撤销 / 重做按焦点分流。**
        // 正文有焦点走编辑器的撤销栈，输入框有焦点走那个输入框——见 `performUndo`。
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { shortcuts.performUndo(redo: false) }
                .keyboardShortcut("z", modifiers: .command)
            Button("重做") { shortcuts.performUndo(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        // 正文是边打边存的，⌘S 只是"现在立刻落盘"——不用等到防抖结束。
        CommandGroup(replacing: .saveItem) {
            Button("保存到本地") { shortcuts.flush() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!shortcuts.hasEditableNote)
        }

        CommandMenu("格式") {
            Button("加粗") { shortcuts.send(.bold) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!shortcuts.hasEditableNote)
            Button("斜体") { shortcuts.send(.italic) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!shortcuts.hasEditableNote)
            Button("下划线") { shortcuts.send(.underline) }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!shortcuts.hasEditableNote)

            Divider()

            // ⌘⌥1/2/3 是 Pages、Notion 一类的通用键位，用户不用学新的。
            Button("标题 1") { shortcuts.send(.heading1) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(!shortcuts.hasEditableNote)
            Button("标题 2") { shortcuts.send(.heading2) }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(!shortcuts.hasEditableNote)
            Button("标题 3") { shortcuts.send(.heading3) }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(!shortcuts.hasEditableNote)
            Button("正文") { shortcuts.send(.paragraph) }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!shortcuts.hasEditableNote)

            Divider()

            Button("无序列表") { shortcuts.send(.bulletList) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!shortcuts.hasEditableNote)
            Button("有序列表") { shortcuts.send(.orderedList) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!shortcuts.hasEditableNote)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var onboarding: OnboardingState

    var body: some View {
        content
            // 引导阶段把窗口调成透明：内容浮在桌面上，玻璃才有东西可折射。
            // 进入主界面后 updateNSView 会把窗口还原成不透明。
            .background(WindowTransparency(enabled: isOnboarding))
    }

    /// 是否处于引导阶段（含只跑登录页的诊断模式）。
    private var isOnboarding: Bool {
        if ProcessInfo.processInfo.environment["MINB_LOGIN_ONLY"] == "1" { return true }
        return !onboarding.isReady
    }

    @ViewBuilder
    private var content: some View {
        // 诊断入口：直接停在登录页，跳过引导与主界面。
        // 只用于排查登录问题，配合 LoginTrace 一起用：
        //   MINB_LOGIN_ONLY=1 MINB_LOGIN_TRACE=1 ./build/MiNoteBridge.app/Contents/MacOS/MiNoteBridge
        // 不在这个环境变量下时它完全不参与，行为与原来一致。
        if ProcessInfo.processInfo.environment["MINB_LOGIN_ONLY"] == "1" {
            LoginStepView(onLoggedIn: { _ in }, onSkip: {})
                .frame(width: DS.windowSize.width, height: DS.windowSize.height)
        } else if onboarding.isReady {
            // 主界面：三栏式，需要横向空间，可自由拉伸。
            //
            // **不能写死 `.frame(width:height:)`。**
            // 固定尺寸时窗口被拉大、内容不跟随，多出来的那截会露出窗口默认浅色底——
            // 深色模式下就是详情栏顶部那条白横条（实测窗口 1358×805，内容只有 1000×680）。
            // 改成"最小尺寸 + 撑满"：内容永远铺满窗口，toolbar 下方不会再露出底色。
            MainView()
                .frame(minWidth: DS.mainWindowSize.width,
                       minHeight: DS.mainWindowSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 引导页：登录这一步现在是内嵌网页，用更大的窗口，否则小米登录页显示不全。
            OnboardingView(state: onboarding)
                .frame(width: DS.loginWindowSize.width, height: DS.loginWindowSize.height)
        }
    }
}
