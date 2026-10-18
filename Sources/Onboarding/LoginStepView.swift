import SwiftUI
import AppKit

struct LoginStepView: View {
    let onLoggedIn: (String) -> Void
    let onSkip: () -> Void

    @StateObject private var model = LoginModel()

    @StateObject private var web = WebFallbackSession()

    @State private var showingWebLogin = false

    private var nativeLoginBody: some View {
        VStack(spacing: 0) {
            DSScreenHeader(
                title: "登录小米账号",
                subtitle: "登录在本应用内完成，不经过任何第三方服务器。登录凭证只会保存到你自己电脑上。"
            )
            .measureSize("login.header")

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    loginCard
                    consentCard
                }
                .padding(.horizontal, DS.Space.screen)
                .padding(.bottom, DS.Space.m)
                .measureSize("login.content")
            }

            Divider()

            DSFooter(note: model.footerNote) {
                Button("先跳过") { onSkip() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Button("完成登录") {
                    if let c = model.cookie { onLoggedIn(c) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.cookie == nil || !model.consent)
                .keyboardShortcut(.defaultAction)
            }
            .measureSize("login.footer")
        }
        .task {

            model.showWebFallback = true
        }
        .onDisappear { model.stopPolling() }

        .alert(model.alertTitle, isPresented: $model.showAlert) {

            if model.alertOffersWebFallback {
                Button("改用网页登录") { model.openWebFallback() }
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }

        .sheet(isPresented: $model.showCaptcha) {
            captchaSheet
        }

        .sheet(isPresented: $model.showWebFallback) {
            webFallbackSheet
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DSScreenHeader(
                title: "登录小米账号",
                subtitle: "登录在本应用内完成，不经过任何第三方服务器。登录凭证只会保存到你自己电脑上。"
            )
            .measureSize("login.header")

            ZStack {
                WebFallbackWebView(webView: web.webView)
                if web.phase.isBusy {
                    VStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("正在载入小米登录页面…")
                            .font(DS.Fonts.label).foregroundStyle(.secondary)
                    }
                    .padding(DS.Space.xl)
                    .dsGlass(cornerRadius: DS.Radius.m, fallbackStroke: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            DSFooter(note: webStatusText) {
                Button("先跳过") { onSkip() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Button("我已完成登录") {
                    Task { await finishWebFallback() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(web.phase.isBusy)
                .keyboardShortcut(.defaultAction)
            }
            .measureSize("login.footer")
        }
        .onAppear { web.start() }
        .onDisappear { model.stopPolling() }
    }

    private var webFallbackSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("网页登录")
                    .font(DS.Fonts.cardTitle)
                Text("备用方式")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Status.warn)
                    .padding(.horizontal, DS.Optical.compact)
                    .padding(.vertical, DS.Optical.snug)
                    .background(DS.Palette.tint(DS.Status.warn),
                                in: RoundedRectangle(cornerRadius: DS.Radius.s))
                Spacer(minLength: 0)
                Text("页面内容由小米提供")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)

            Divider()

            ZStack {
                WebFallbackWebView(webView: web.webView)
                if web.phase.isBusy {
                    VStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("正在载入小米登录页面…")
                            .font(DS.Fonts.label).foregroundStyle(.secondary)
                    }
                    .padding(DS.Space.xl)
                    .dsGlass(cornerRadius: DS.Radius.m, fallbackStroke: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: DS.Space.s) {
                Image(systemName: webStatusIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(webStatusTint)
                Text(webStatusText)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: DS.Space.m)

                Button("取消") { model.showWebFallback = false }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Button("我已完成登录") { Task { await finishWebFallback() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
        }
        .frame(width: DS.Size.webFallbackWidth, height: DS.Size.webFallbackHeight)
        .onAppear { web.start() }
    }

    private var webStatusIcon: String {
        switch web.phase {
        case .loading: return "clock"
        case .ready: return "hand.point.up.left"
        case .loggedIn: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var webStatusTint: Color {
        switch web.phase {
        case .loading: return DS.Status.idle
        case .ready: return DS.Status.warn
        case .loggedIn: return DS.Status.ok
        case .failed: return DS.Status.bad
        }
    }

    private var webStatusText: String {
        switch web.phase {
        case .loading: return "正在载入页面…"
        case .ready: return "请在页面内完成登录，成功后点右侧「我已完成登录」。"
        case .loggedIn: return "已检测到登录成功，点右侧按钮完成。"
        case .failed(let m): return "页面载入失败：\(m)"
        }
    }

    private func finishWebFallback() async {
        guard let cookie = await web.collectCookie() else {
            model.fail("没有取到登录凭证",
                       "页面里可能还没有完成登录。请确认已经登录成功后再试一次。")
            return
        }

        if !WebFallbackSession.hasUsableCredential(cookie) {
            model.fail("登录尚未完成",
                       "页面里还没有拿到底层凭证。请先在页面内完成登录，再点「我已完成登录」。")
            return
        }
        model.acceptWebFallbackCookie(cookie)

        onLoggedIn(cookie)
    }

    private var captchaSheet: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.accent)
                Text("需要完成人机验证")
                    .font(DS.Fonts.cardTitle)
                Spacer(minLength: 0)
            }

            Text("小米认为本次登录需要额外确认。请输入下图中的字符，然后继续登录。")
                .font(DS.Fonts.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.s).fill(DS.Palette.surface)
                if let img = model.captchaImage {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(DS.Space.s)
                } else if model.captchaBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("图片加载失败，点「换一张」重试。")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: DS.Size.captchaImageHeight)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s)
                .stroke(DS.Palette.stroke, lineWidth: 1))

            TextField("请输入图中的字符", text: $model.captchaCode)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(DS.Fonts.label)
                .onSubmit { model.submitCaptcha() }

            HStack(spacing: DS.Space.s) {
                Button("换一张") { Task { await model.refreshCaptcha() } }
                    .controlSize(.large)

                Spacer(minLength: 0)

                Button("取消") { model.cancelCaptcha() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Button("继续登录") { model.submitCaptcha() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.captchaCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("你的密码在验证期间会保留在输入框里，验证结束后立即清除；全程不落盘。")
                .font(DS.Fonts.caption)
                .foregroundStyle(Color.secondary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.captchaSheetWidth)
    }

    private var loginCard: some View {
        DSCard(title: "登录小米账号", icon: "person.crop.circle") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("下面两种方式任选其一即可。无论使用哪一种，登录成功后本应用获得的权限完全相同。")
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                columnHeader("扫码登录",
                             badge: model.cookie == nil ? "推荐" : "已登录",
                             badgeTint: DS.Status.ok)

                HStack(alignment: .top, spacing: DS.Space.xl) {
                    qrBody
                        .frame(width: DS.Size.qrCode, alignment: .top)

                    formBody
                        .frame(width: DS.Size.loginFormWidth)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
            .measureSize("login.card.body")
        }
        .measureSize("login.card")
    }

    private var qrBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            qrImageBox

            HStack(spacing: DS.Space.s) {
                Button("刷新") { Task { await model.startQRLogin() } }
                    .controlSize(.small)

                if let img = model.qrImage {
                    Button("保存") { model.saveQRImage(img) }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            Text("用小米手机扫一扫")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let line = model.statusLine {
                Text(line)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(model.statusTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .measureSize("login.qrBody")
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Spacer(minLength: 0)

            Group {
                if model.rightMode == .password {
                    passwordForm
                } else {
                    codeForm
                }
            }
            .transition(Self.liquidTransition)
            .animation(.spring(response: 0.52, dampingFraction: 0.72), value: model.rightMode)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 200)
        .measureSize("login.formBody")
    }

    private static let liquidTransition: AnyTransition = .asymmetric(
        insertion: .modifier(
            active: LiquidModifier(opacity: 0, blur: 7, offsetY: -10, scale: 0.97),
            identity: LiquidModifier(opacity: 1, blur: 0, offsetY: 0, scale: 1)
        ),
        removal: .modifier(
            active: LiquidModifier(opacity: 0, blur: 7, offsetY: 10, scale: 1.03),
            identity: LiquidModifier(opacity: 1, blur: 0, offsetY: 0, scale: 1)
        )
    )

    private var qrImageBox: some View {
        ZStack {
            if let img = model.qrImage {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s))
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Palette.surface)
                    .overlay {
                        VStack(spacing: DS.Space.s) {
                            if model.qrBusy {
                                ProgressView().controlSize(.small)
                                Text("获取中…")
                                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 28)).foregroundStyle(.tertiary)
                                Text(model.qrError ?? "二维码不可用")
                                    .font(DS.Fonts.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(DS.Space.m)
                    }
            }

            if model.qrExpired && model.qrImage != nil {
                RoundedRectangle(cornerRadius: DS.Radius.s).fill(.ultraThinMaterial)
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 20))
                    Text("已过期").font(DS.Fonts.label)
                    Button("点击刷新") { Task { await model.startQRLogin() } }
                        .controlSize(.small)
                }
            }
        }
        .frame(width: DS.Size.qrCode, height: DS.Size.qrCode)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.s)
            .stroke(DS.Palette.stroke, lineWidth: 1))
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            TextField("小米 ID / 手机号 / 邮箱", text: $model.account)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(DS.Fonts.label)

            HStack(spacing: DS.Space.s) {
                SecureField("密码", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(DS.Fonts.label)
                    .onSubmit { model.loginWithPassword() }

                switchLink("验证码登录") { model.switchToCode() }
                    .frame(width: DS.Size.formSlotWidth)
            }

            Button {
                model.loginWithPassword()
            } label: {
                Text(model.loggingIn ? "正在登录…" : "登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            .disabled(model.loggingIn || model.verifying)

            messageLine("密码不会保存到本机，也不会写入任何日志。")
        }
    }

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {

            phoneField

            HStack(spacing: DS.Space.s) {
                TextField("验证码", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(DS.Fonts.label)
                    .monospacedDigit()

                switchLink("返回密码登录") { model.switchToPassword() }
                    .frame(width: DS.Size.formSlotWidth)
            }

            Button {
                model.loginWithCode()
            } label: {
                Text(model.loggingIn ? "正在登录…" : "登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.loggingIn || model.verifying)

            messageLine("短信通道未接通，请用扫码或密码登录。")
        }
    }

    private var phoneField: some View {
        TextField("手机号", text: $model.phone)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .font(DS.Fonts.label)
            .monospacedDigit()
            .padding(.leading, DS.Size.phoneFieldInset)
            .padding(.trailing, DS.Size.phoneFieldTrailingInset)
            .onSubmit { model.sendSMSCode() }
            .overlay(alignment: .leading) {
                Menu {
                    ForEach(MiRegion.all) { r in
                        Button("\(r.name)  \(r.dialCode)") { model.region = r }
                    }
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Text(model.region.dialCode)
                            .font(DS.Fonts.label)
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Optical.snug)
                    .background(DS.Palette.nest,
                                in: RoundedRectangle(cornerRadius: DS.Radius.s))
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                .padding(.leading, DS.Space.xs)
            }
            .overlay(alignment: .trailing) {
                sendCodeButton
                    .padding(.trailing, DS.Space.xs)
            }
    }

    private var sendCodeButton: some View {
        Button {
            model.sendSMSCode()
        } label: {
            Text(model.countdown > 0 ? "\(model.countdown)s" : "发送验证码")
                .font(DS.Fonts.caption)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Optical.snug)
                .background(DS.Palette.tint(DS.Palette.accent),
                            in: RoundedRectangle(cornerRadius: DS.Radius.s))
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.countdown == 0 ? DS.Palette.accent : Color.secondary)
        .disabled(model.countdown > 0)
    }

    private func switchLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundStyle(DS.Palette.accent)
            .fixedSize()
    }

    private func messageLine(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundStyle(Color.secondary.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func columnHeader(_ text: String, badge: String, badgeTint: Color) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(text).font(DS.Fonts.rowTitle)
            Text(badge)
                .font(DS.Fonts.caption)
                .foregroundStyle(badgeTint)
                .padding(.horizontal, DS.Optical.compact)
                .padding(.vertical, DS.Optical.snug)
                .background(DS.Palette.tint(badgeTint),
                            in: RoundedRectangle(cornerRadius: DS.Radius.s))
            Spacer(minLength: 0)
        }
    }

    private var consentCard: some View {
        DSCard(title: "小米账号使用协议", icon: "doc.text") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Toggle("", isOn: $model.consent)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .padding(.top, DS.Optical.hairline)

                    Text(consentText)
                        .font(DS.Fonts.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .tint(DS.Palette.accent)
                }

            }
        }
        .measureSize("login.consent")
    }

    private var consentText: AttributedString {
        let raw = "我已阅读并同意小米的[《小米账号使用协议》](\(MiLoginService.agreementURL.absoluteString))"
            + "和[《小米账号隐私政策》](\(MiLoginService.privacyURL.absoluteString))。"
            + "（协议内容由小米官方页面提供，本应用不做转述或改写）"
        return (try? AttributedString(markdown: raw)) ?? AttributedString(raw)
    }
}

private struct LiquidModifier: ViewModifier {
    let opacity: Double
    let blur: CGFloat
    let offsetY: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale)
            .offset(y: offsetY)
    }
}

struct MiRegion: Identifiable, Hashable {
    let id: String
    let name: String
    let dialCode: String

    static let all: [MiRegion] = [
        .init(id: "86", name: "中国大陆", dialCode: "+86"),
        .init(id: "852", name: "中国香港", dialCode: "+852"),
        .init(id: "853", name: "中国澳门", dialCode: "+853"),
        .init(id: "886", name: "中国台湾", dialCode: "+886"),
        .init(id: "81", name: "日本", dialCode: "+81"),
        .init(id: "82", name: "韩国", dialCode: "+82"),
        .init(id: "65", name: "新加坡", dialCode: "+65"),
        .init(id: "60", name: "马来西亚", dialCode: "+60"),
        .init(id: "1", name: "美国 / 加拿大", dialCode: "+1"),
        .init(id: "44", name: "英国", dialCode: "+44"),
        .init(id: "61", name: "澳大利亚", dialCode: "+61"),
    ]
}

@MainActor
final class LoginModel: ObservableObject {

    enum RightMode: Hashable { case password, code }

    @Published var qrImage: NSImage?
    @Published var qrBusy = false
    @Published var qrExpired = false
    @Published var qrRemaining = 0
    @Published var qrError: String?
    @Published var cookie: String?

    @Published var verifying = false

    private var qrSession: MiQRSession?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    private var hasStarted = false

    private var sessionGeneration = 0

    @Published var rightMode: RightMode = .password
    @Published var account = ""
    @Published var password = ""
    @Published var loggingIn = false

    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""

    @Published var alertOffersWebFallback = false

    @Published var showWebFallback = false

    @Published var showCaptcha = false
    @Published var captchaImage: NSImage?
    @Published var captchaCode = ""
    @Published var captchaBusy = false

    private var passwordSession: URLSession?
    private var passwordParams: MiLoginService.LoginParams?
    private var captchaURL: URL?

    @Published var region: MiRegion = MiRegion.all[0]
    @Published var phone = ""
    @Published var code = ""
    @Published var countdown = 0

    @Published var consent = false

    func fail(_ title: String, _ message: String, offersWebFallback: Bool = false) {
        alertTitle = title
        alertMessage = message
        alertOffersWebFallback = offersWebFallback
        showAlert = true
    }

    func startOnce() async {
        guard !hasStarted else {
            LoginTrace.log("startOnce 跳过：已经初始化过")
            return
        }
        hasStarted = true
        LoginTrace.log("startOnce 首次初始化")
        await startQRLogin()
    }

    func startQRLogin() async {

        guard !qrBusy else {

            LoginTrace.log("刷新被跳过：上一轮申请还没结束（qrBusy=true）")
            return
        }

        sessionGeneration += 1
        let generation = sessionGeneration
        stopPolling()

        let previousCookie = cookie

        qrBusy = true
        qrError = nil
        qrImage = nil
        qrExpired = false

        verifying = false
        cookie = nil
        defer { qrBusy = false }

        do {
            let (session, urlSession) = try await MiLoginService.requestQRCode()
            qrSession = session
            qrRemaining = session.expiresIn
            qrImage = MiLoginService.qrImage(for: session.content)
            guard qrImage != nil else {
                qrError = "二维码生成失败"
                LoginTrace.log("requestQRCode 成功，但 CoreImage 生成二维码失败")
                return
            }
            LoginTrace.log("requestQRCode 成功：expires=\(session.expiresIn)s "
                           + "lp=\(session.pollURL.host ?? "?") "
                           + "qr=\(Int(qrImage!.size.width))x\(Int(qrImage!.size.height))，开始轮询")
            startTick()
            startPolling(session, urlSession, generation: generation)
        } catch {
            qrError = error.localizedDescription

            cookie = previousCookie
            LoginTrace.log("requestQRCode 失败：\(error.localizedDescription)")
        }
    }

    private func startPolling(_ session: MiQRSession, _ urlSession: URLSession, generation: Int) {

        pollTask?.cancel()
        pollTask = Task { [weak self] in

            var attempts = 0
            var badRounds = 0
            var fastRounds = 0
            defer { LoginTrace.log("poll 结束，共尝试 \(attempts) 次") }
            while !Task.isCancelled {
                guard let self else {
                    LoginTrace.log("轮询结束：LoginModel 已释放（视图被销毁）")
                    return
                }
                if session.isExpired {
                    LoginTrace.log("轮询结束：二维码已过期（gen \(generation)）")

                    if generation == self.sessionGeneration {
                        await MainActor.run { self.qrExpired = true }
                    }
                    return
                }

                attempts += 1
                let roundStart = Date()
                do {
                    let outcome = try await MiLoginService.pollOnce(session, session: urlSession)
                    LoginTrace.log("pollOnce → \(LoginTrace.describe(outcome))")

                    switch outcome {
                    case .succeeded(let c):

                        await self.verifyAndAccept(c, generation: generation)
                        return
                    case .waiting:

                        let elapsed = Date().timeIntervalSince(roundStart)
                        if elapsed < 2.0 {
                            fastRounds += 1
                            let backoff = min(0.5 * Double(fastRounds), 5.0)
                            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                        } else {
                            fastRounds = 0
                        }
                        badRounds = 0
                    case .unexpected:
                        badRounds += 1

                        fastRounds = 0
                        if badRounds >= 5 {
                            await MainActor.run {
                                guard generation == self.sessionGeneration else { return }

                                self.qrError = "登录服务返回了异常内容，请点「刷新」重试；若反复出现，再改用网页登录。"
                            }
                            LoginTrace.log("poll 终止：连续 \(badRounds) 次无法解析")
                            return
                        }

                        let backoff = min(0.5 * Double(badRounds), 5.0)
                        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    }
                } catch MiLoginError.expired {

                    await MainActor.run {
                        guard generation == self.sessionGeneration else { return }
                        self.qrExpired = true
                        self.qrError = nil
                    }
                    LoginTrace.log("poll 终止：票据失效（gen \(generation)）")
                    return
                } catch {

                    if Task.isCancelled {
                        LoginTrace.log("轮询结束：被取消（gen \(generation)）")
                        return
                    }

                    guard generation == self.sessionGeneration else {
                        LoginTrace.log("轮询丢弃：gen \(generation) ≠ 当前 \(self.sessionGeneration)")
                        return
                    }

                    LoginTrace.log("poll 终止：\(error.localizedDescription)")
                    await MainActor.run { self.qrError = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func startTick() {

        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    guard let s = self.qrSession else { return }
                    self.qrRemaining = s.remaining
                    if s.isExpired { self.qrExpired = true }
                }
            }
        }
    }

    func stopPolling() {

        if pollTask != nil || tickTask != nil {
            LoginTrace.log("stopPolling 取消轮询")
        }
        pollTask?.cancel(); pollTask = nil
        tickTask?.cancel(); tickTask = nil
    }

    func saveQRImage(_ img: NSImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "小米登录二维码.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    func switchToCode() {
        rightMode = .code
    }

    func switchToPassword() {
        rightMode = .password
    }

    private func phoneValidationMessage() -> String? {
        let digits = phone.filter(\.isNumber)
        if digits.isEmpty {
            return "请先填写手机号。"
        }
        if region.id == "86" {
            if digits.count != 11 || !digits.hasPrefix("1") {
                return "中国大陆手机号应为 11 位、以 1 开头。\n你当前填了 \(digits.count) 位。"
            }
        } else if digits.count < 6 || digits.count > 15 {
            return "\(region.name)（\(region.dialCode)）的手机号应为 6 到 15 位。\n你当前填了 \(digits.count) 位。"
        }
        return nil
    }

    func loginWithPassword(captchaAnswer: String? = nil) {

        guard !loggingIn, !verifying else { return }

        let user = account.trimmingCharacters(in: .whitespaces)
        if user.isEmpty {
            fail("请填写账号", "可以填小米 ID、手机号或邮箱。")
            return
        }
        if password.isEmpty {
            fail("请填写密码", "密码不会保存到本机，也不会写入任何日志。")
            return
        }

        loggingIn = true
        let secret = password

        Task {
            do {

                let params: MiLoginService.LoginParams
                let session: URLSession
                if let p = passwordParams, let s = passwordSession {
                    params = p; session = s
                } else {
                    let fresh = try await MiLoginService.fetchLoginParams()
                    params = fresh.0; session = fresh.1
                    passwordParams = params
                    passwordSession = session
                }

                let c = try await MiLoginService.loginWithPassword(user: user,
                                                                  password: secret,
                                                                  params: params,
                                                                  session: session,
                                                                  captchaCode: captchaAnswer)

                password = ""
                loggingIn = false
                clearPasswordSession()

                await verifyAndAccept(c, generation: sessionGeneration)

            } catch MiLoginError.captchaRequired(let url) {

                loggingIn = false
                captchaURL = url
                captchaCode = ""
                showCaptcha = true
                await loadCaptchaImage()

            } catch {
                password = ""
                loggingIn = false
                clearPasswordSession()
                fail("登录失败", error.localizedDescription, offersWebFallback: true)
            }
        }
    }

    private func loadCaptchaImage() async {
        guard let url = captchaURL, let session = passwordSession else { return }
        captchaBusy = true
        captchaImage = await MiLoginService.fetchCaptchaImage(url, session: session)
        captchaBusy = false
    }

    func refreshCaptcha() async {
        captchaCode = ""
        await loadCaptchaImage()
    }

    func submitCaptcha() {
        let trimmed = captchaCode.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            fail("请填写验证码", "请输入图片中的字符。看不清可以点「换一张」。")
            return
        }
        showCaptcha = false
        loginWithPassword(captchaAnswer: trimmed)
    }

    func cancelCaptcha() {
        showCaptcha = false
        captchaImage = nil
        captchaCode = ""
        password = ""
        clearPasswordSession()
    }

    func openWebFallback() {
        showAlert = false
        showCaptcha = false
        captchaImage = nil
        captchaCode = ""
        password = ""
        clearPasswordSession()
        showWebFallback = true
    }

    func acceptWebFallbackCookie(_ cookie: String) {
        self.cookie = cookie
        showWebFallback = false
    }

    func verifyAndAccept(_ cookie: String, generation: Int) async {
        guard isCurrentGeneration(generation) else {
            LoginTrace.log("丢弃过期校验结果（gen \(generation) ≠ \(sessionGeneration)）")
            return
        }

        let quality = MiLoginService.credentialQuality(cookie)
        LoginTrace.log("verifyAndAccept：凭证质量=\(quality)")
        guard quality != .none else {
            fail("登录没有真正完成",
                 "没有拿到可用的登录凭证，这通常是登录流程中途被打断导致的。\n\n"
                 + "扫码登录请点二维码下方的「刷新」重新获取再扫一次；"
                 + "若反复如此，点下面的「改用网页登录」。",
                 offersWebFallback: true)
            return
        }
        guard quality == .serviceToken else {

            fail("登录没有走完",
                 "账号已经记住了，但没拿到能读取笔记的凭证。\n\n"
                 + "请点二维码下方的「刷新」重新扫一次；若反复如此，点下面的「改用网页登录」。",
                 offersWebFallback: true)
            return
        }

        verifying = true

        defer { if generation == sessionGeneration { verifying = false } }

        do {
            _ = try await MiAPI(cookie: cookie).testConnection()

            guard isCurrentGeneration(generation) else {
                LoginTrace.log("testConnection 返回时已过期，丢弃（gen \(generation)）")
                return
            }
            LoginTrace.log("testConnection 通过：凭证确实能读笔记")
            accept(cookie)
        } catch MiError.badPayload {

            guard isCurrentGeneration(generation) else { return }
            LoginTrace.log("testConnection 失败：badPayload（返回不是笔记数据，多为登录页 HTML）")
            fail("登录没有完成",
                 "小米返回的内容不是笔记数据，登录很可能没有真正生效。\n\n"
                 + "扫码登录请点二维码下方的「刷新」重新获取；"
                 + "也可以点下面的「改用网页登录」。",
                 offersWebFallback: true)
        } catch MiError.cookieInvalid {
            guard isCurrentGeneration(generation) else { return }
            LoginTrace.log("testConnection 失败：cookieInvalid（响应里没有 data/entries）")
            fail("登录凭证无效",
                 "小米没有接受这份登录凭证，它可能已经过期。\n\n"
                 + "扫码登录请点二维码下方的「刷新」重新获取；"
                 + "也可以点下面的「改用网页登录」。",
                 offersWebFallback: true)
        } catch MiError.http(let code, _) where code == 401 || code == 403 {
            guard isCurrentGeneration(generation) else { return }
            LoginTrace.log("testConnection 失败：HTTP \(code)")
            fail("登录凭证被拒绝",
                 "小米返回 HTTP \(code)，说明这份凭证不能用来读取笔记。\n\n"
                 + "扫码登录请点二维码下方的「刷新」重新获取；"
                 + "也可以点下面的「改用网页登录」。",
                 offersWebFallback: true)
        } catch {

            guard isCurrentGeneration(generation) else { return }
            LoginTrace.log("testConnection 异常，按网络问题放行：\(error.localizedDescription)")
            accept(cookie)
        }
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == sessionGeneration
    }

    private func accept(_ cookie: String) {
        LoginTrace.log("accept：登录成功，凭证含 \(cookie.split(separator: ";").count) 个 Cookie")
        self.cookie = cookie
        qrError = nil
        qrExpired = false

        stopPolling()
    }

    private func clearPasswordSession() {
        passwordSession = nil
        passwordParams = nil
        captchaURL = nil
    }

    func sendSMSCode() {
        guard countdown == 0 else { return }

        if let problem = phoneValidationMessage() {
            fail("手机号格式不正确", problem)
            return
        }

        fail("短信通道尚未接通",
             "小米的短信接口未公开，且背后有极验滑块与图形验证码兜底，本版本没有接通。\n\n可以改用左侧的扫码登录，或点下面的「改用网页登录」。",
             offersWebFallback: true)
    }

    func loginWithCode() {
        if let problem = phoneValidationMessage() {
            fail("手机号格式不正确", problem)
            return
        }

        let trimmed = code.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            fail("请填写验证码", "请先点手机号框里的「发送验证码」，再把收到的验证码填进来。")
            return
        }
        if trimmed.count < 4 {
            fail("验证码不完整", "验证码通常为 4 到 6 位，你当前填了 \(trimmed.count) 位。")
            return
        }

        fail("验证码登录尚未接通",
             "小米的短信接口未公开且带极验滑块验证，本版本没有接通验证码登录。\n\n可以改用左侧的扫码登录，或点下面的「改用网页登录」。",
             offersWebFallback: true)
    }

    private func startCountdown() {
        countdown = 60
        Task { [weak self] in
            while let self, self.countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self.countdown -= 1 }
            }
        }
    }

    var statusTint: Color {

        if verifying || qrBusy { return DS.Status.idle }
        if cookie != nil { return DS.Status.ok }
        if qrError != nil { return DS.Status.bad }
        return DS.Status.idle
    }

    var statusLine: String? {
        if verifying { return "凭证已到手，正在确认它真的能读取笔记…" }
        if qrBusy { return "正在获取二维码…" }

        if cookie != nil { return "已登录成功，勾选下方协议后即可继续。" }
        if let e = qrError { return e }
        return nil
    }

    var footerNote: String {
        if verifying { return "正在校验登录凭证，请稍候。" }
        if cookie == nil && !consent { return "还没有完成登录，协议也尚未勾选。" }
        if cookie == nil { return "还没有完成登录。" }
        if !consent { return "请先勾选同意小米的用户协议与隐私政策。" }
        return "登录凭证已就绪。"
    }
}
