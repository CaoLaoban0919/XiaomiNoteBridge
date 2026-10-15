import SwiftUI
import AppKit

/// 第 3 步：登录小米账号。
///
/// 版式约定：
/// 1. **扫码与密码登录收在同一个方框里**——它们做的是同一件事（登录），共用一个标题与说明。
/// 2. **小米许可单独一个方框**——勾选协议与登录是两个独立动作。
/// 3. 右栏默认是**密码登录**（账号 + 密码两个输入框）；密码框旁边一行小字「验证码登录」
///    切换过去，切过去之后才出现「发送」按钮。
///
/// 整个界面完全由原生 SwiftUI 构成，不嵌入任何网页。
struct LoginStepView: View {
    let onLoggedIn: (String) -> Void
    let onSkip: () -> Void

    @StateObject private var model = LoginModel()
    /// 网页登录兜底会话。只在异常分支用到，正常流程它是闲置的。
    @StateObject private var web = WebFallbackSession()

    var body: some View {
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
                    // 临时调试条，仅在开关打开时出现。验证完连同模型里那段一起删。
                    if LoginModel.debugErrors { debugStrip }
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
        .task { await model.startQRLogin() }
        .onDisappear { model.stopPolling() }
        // 报错统一走弹窗。放在最外层，两个模式共用一套。
        .alert(model.alertTitle, isPresented: $model.showAlert) {
            // 用户自己改不掉的失败，给一条"无论如何先登进去"的退路
            if model.alertOffersWebFallback {
                Button("改用网页登录") { model.openWebFallback() }
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }
        // 人机验证单独弹窗。这一步无法用原生控件完成——
        // 要么是图形验证码（要人眼识别），要么是滑块（要人手拖），
        // 所以它必须由用户亲自过，我们只负责把题目摆出来。
        .sheet(isPresented: $model.showCaptcha) {
            captchaSheet
        }
        // 网页登录兜底：异常分支才出现，正常流程一个网页都不会有
        .sheet(isPresented: $model.showWebFallback) {
            webFallbackSheet
        }
    }

    // MARK: - 临时调试条

    /// **临时代码**：仅当 `debugErrors` 开关打开时渲染。验证完删掉。
    private var debugStrip: some View {
        DSCard(title: "调试 · 手动触发错误分支", icon: "hammer", tint: DS.Status.warn) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("这几个分支正常操作触发不到，用一个假错误把它们叫出来看看。"
                     + "关掉开关就整条消失：defaults write local.minotebridge.app debugErrors -bool false")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DS.Space.s) {
                    Button("服务端登录失败") { model.debugServerFailure() }
                    Button("人机验证弹窗") { model.debugCaptcha() }
                    Button("手机号格式错") { model.debugPhoneError() }
                    Button("网页登录兜底") { model.debugWebFallback() }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - 网页登录兜底弹窗

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
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.m))
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
        // 只看"有没有小米域 Cookie"不够——被踢到登录页时也有一堆账号域 Cookie。
        // 真正可用的标志是出现 serviceToken / passToken。判断逻辑只有一份，在 WebFallback 里。
        if !WebFallbackSession.hasUsableCredential(cookie) {
            model.fail("登录尚未完成",
                       "页面里还没有拿到底层凭证。请先在页面内完成登录，再点「我已完成登录」。")
            return
        }
        model.acceptWebFallbackCookie(cookie)
    }

    // MARK: - 人机验证弹窗

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

            // 验证码图片
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

    // MARK: - 方框一：登录（两种方式收在一起）

    private var loginCard: some View {
        DSCard(title: "登录小米账号", icon: "person.crop.circle") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("下面两种方式任选其一即可。无论使用哪一种，登录成功后本应用获得的权限完全相同。")
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 标题独立成一行，右栏不再有自己的标题。
                // 这样二维码图像与右栏的第一个输入框天然从同一条水平线开始，
                // 不需要任何"补偿性 padding"去凑对齐。
                columnHeader("扫码登录",
                             badge: model.cookie == nil ? "推荐" : "已登录",
                             badgeTint: DS.Status.ok)

                HStack(alignment: .top, spacing: DS.Space.xl) {
                    qrBody
                        .frame(width: DS.Size.qrCode, alignment: .top)

                    formBody
                        .frame(width: DS.Size.loginFormWidth)
                        .frame(maxWidth: .infinity)   // 在右栏里居中，不贴边
                }
                .frame(maxWidth: .infinity)
            }
            .measureSize("login.card.body")
        }
        .measureSize("login.card")
    }

    // MARK: 左栏内容

    private var qrBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            qrImageBox

            // 刷新紧接在二维码下方
            HStack(spacing: DS.Space.s) {
                Button("刷新") { Task { await model.startQRLogin() } }
                    .controlSize(.small)
                if let img = model.qrImage {
                    Button("保存") { model.saveQRImage(img) }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            // 左栏只有二维码那么宽，这行主动断行，避免被挤成一个难看的折行
            Text("用小米手机扫一扫")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 常态（等待扫码）不渲染任何东西；只有出错或登录成功才出现
            if let line = model.statusLine {
                Text(line)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(model.cookie == nil ? DS.Status.bad : DS.Status.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .measureSize("login.qrBody")
    }

    // MARK: - 右栏内容（无标题，随模式切换）

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

    /// 两种登录方式之间的过渡，做成"液体流动"的观感。
    ///
    /// 靠三件事叠加，缺一不可：
    /// 1. **模糊**——旧内容先化开、新内容从模糊里聚拢。这是液体感的主要来源，
    ///    单纯的位移或淡入都只会像"换了个画面"，不会有"化开又聚拢"的质感；
    /// 2. **反向错位的位移**——旧的向下沉、新的从上落下，制造"流过去"的方向感；
    /// 3. **反向缩放**——旧的略微放大（1.03）、新的略微收缩（0.97），
    ///    让两者像在同一个容器里互相推挤，而不是各走各的。
    ///
    /// 曲线用 `dampingFraction: 0.72` 的弹簧：**允许一点点回弹**。
    /// 线性插值会显得机械，轻微过冲才像液体。
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

    /// 二维码本身。刻意不铺白底——图片自带白底黑模块，再套一个白框只会多出一圈空档。
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

    // MARK: 两种登录表单
    //
    // **结构刻意做成完全对称**：第一行一个输入框、第二行一个输入框 + 一行小字链接、
    // 第三行一个全宽按钮、第四行一行说明。
    //
    // 目的是让两种模式的切换"无感知"——切换时只有占位文字和链接文案在变，
    // 版式纹丝不动。之前用位移 + 缩放的动画，反而把注意力引到"切换"这个动作上，
    // 而这两种方式做的其实是同一件事（登录）。

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
            // 不做"填完整才可点"的预禁用——禁用的按钮说不清为什么不能点。
            // 点下去再弹窗告诉用户缺什么。
            .disabled(model.loggingIn)

            messageLine("密码不会保存到本机，也不会写入任何日志。")
        }
    }

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            // 第一行：整宽的手机号框（区号与发送都在框内）。
            // 这样它才能和密码模式第一行的「账号」框左右边缘完全对齐。
            phoneField

            // 第二行：验证码 + 返回链接，链接槽与密码模式的槽同宽 → 输入框右边缘对齐
            HStack(spacing: DS.Space.s) {
                TextField("验证码", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(DS.Fonts.label)
                    .monospacedDigit()

                switchLink("返回密码登录") { model.switchToPassword() }
                    .frame(width: DS.Size.formSlotWidth)
            }

            // 第三行：登录按钮。**验证码模式同样需要它**——
            // 填完验证码总要有个地方提交，否则这个表单是残缺的。
            // 位置与密码模式的「登录」完全一致，两种模式的行数与高度因此保持对称。
            Button {
                model.loginWithCode()
            } label: {
                Text(model.loggingIn ? "正在登录…" : "登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.loggingIn)

            messageLine("短信通道未接通，请用扫码或密码登录。")
        }
    }

    /// 手机号输入框：**一个框、两个内层**（左边区号、右边发送）。
    ///
    /// 区号和手机号本质是同一个东西（电话号码），所以同属一个框；
    /// 区号只是框里可单独点的一小块。发送按钮同理放进框内，
    /// 因为放到框外会把输入框挤窄，两种模式的输入框就对齐不了了。
    ///
    /// 两个内层用不同的表达，区分"值"与"动作"：
    /// - 区号是**中性底色块**——它是个值，点它只是换个值；
    /// - 发送是**强调色文字块**——它是个动作，点它会发短信。
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
                // 与外框留一点边距，"内层"的关系才看得出来
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

    /// 一行小字链接。两种模式都用它，位置固定在第二行输入框右侧。
    private func switchLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundStyle(DS.Palette.accent)
            .fixedSize()
    }

    /// 表单底部的说明行（不是报错行——报错走弹窗）。
    ///
    /// 两种模式各有一句固定说明，行数因此一致，切换时不会有高度变化。
    private func messageLine(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.caption)
            .foregroundStyle(Color.secondary.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 共用小件

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

    // MARK: - 方框二：小米许可

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

    /// 协议名可点击，由系统浏览器打开小米官网原文
    private var consentText: AttributedString {
        let raw = "我已阅读并同意小米的[《小米账号使用协议》](\(MiLoginService.agreementURL.absoluteString))"
            + "和[《小米账号隐私政策》](\(MiLoginService.privacyURL.absoluteString))。"
            + "（协议内容由小米官方页面提供，本应用不做转述或改写）"
        return (try? AttributedString(markdown: raw)) ?? AttributedString(raw)
    }
}

// MARK: - 过渡修饰器

/// 液体流动过渡用的修饰器：四个量一起变，才有"化开又聚拢"的质感。
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

// MARK: - 区号

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

// MARK: - 登录模型

@MainActor
final class LoginModel: ObservableObject {

    enum RightMode: Hashable { case password, code }

    // 扫码
    @Published var qrImage: NSImage?
    @Published var qrBusy = false
    @Published var qrExpired = false
    @Published var qrRemaining = 0
    @Published var qrError: String?
    @Published var cookie: String?

    private var qrSession: MiQRSession?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    // 右栏
    @Published var rightMode: RightMode = .password
    @Published var account = ""
    @Published var password = ""
    @Published var loggingIn = false

    // 报错弹窗
    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    /// 这次报错要不要顺便提供「改用网页登录」的出口。
    /// 校验类错误（没填账号之类）不需要——那些用户自己就能改。
    @Published var alertOffersWebFallback = false

    // 网页登录兜底
    @Published var showWebFallback = false

    // 人机验证弹窗
    @Published var showCaptcha = false
    @Published var captchaImage: NSImage?
    @Published var captchaCode = ""
    @Published var captchaBusy = false
    /// 登录会话与凭据参数要留到验证通过为止——
    /// 验证码绑定在这次会话上，重试时换一个 session 服务端就不认了。
    private var passwordSession: URLSession?
    private var passwordParams: MiLoginService.LoginParams?
    private var captchaURL: URL?

    // 验证码
    @Published var region: MiRegion = MiRegion.all[0]
    @Published var phone = ""
    @Published var code = ""
    @Published var countdown = 0

    // 协议
    @Published var consent = false

    /// 统一的报错出口。
    ///
    /// 用弹窗而不是内联的小灰字：内联提示在表单里很容易被当成普通说明扫过去，
    /// 而"手机号格式不对"这类问题必须让用户真正看到并处理。
    ///
    /// - Parameter offersWebFallback: 是否附带「改用网页登录」出口。
    ///   登录被服务端拒绝、或人机验证过不去时才给——那类问题用户自己改不掉，
    ///   需要一个"无论如何先登进去"的退路。
    func fail(_ title: String, _ message: String, offersWebFallback: Bool = false) {
        alertTitle = title
        alertMessage = message
        alertOffersWebFallback = offersWebFallback
        showAlert = true
    }

    // MARK: 扫码

    func startQRLogin() async {
        stopPolling()
        qrBusy = true
        qrError = nil
        qrImage = nil
        qrExpired = false
        cookie = nil
        defer { qrBusy = false }

        do {
            let (session, urlSession) = try await MiLoginService.requestQRCode()
            qrSession = session
            qrRemaining = session.expiresIn
            qrImage = MiLoginService.qrImage(for: session.content)
            guard qrImage != nil else {
                qrError = "二维码生成失败"
                return
            }
            startTick()
            startPolling(session, urlSession)
        } catch {
            qrError = error.localizedDescription
        }
    }

    private func startPolling(_ session: MiQRSession, _ urlSession: URLSession) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if session.isExpired {
                    await MainActor.run { self.qrExpired = true }
                    return
                }
                do {
                    let outcome = try await MiLoginService.pollOnce(session, session: urlSession)
                    if case .succeeded(let c) = outcome {
                        await MainActor.run {
                            self.cookie = c
                            self.qrError = nil
                        }
                        return
                    }
                } catch {
                    await MainActor.run { self.qrError = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func startTick() {
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

    // MARK: 右栏切换

    func switchToCode() {
        rightMode = .code
    }

    func switchToPassword() {
        rightMode = .password
    }

    // MARK: 校验

    /// 校验手机号。返回 nil 表示通过，否则返回给用户看的说明。
    ///
    /// 分两套规则：中国大陆号段固定是 11 位以 1 开头，其他国家/地区只做长度粗查——
    /// 各国号段规则差异太大，硬套一套规则只会把合法号码挡在外面。
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

    // MARK: 密码登录

    func loginWithPassword(captchaAnswer: String? = nil) {
        guard !loggingIn else { return }

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
                // 重试时复用上次的会话与参数，只有首次才新建
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
                // 成功：密码与会话都立刻清掉
                password = ""
                cookie = c
                qrError = nil
                loggingIn = false
                clearPasswordSession()

            } catch MiLoginError.captchaRequired(let url) {
                // 要求人机验证：**不清密码**——用户还要接着重试，让他重打一遍是折磨。
                // 会话与参数也保留，验证码就绑在这次会话上。
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

    /// 换一张验证码图片。用同一个会话重新取图，旧的字符随之作废。
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

    /// 打开网页登录兜底。清掉原生登录留下的中间状态，避免两套流程串在一起。
    func openWebFallback() {
        showAlert = false
        showCaptcha = false
        captchaImage = nil
        captchaCode = ""
        password = ""
        clearPasswordSession()
        showWebFallback = true
    }

    /// 兜底弹窗里登录成功、取到 Cookie
    func acceptWebFallbackCookie(_ cookie: String) {
        self.cookie = cookie
        showWebFallback = false
    }

    private func clearPasswordSession() {
        passwordSession = nil
        passwordParams = nil
        captchaURL = nil
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - 临时调试：手动触发错误分支
    //
    // 下面这几十行是**临时代码**，验证完就整段删掉，不参与正式流程。
    //
    // 存在的理由：服务端拒绝、人机验证、网页兜底这三个分支，
    // 用正常操作根本触发不到（要触发就得反复失败登录，可能把账号风控掉）。
    // 没有这段代码，这三条路径就只能靠读代码相信它对。
    //
    // 开关：
    //   defaults write local.minotebridge.app debugErrors -bool true   开启
    //   defaults write local.minotebridge.app debugErrors -bool false  关闭
    // ═══════════════════════════════════════════════════════════

    static var debugErrors: Bool {
        ProcessInfo.processInfo.environment["MINB_DEBUG_ERRORS"] == "1"
            || UserDefaults.standard.bool(forKey: "debugErrors")
    }

    func debugServerFailure() {
        fail("登录失败（调试）",
             "这是调试用的假错误。真实情况下这里显示的是小米返回的原话，"
             + "例如「账号或密码不正确」。注意弹窗里多了一个「改用网页登录」。",
             offersWebFallback: true)
    }

    func debugPhoneError() {
        fail("手机号格式不正确",
             "中国大陆手机号应为 11 位、以 1 开头。\n你当前填了 5 位。")
    }

    /// 伪造一张图形验证码，用来检查弹窗排版。
    /// 注意：真实的图片是从小米服务器取的，这里只是让弹窗能看。
    func debugCaptcha() {
        captchaURL = nil
        captchaCode = ""
        captchaImage = Self.debugCaptchaImage(text: "A7K2")
        showCaptcha = true
    }

    func debugWebFallback() {
        openWebFallback()
    }

    private static func debugCaptchaImage(text: String) -> NSImage {
        let size = NSSize(width: 150, height: 46)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        // 几道干扰线，模拟真实验证码的观感
        NSColor.gray.withAlphaComponent(0.45).setStroke()
        for i in 0..<4 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: CGFloat(6 + i * 11)))
            path.line(to: NSPoint(x: size.width, y: CGFloat(3 + i * 13)))
            path.lineWidth = 1
            path.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.darkGray,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let textSize = string.size()
        string.draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                                y: (size.height - textSize.height) / 2))

        image.unlockFocus()
        return image
    }

    // MARK: 验证码

    /// 「发送验证码」：先校验，通过才发。
    ///
    /// 按钮不预先禁用——禁用的按钮不会告诉用户"为什么不能点"，
    /// 点下去再弹出具体原因，比一个灰着的按钮有用。
    func sendSMSCode() {
        guard countdown == 0 else { return }

        if let problem = phoneValidationMessage() {
            fail("手机号格式不正确", problem)
            return
        }

        // 通道未接通：如实告知，**不启动倒计时**——没发出去却显示倒计时是在骗用户
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

    /// 发送成功后才应该启动的倒计时。
    ///
    /// **当前没有任何调用点**——因为短信通道未接通，`sendSMSCode` 只会弹窗告知，
    /// 不会真的发出去。这里保留它是为了通道接通后直接接上，
    /// 而不是留一段"看起来在工作"的假倒计时。
    private func startCountdown() {
        countdown = 60
        Task { [weak self] in
            while let self, self.countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self.countdown -= 1 }
            }
        }
    }

    // MARK: 文案

    /// 只返回有信息量的文本：加载中、出错、已登录成功。
    /// 常态（等待扫码）返回 nil——「等待扫码」那类文字占一行却不提供新信息。
    var statusLine: String? {
        if qrBusy { return "正在获取二维码…" }
        if let e = qrError { return e }
        if cookie != nil { return "已登录成功，勾选下方协议后即可继续。" }
        return nil
    }

    var footerNote: String {
        if cookie == nil && !consent { return "还没有完成登录，协议也尚未勾选。" }
        if cookie == nil { return "还没有完成登录。" }
        if !consent { return "请先勾选同意小米的用户协议与隐私政策。" }
        return "登录凭证已就绪。"
    }
}
