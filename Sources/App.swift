import SwiftUI

@main
struct MiNoteBridgeApp: App {
    @StateObject private var onboarding = OnboardingState()

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
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var onboarding: OnboardingState

    var body: some View {
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
