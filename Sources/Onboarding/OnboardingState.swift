import SwiftUI
import AppKit

@MainActor
final class OnboardingState: ObservableObject {

    enum Step: Int, CaseIterable {
        case license = 1
        case permission = 2
        case login = 3

        var title: String {
            switch self {
            case .license: return "用户许可"
            case .permission: return "系统权限"
            case .login: return "登录小米"
            }
        }
    }

    static let licenseVersion = "1.0"

    @Published var step: Step
    @Published var cookie: String?

    @Published var skippedLogin: Bool

    private let licenseKey = "acceptedLicenseVersion"
    private let permissionKey = "permissionStepAcknowledged"
    private let skipKey = "loginSkipped"

    init() {
        let defaults = UserDefaults.standard
        let licenseOK = defaults.string(forKey: licenseKey) == Self.licenseVersion
        let permissionOK = defaults.bool(forKey: permissionKey)
        cookie = CredentialsStore.loadCookie()
        skippedLogin = defaults.bool(forKey: skipKey)

        if !licenseOK {
            step = .license
        } else if !permissionOK {
            step = .permission
        } else {
            step = .login
        }
    }

    var isReady: Bool {
        guard UserDefaults.standard.string(forKey: licenseKey) == Self.licenseVersion else {
            return false
        }
        return CredentialsStore.loadCookie() != nil || skippedLogin
    }

    func acceptLicense() {
        UserDefaults.standard.set(Self.licenseVersion, forKey: licenseKey)
        withAnimation(.easeInOut(duration: 0.22)) { step = .permission }
    }

    func finishPermission() {
        UserDefaults.standard.set(true, forKey: permissionKey)
        withAnimation(.easeInOut(duration: 0.22)) { step = .login }
    }

    func finishLogin(cookie: String) {
        self.cookie = cookie
        try? CredentialsStore.saveCookie(cookie)
        UserDefaults.standard.set(true, forKey: permissionKey)
    }

    func loginLater(cookie: String) {
        self.cookie = cookie
        try? CredentialsStore.saveCookie(cookie)
        skippedLogin = false
        UserDefaults.standard.set(false, forKey: skipKey)
    }

    func skipLogin() {
        skippedLogin = true
        UserDefaults.standard.set(true, forKey: skipKey)
        UserDefaults.standard.set(true, forKey: permissionKey)
    }

    func declineLicense() {
        NSApplication.shared.terminate(nil)
    }

    func resetOnboarding() {
        let d = UserDefaults.standard
        d.removeObject(forKey: licenseKey)
        d.removeObject(forKey: permissionKey)
        d.removeObject(forKey: skipKey)
        CredentialsStore.clearCookie()
        cookie = nil
        skippedLogin = false
        step = .license
    }
}
