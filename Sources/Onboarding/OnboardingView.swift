import SwiftUI

struct OnboardingView: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            .dsGlass(cornerRadius: 0, fallbackStroke: false)
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
