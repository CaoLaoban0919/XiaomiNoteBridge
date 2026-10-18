import SwiftUI

@main
struct MiNoteBridgeApp: App {
    @StateObject private var onboarding = OnboardingState()

    @StateObject private var shortcuts = EditorShortcuts.shared

    init() {

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

    @CommandsBuilder
    private var menuCommands: some Commands {

        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { shortcuts.performUndo(redo: false) }
                .keyboardShortcut("z", modifiers: .command)
            Button("重做") { shortcuts.performUndo(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

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

            .background(WindowTransparency(enabled: isOnboarding))
    }

    private var isOnboarding: Bool {
        if ProcessInfo.processInfo.environment["MINB_LOGIN_ONLY"] == "1" { return true }
        return !onboarding.isReady
    }

    @ViewBuilder
    private var content: some View {

        if ProcessInfo.processInfo.environment["MINB_LOGIN_ONLY"] == "1" {
            LoginStepView(onLoggedIn: { _ in }, onSkip: {})
                .frame(width: DS.windowSize.width, height: DS.windowSize.height)
        } else if onboarding.isReady {

            MainView()
                .frame(minWidth: DS.mainWindowSize.width,
                       minHeight: DS.mainWindowSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {

            OnboardingView(state: onboarding)
                .frame(width: DS.loginWindowSize.width, height: DS.loginWindowSize.height)
        }
    }
}
