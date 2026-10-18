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
    /// 是否正在显示网页登录面板
    @State private var showingWebLogin = false

    /// 原生登录界面（扫码 / 密码 / 验证码）。
    ///
    /// **当前不显示**——登录已改为直接走网页登录（见下方 `body`）。
    /// 代码**完整保留**，需要恢复时把 `body` 换回 `nativeLoginBody` 即可。
    ///
    /// 保留而不是删掉的理由：扫码那条路只差最后一步"用服务端签名的 URL 换 `serviceToken`"，
    /// 若将来摸清签名规则（或小米放宽），这里能立刻切回去，不用重写一遍界面。
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
            // **直接进网页登录，不再申请二维码。**
            //
            // 扫码登录的最后一步，是拿 `lp` 下发的签名 URL（`i.mi.com/sts?..._ssign`）
            // 去换 `serviceToken`。那个签名由服务端生成、绑定了我们看不到的因素，
            // 实测原样发送仍回 401，客户端没有复现的余地。
            // 网页里是**真实浏览器会话**，小米自己的 JS 会完成包括签名在内的全部流程，
            // 我们只负责把会话里的 Cookie 取回来。
            model.showWebFallback = true
        }
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

    /// 登录页当前**直接显示网页登录**，但保留原页面的三段式骨架。
    ///
    /// 为什么不再走原生扫码：最后一步是把 `lp` 下发的签名 URL（`i.mi.com/sts?..._ssign`）
    /// 原样请求来换 `serviceToken`，而那个签名由服务端生成、绑定客户端看不到的因素——
    /// 实测参数完整、原样发送仍然回 401（且 body 为空，说明拒绝发生在认证层）。
    /// 网页里是真实浏览器会话，小米自己的 JS 会完成包括签名在内的全部流程。
    ///
    /// **外层骨架（标题 / 底栏）必须保留**：它们不属于登录表单，而是"这一步"的页面框架，
    /// 只有中间的内容区换成了网页。之前直接把 `body` 换成 `webFallbackSheet`，
    /// 标题和「先跳过」就一起消失了。
    var body: some View {
        VStack(spacing: 0) {
            DSScreenHeader(
                title: "登录小米账号",
                subtitle: "登录在本应用内完成，不经过任何第三方服务器。登录凭证只会保存到你自己电脑上。"
            )
            .measureSize("login.header")

            // 网页内容区：铺满中间，随窗口拉伸
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
        // 只看"有没有小米域 Cookie"不够——被踢到登录页时也有一堆账号域 Cookie。
        // 真正可用的标志是出现 serviceToken / passToken。判断逻辑只有一份，在 WebFallback 里。
        if !WebFallbackSession.hasUsableCredential(cookie) {
            model.fail("登录尚未完成",
                       "页面里还没有拿到底层凭证。请先在页面内完成登录，再点「我已完成登录」。")
            return
        }
        model.acceptWebFallbackCookie(cookie)
        // **直接前进。** 主界面已经替换成网页登录，原来那个「完成登录」按钮
        // 属于原生界面，现在不存在了；取到有效凭证就是这件事的终点，
        // 不需要用户再多点一次。
        onLoggedIn(cookie)
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
                    // **刻意不按 verifying 禁用。**
                    // 禁用看起来"更严谨"，实际会变成死锁：校验卡在一次慢网络里时，
                    // 用户既不能重来也不能取消，只能干等（而他已经没有任何反馈）。
                    // 重来本身是安全的——startQRLogin 会推进代际号，旧结果回来会被丢弃。
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

            // 常态（等待扫码）不渲染任何东西；只有校验中、出错、或登录成功才出现
            if let line = model.statusLine {
                Text(line)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(model.statusTint)
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
            .disabled(model.loggingIn || model.verifying)

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
            .disabled(model.loggingIn || model.verifying)

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

    /// 已拿到 Cookie、正在校验它是否真的可用。
    ///
    /// 这一步不能省，理由见 `verifyAndAccept`。界面用它显示"正在校验…"，
    /// 并在这期间禁用会打断流程的按钮（刷新二维码 / 再次登录）。
    @Published var verifying = false

    private var qrSession: MiQRSession?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// `.task` 是否已经初始化过（见 `startOnce`）。
    private var hasStarted = false

    /// 每次重新申请二维码就 +1，用来认出"上一轮迟到的结果"。
    ///
    /// 用户点刷新时，旧二维码的校验请求可能还在路上；它回来时如果照常写状态，
    /// 就会把新会话的界面改成一个已经作废的结果（甚至把旧 cookie 当成新的）。
    /// 每一次"重来"都换一个代际号，旧结果一回来就被认出来直接丢掉。
    private var sessionGeneration = 0

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

    /// 视图出现时的入口：**只初始化一次**。
    ///
    /// `.task` 在视图重新出现时会再次执行。每执行一次就会把 `qrImage` 清成 nil
    /// 再重新申请，界面上表现为"二维码一直在获取、始终拿不到"。
    /// 用标记收敛成一次；用户主动点「刷新」仍走 `startQRLogin()`，不受影响。
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
        // **重入闸门**：连点两次「刷新」会开出两条并发的申请流程，
        // 后一条的 `pollTask = ...` 会直接覆盖前一条的句柄——被覆盖的那个
        // 成了孤儿任务，`stopPolling()` 再也取消不掉它，它会一直打网络、
        // 到点还会把新二维码标成"已过期"。
        guard !qrBusy else {
            // 这条静默返回曾经让"点刷新没反应"完全无法排查：
            // 用户点了、什么都没发生、日志里也一个字都没有。
            LoginTrace.log("刷新被跳过：上一轮申请还没结束（qrBusy=true）")
            return
        }

        // 换一个代际号：从这一刻起，上一轮的任何迟到结果都作废
        sessionGeneration += 1
        let generation = sessionGeneration
        stopPolling()

        // 清空 cookie 是为了让界面先回到"未登录"，但**失败要还回去**：
        // 用户可能本来已经登录好了，只是好奇点了一下刷新。请求失败还顺手
        // 把他的登录态清掉，等于"点一下就自动登出"。
        let previousCookie = cookie

        qrBusy = true
        qrError = nil
        qrImage = nil
        qrExpired = false
        // 主动重来一次就该把上一次的校验状态一并清掉，
        // 否则「刷新」会带着一个假的"校验中"进去，按钮一直是灰的。
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
            // 失败回滚：别因为一次刷新失败就把用户原有的登录态清掉
            cookie = previousCookie
            LoginTrace.log("requestQRCode 失败：\(error.localizedDescription)")
        }
    }

    private func startPolling(_ session: MiQRSession, _ urlSession: URLSession, generation: Int) {
        // 先取消旧句柄再赋值。直接覆盖会让上一条轮询变成取消不掉的孤儿任务。
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // 兜底：**无论从哪个出口离开这个循环都留一行日志。**
            // 循环有四个静默出口（条件失败 / 二维码过期 / 对象已释放 / catch 里的三种），
            // 逐个补日志仍会漏；最外层一个 defer 才能保证"轮询为什么停了"永远有答案。
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
                    // 只有当前这一轮才有资格把界面标成"已过期"；
                    // 旧会话到期时新二维码可能已经生成了，别去盖它。
                    if generation == self.sessionGeneration {
                        await MainActor.run { self.qrExpired = true }
                    }
                    return
                }
                // 计数放在这里：只有真的发起了请求才算一次尝试。
                attempts += 1
                let roundStart = Date()
                do {
                    let outcome = try await MiLoginService.pollOnce(session, session: urlSession)
                    LoginTrace.log("pollOnce → \(LoginTrace.describe(outcome))")
                    // 用穷举 switch，不用 `if case .succeeded`：枚举新增 `.unexpected` 后，
                    // `if case` 会把它和 `.waiting` 一起静默吞掉——两者虽然都"继续轮询"，
                    // 但 `.unexpected` 是服务端**立刻**返回的，必须计数并退避，
                    // 否则就是零间隔空转，而零间隔空转正是能把服务端喂出 403 的形态。
                    switch outcome {
                    case .succeeded(let c):
                        // 不直接把 Cookie 当成功——先校验它真能读笔记，见 verifyAndAccept
                        await self.verifyAndAccept(c, generation: generation)
                        return
                    case .waiting:
                        // **秒回的 `.waiting` 必须退避。**
                        // 403/429/5xx 都映射成 `.waiting`，而它们是**毫秒级返回**的。
                        // 零间隔重打同一 ticket 会让限流自己维持下去（越打越 403，
                        // 正是压测里"连打十几条就 403"的同一形态）。更糟的是
                        // `badRounds = 0` 让"连续失败"计数永远触发不了上限，
                        // 也就是这条自激回路没有任何天然终点。
                        // 正常 hold（>2s）则不需要间隔——服务端本来就在等我们。
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
                        // 归零"快速返回"那条序列：`.unexpected` 有自己的计数与退避，
                        // 两条序列叠加会让等待变成 5s + 5s。
                        fastRounds = 0
                        if badRounds >= 5 {
                            await MainActor.run {
                                guard generation == self.sessionGeneration else { return }
                                // 带上退路：连续 5 次解析失败多半不是用户能自己解决的，
                                // 只让他"重试"等于让他反复撞同一堵墙。
                                self.qrError = "登录服务返回了异常内容，请点「刷新」重试；若反复出现，再改用网页登录。"
                            }
                            LoginTrace.log("poll 终止：连续 \(badRounds) 次无法解析")
                            return
                        }
                        // 500ms × n，封顶 5s（与官方实现一致）
                        let backoff = min(0.5 * Double(badRounds), 5.0)
                        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    }
                } catch MiLoginError.expired {
                    // **早到的失效必须驱动遮罩，不能只写一行红字。**
                    // `code != 0` 可能在第 10 秒就返回，而 `qrExpired` 要等本地
                    // 300 多秒才由 tick 补上。这中间二维码看起来仍然能扫，
                    // 用户会再扫一次、再等一轮，把"失效"体验成"扫了没反应"。
                    // 代际判断放进 MainActor 闭包里：await 之前用户可能已经点了刷新。
                    await MainActor.run {
                        guard generation == self.sessionGeneration else { return }
                        self.qrExpired = true
                        self.qrError = nil
                    }
                    LoginTrace.log("poll 终止：票据失效（gen \(generation)）")
                    return
                } catch {
                    // 被主动取消（点「刷新」换二维码、或离开页面）不是错误。
                    // 不挡住的话，这里会往 qrError 写一句"已取消"，而那时新的二维码
                    // 正在加载、qrError 刚被清成 nil —— 两条异步路径赛跑，
                    // 用户会看到一个莫名其妙的错误贴在刚生成的二维码下面。
                    if Task.isCancelled {
                        LoginTrace.log("轮询结束：被取消（gen \(generation)）")
                        return
                    }
                    // 旧会话的错误不该贴到新二维码下面
                    guard generation == self.sessionGeneration else {
                        LoginTrace.log("轮询丢弃：gen \(generation) ≠ 当前 \(self.sessionGeneration)")
                        return
                    }
                    // **必须记下终止原因。** 早先这里只把错误写进界面，
                    // 日志里一个字都没有，于是"轮询为什么停了"完全无从判断。
                    LoginTrace.log("poll 终止：\(error.localizedDescription)")
                    await MainActor.run { self.qrError = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func startTick() {
        // 同上：先取消旧句柄，避免留下一条取消不掉的倒计时
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
        // 记一笔：如果日志里反复出现它，说明视图在反复消失/重建，
        // 轮询被一直掐断——这正是"扫码了但永远不完成"的典型形态。
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
        // 校验期间也挡住重复提交：此时 loggingIn 已复位，光看它不足以拦住第二次点击
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
                // 密码与会话立刻清掉，**不等校验完成**——密码不该为了等一次网络往返多留一秒
                password = ""
                loggingIn = false
                clearPasswordSession()
                // 服务端给了 location 只代表"凭据通过"，不代表 Cookie 真的能读笔记
                await verifyAndAccept(c, generation: sessionGeneration)

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

    // MARK: 登录成功的统一出口（扫码 / 密码共用）

    /// 校验一份刚拿到的 Cookie，通过了才算登录成功。
    ///
    /// **为什么不能"拿到 Cookie 就当成功"：** 拿到 Cookie ≠ 这个 Cookie 能用。
    /// 小米在多条失败路径上都会种下一堆 `account.xiaomi.com` 域的 Cookie 却不发
    /// `serviceToken`；只检查"有没有 Cookie"会把这种情况当成登录成功，
    /// 用户随后点「拉取」才发现读不到笔记，而错误信息还会指向网络或 Cookie 过期，
    /// 完全看不出来问题其实出在登录这一步。所以这里做两道校验：
    ///
    /// 1. **结构校验**：必须带 `serviceToken` / `passToken`（判断逻辑在 `MiLoginService`，三处共用一份）；
    /// 2. **端到端校验**：拿这个 Cookie 去真读一次笔记。只拉 1 条，代价极小，
    ///    但能一次性确认"凭证可用 + 这个账号确实能读到笔记"。
    func verifyAndAccept(_ cookie: String, generation: Int) async {
        guard isCurrentGeneration(generation) else {
            LoginTrace.log("丢弃过期校验结果（gen \(generation) ≠ \(sessionGeneration)）")
            return
        }

        // **必须在进 testConnection 之前分三态拦。**
        // 早先这里只判 `.hasUsableCredential`（serviceToken 或 passToken 都算有），
        // 而下面"网络异常不判失败"的 catch 会 `accept(cookie)` —— 两者一组合就留出
        // 一条假成功路径：只有 passToken、其实读不了笔记的凭证，只要 testConnection
        // 那一刻恰好网络抖动，就会被当成登录成功存下来。用户要到点「拉取」才发现
        // 读不到，而错误会指向网络或 Cookie 过期。
        // 分三态之后，能走到 catch 的一定已经带 serviceToken，"不冤枉好用户"的原则完整保留。
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
            // 只拿到 passToken：账号记住了，但没换到读笔记的凭证。
            // 与 `.none` 分开报，因为原因不同（流程没走完 vs 被中断），处理方式也不同。
            fail("登录没有走完",
                 "账号已经记住了，但没拿到能读取笔记的凭证。\n\n"
                 + "请点二维码下方的「刷新」重新扫一次；若反复如此，点下面的「改用网页登录」。",
                 offersWebFallback: true)
            return
        }

        verifying = true
        // 只有"自己这一轮"才有资格把标志清掉。
        // 无条件清会让一个旧校验的收尾把新一轮的"校验中"抹掉（按钮提前恢复可点）。
        defer { if generation == sessionGeneration { verifying = false } }

        do {
            _ = try await MiAPI(cookie: cookie).testConnection()
            // await 期间用户完全可能点了「刷新」换二维码。那时这份结果已经作废，
            // 再把 cookie 写进去就等于让一次旧的登录覆盖掉新的。
            guard isCurrentGeneration(generation) else {
                LoginTrace.log("testConnection 返回时已过期，丢弃（gen \(generation)）")
                return
            }
            LoginTrace.log("testConnection 通过：凭证确实能读笔记")
            accept(cookie)
        } catch MiError.badPayload {
            // **这是 cookie 失效最常见的那条路径，必须单独拦。**
            // 凭证失效时 `i.mi.com/note/full/page/` 会 302 到登录页，最终返回
            // 200 + HTML；`getJSON` 在 JSON 解析那一步就抛 badPayload，
            // 根本走不到它里面那两处 `throw MiError.cookieInvalid`。
            // 如果不在这里拦，就会落到最后的 catch-all 被当成"网络异常"放行，
            // 界面报登录成功、实际读不了笔记 —— 而且日志里只有一句
            // "按网络问题放行"，排查时会被当成网络抖动忽略掉。
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
            // 网络异常**不能**判成登录失败——凭证本身很可能完全没问题，
            // 这时候把人赶去网页登录是误伤。先接受，让真正需要网络的「拉取」
            // 那一步去报错，那里的提示更具体。
            guard isCurrentGeneration(generation) else { return }
            LoginTrace.log("testConnection 异常，按网络问题放行：\(error.localizedDescription)")
            accept(cookie)
        }
    }

    /// 这份结果是否属于当前这一轮会话。
    private func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == sessionGeneration
    }

    /// 校验通过：记下凭证、收掉二维码那一侧的临时状态。
    private func accept(_ cookie: String) {
        LoginTrace.log("accept：登录成功，凭证含 \(cookie.split(separator: ";").count) 个 Cookie")
        self.cookie = cookie
        qrError = nil
        qrExpired = false
        // 轮询与倒计时都到此为止，别让它们继续跑
        stopPolling()
    }

    private func clearPasswordSession() {
        passwordSession = nil
        passwordParams = nil
        captchaURL = nil
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

    // MARK: 派生状态（界面直接消费）

    /// 状态行的颜色。
    ///
    /// 校验中必须走中性色：那时既没出错也没成功，沿用"未登录=红"会把
    /// 一次正常的等待渲染成报错，用户会以为已经失败了。
    var statusTint: Color {
        // 必须和 `statusLine` 的判断顺序**完全同源**，否则会出现
        // "这句话说的是正在获取二维码，却染成红色"的错配。
        if verifying || qrBusy { return DS.Status.idle }
        if cookie != nil { return DS.Status.ok }
        if qrError != nil { return DS.Status.bad }
        return DS.Status.idle
    }

    /// 只返回有信息量的文本：加载中、出错、已登录成功。
    /// 常态（等待扫码）返回 nil——「等待扫码」那类文字占一行却不提供新信息。
    var statusLine: String? {
        if verifying { return "凭证已到手，正在确认它真的能读取笔记…" }
        if qrBusy { return "正在获取二维码…" }
        // 已登录优先于报错：登录成功之后残留的任何 `qrError` 都是历史消息，
        // 排在前面会让用户看到"已登录"旁边挂着一句红的失败提示。
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
