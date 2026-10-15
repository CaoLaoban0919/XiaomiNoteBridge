import SwiftUI

@main
struct MiNoteBridgeApp: App {
    @StateObject private var onboarding = OnboardingState()

    var body: some Scene {
        WindowGroup("米记桥") {
            RootView()
                .environmentObject(onboarding)
        }
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var onboarding: OnboardingState

    var body: some View {
        // 不再额外判断 cookie —— 用户可以选择「先跳过」登录，
        // 那种情况下也应该能进主界面（未登录态），否则那个按钮等于没用。
        // 是否需要登录由 `isReady` 决定。
        if onboarding.isReady {
            // 主界面：三栏式，需要横向空间，可自由拉伸
            MainView()
                .frame(width: DS.mainWindowSize.width, height: DS.mainWindowSize.height)
        } else {
            // 引导页：固定小窗
            OnboardingView(state: onboarding)
                .frame(width: DS.windowSize.width, height: DS.windowSize.height)
        }
    }
}
