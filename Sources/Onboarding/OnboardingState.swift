import SwiftUI
import AppKit

/// 首次启动的推进状态。
///
/// 推进顺序：用户许可 → 系统权限 → 登录。每一步完成后才写入 UserDefaults，
/// 所以中途退出不会跳过尚未确认的步骤。
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
    /// 用户是否明确选择过「先跳过」登录。
    ///
    /// 需要它是因为：`isReady` 原来只认 cookie，而跳过登录是没有 cookie 的，
    /// 于是「先跳过」点了之后界面不会有任何变化（死按钮）。
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

    /// 许可已接受，且**已登录或用户明确跳过登录**时，进主界面。
    ///
    /// 注意这里不再强求 `cookie != nil`——否则跳过登录的用户永远进不去。
    /// 没登录也能进主界面，只是同步会提示未登录；「设置 → 小米账户」里有补登录的入口。
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

    /// 用户在主界面的「设置 → 小米账户」里补登录成功后调用
    func loginLater(cookie: String) {
        self.cookie = cookie
        try? CredentialsStore.saveCookie(cookie)
        skippedLogin = false
        UserDefaults.standard.set(false, forKey: skipKey)
    }

    /// 先跳过登录，直接进主界面（未登录态）。
    ///
    /// 原来的实现只写了一个 UserDefaults 标记，**既不推进 `step` 也不置 `cookie`**，
    /// 而 `isReady` 当时又要求必须有 cookie —— 结果这个按钮点下去什么都不会发生。
    /// 现在改成：记下「用户选择跳过」，并让 `isReady` 认这个标记。
    ///
    /// 跳过登录时也要记下权限步骤已处理过，避免每次启动都重走一遍。
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
