import SwiftUI

/// 首次启动的三步引导容器：许可 → 权限 → 登录。
///
/// 顶部原本有一条步骤指示器（1 用户许可 · 2 系统权限 · 3 登录小米）。
/// 已按需求去掉——它占掉约 33px 垂直空间，而引导只有三步，
/// 用户点进来看标题就知道自己在哪一步，不值得为它牺牲内容区高度。
struct OnboardingView: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case .license:
            LicenseStepView(
                onAgree: { state.acceptLicense() },
                onDecline: { state.declineLicense() }
            )
            .transition(.opacity)

        case .permission:
            PermissionStepView(onContinue: { state.finishPermission() })
                .transition(.opacity)

        case .login:
            LoginStepView(
                onLoggedIn: { state.finishLogin(cookie: $0) },
                onSkip: { state.skipLogin() }
            )
            .transition(.opacity)
        }
    }
}
