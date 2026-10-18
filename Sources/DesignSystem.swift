import SwiftUI

/// 全局设计系统。所有界面只允许从这里取值，不允许在视图里写魔法数字。
///
/// **尺度是一条严格的 4 基数列：4 / 8 / 12 / 16 / 24 / 28。**
/// 任何地方都不允许出现 `DS.Space.s` 这种写法——一旦 token 里开始做算术，
/// 说明是在硬凑数字而不是在使用规则，对齐就会一点点走偏。
/// 需要介于两者之间的值时，把它吸到相邻刻度上，而不是新造一个。
///
/// 颜色一律用语义色（`primary` / `secondary` + 透明度）而不是硬编码色值，
/// 这样浅色与深色模式、以及系统强调色变化都能自动跟随。
enum DS {

    // MARK: - 尺度

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let screen: CGFloat = 28      // 页面左右留白
    }

    /// 第二档：光学微调。
    ///
    /// 这一档专门容纳 4px 以下、以及紧凑控件内部的数值。它们确实需要存在
    /// （图标和文字基线要对齐、分段控件的外框要窄一点），但**必须命名**——
    /// 留在代码里的裸数字和一个没有规则的系统没有区别。
    ///
    /// 使用边界：**Optical 只用于元素内部的视觉微调，绝不用于布局间距**。
    /// 布局间距一律走 `Space`。
    enum Optical {
        static let hairline: CGFloat = 1     // 基线对齐补偿
        static let snug: CGFloat = 2         // 卡片内标题与描述的间距
        static let tight: CGFloat = 3        // 分段控件外框
        static let compact: CGFloat = 6      // 图标与文字、控件纵向内边距
        static let control: CGFloat = 10     // 代码块等内容块的内边距
    }

    enum Radius {
        static let s: CGFloat = 7
        static let m: CGFloat = 10
        static let l: CGFloat = 12
    }

    /// 元素自身的边长（不是间距，所以不放在 Space 里）。
    ///
    /// `qrCode` 取 160pt 是权衡结果：二维码编码的是小米登录 URL（约 130 字符），
    /// 在 160pt 下每个模块约 3.5pt、Retina 屏上约 7 物理像素，扫码距离够用。
    /// 尺寸再小会开始挑扫码角度。
    ///
    /// 登录页左栏的宽度就等于这个值——栏内所有元素左对齐到同一条线，
    /// 不给二维码单独居中，否则它会和上方的标题、下方的按钮错位。
    enum Size {
        static let qrCode: CGFloat = 144

        /// 登录页右栏表单宽度。
        ///
        /// 由第一行倒推：手机号框内要同时容纳「区号块 66 + 号码区 + 发送块 78」，
        /// 号码区留 136 足够写 11 位号码，于是 66 + 136 + 78 = 280。
        ///
        /// 收紧到 280（原 300）是因为 300 时第一行的「账号」框比第二行的「密码」框
        /// 长出 100px，看着空。注意**两种模式的第一行必须同宽**，
        /// 否则跨模式对齐会被破坏，所以这里收的是整个表单而不是单独某一行。
        static let loginFormWidth: CGFloat = 280

        /// 手机号输入框给左侧区号让出的内边距。
        ///
        /// 区号是**框内的一层**（自带底色的小块），不是旁边的独立控件，
        /// 所以这里留的是"外层到内层的距离 + 内层最宽时的宽度 + 与号码的间距"：
        /// 4 + 54(+886) + 8 = 66。写成一个整值，视图里就不用做算术。
        static let phoneFieldInset: CGFloat = 66

        /// 手机号输入框给右侧「发送验证码」让出的内边距。
        ///
        /// 发送按钮同样做成**框内的一层**。这样手机号框仍然是整宽，
        /// 才能和密码模式的第一行输入框对齐——按钮放在框外会把输入框挤窄，
        /// 两种模式的输入框位置就对不上了。
        /// = 按钮文字最宽 55 + 左右内边距 16 + 外距 7 = 78。
        static let phoneFieldTrailingInset: CGFloat = 78

        /// 两种登录方式中，表单右侧行动槽的宽度。
        ///
        /// 密码模式的「验证码登录」链接与验证码模式的「返回密码登录」链接
        /// 都占这个宽度，这样两行输入框的右边缘能对齐。
        static let formSlotWidth: CGFloat = 92

        /// 人机验证弹窗的宽度。420 刚好让验证码图片不失真、输入框不显得空。
        static let captchaSheetWidth: CGFloat = 420
        /// 人机验证图片区的高度。小米的图形验证码是扁长的，不需要方块。
        static let captchaImageHeight: CGFloat = 64

        /// 网页登录兜底弹窗的尺寸。
        ///
        /// 比主窗口还大——小米的登录页是按桌面浏览器宽度设计的，
        /// 给窄了会触发它的移动端布局，元素挤成一团反而更难操作。
        static let webFallbackWidth: CGFloat = 760
        static let webFallbackHeight: CGFloat = 620

        /// 主界面左栏（功能栏）的宽度。
        ///
        /// **不设的话 SwiftUI 用系统默认值，那个默认值偏窄**：
        /// 四个分组项（全部笔记/已同步/待处理/已跳过）带图标平铺，
        /// 加上侧栏顶部还有一个 `navigationTitle`，整体会显得局促。
        ///
        /// 取 240（不是 210）—— 系统默认本来就在 200 上下，
        /// 设成 210 等于没改；240 才是肉眼可辨的加宽，同时仍像侧栏而不是内容区。
        /// min/max 给出来是为了**保留用户自己拖宽拖窄的能力**，别写死。
        static let sidebarIdealWidth: CGFloat = 240
        static let sidebarMinWidth: CGFloat = 200
        static let sidebarMaxWidth: CGFloat = 360
    }

    enum Fonts {
        static let screenTitle = Font.system(size: 20, weight: .semibold)
        static let cardTitle   = Font.system(size: 13, weight: .semibold)
        static let rowTitle    = Font.system(size: 13, weight: .medium)
        static let body        = Font.system(size: 13)
        static let label       = Font.system(size: 12)
        static let caption     = Font.system(size: 11)
    }

    /// 语义色板
    enum Palette {
        static let surface      = Color.primary.opacity(0.045)   // 卡片底
        static let surfaceDeep  = Color.primary.opacity(0.035)   // 更浅的底（协议正文）
        /// 嵌套层。用在"控件内部的子控件"上，例如手机号输入框里的区号选择器。
        ///
        /// 比 `surface` 略深一档：太浅看不出层的关系，太深又会像一个独立的按钮。
        static let nest         = Color.primary.opacity(0.08)
        static let stroke       = Color.primary.opacity(0.10)
        static let divider      = Color.primary.opacity(0.12)
        static let accent       = Color.accentColor
        /// 放在强调色实心块之上的前景色。必须跟随强调色深浅，不能用纯黑或纯白写死。
        static let onAccent     = Color.white

        static func tint(_ color: Color) -> Color { color.opacity(0.09) }
    }

    /// 状态用色（跟随系统）
    enum Status {
        static let ok = Color.green
        static let warn = Color.orange
        static let bad = Color.red
        static let idle = Color.secondary
    }

    /// 窗口尺寸。**这两个数是量出来的，不是估出来的。**
    ///
    /// 用 `MINB_MEASURE=1` 启动应用，`LayoutProbe` 会把各区块的实际渲染尺寸写进
    /// `/tmp/minb_layout.txt`。布局改动后重新量一次即可，别凭感觉调。
    ///
    /// 实测（620 宽）：标题区 75 + 内容区 435 + 分隔线 1 + 操作区 52 = 563。
    /// 窗口取 580，留 17px 余量应付"报错文案折成两行"这类情况。
    /// 留太多余量会在底部堆出一片空白，留太少会出现滚动条——两者都不好。
    static let windowSize = CGSize(width: 620, height: 580)

    /// AI 设置弹窗。
    ///
    /// 比主窗口宽 100：模型列表要显示 `deepseek-v4-flash-vision-exp` 这类长名字，
    /// 620 宽时右侧会被截成省略号，用户只能靠猜。
    /// 高度也多给了一截，让列表至少露出 4 行，不至于一进来就得滚动。
    // 660 偏紧：展开模型面板后要滚很久，底部的「清除配置」容易被推到视野外。
    static let aiSettingsWindowSize = CGSize(width: 720, height: 720)

    /// 登录步骤的窗口尺寸。
    ///
    /// 登录已改为**内嵌网页**（WKWebView 加载小米官方登录页），原来的 620×580
    /// 装不下网页内容：会出现滚动条、底部按钮被裁掉，看着像"显示不全"。
    /// 这里按小米登录页的常见布局给足空间。
    static let loginWindowSize = CGSize(width: 1000, height: 760)

    /// 主界面（三栏式）的窗口尺寸。比引导页宽——三栏布局需要横向空间。
    /// 仿 Apple 备忘录的体量：备忘录默认窗口约 1000×700。
    /// 具体尺寸等三栏界面渲染后再用 LayoutProbe 实测校正。
    static let mainWindowSize = CGSize(width: 1000, height: 680)
}

// MARK: - 液态玻璃表层

/// 统一的"表层"材质。
///
/// macOS 26（Liquid Glass）起用真正的玻璃：折射、边缘高光、按下回弹全由系统给。
/// 更早的系统回落到原来的半透明平面 —— **布局完全不变，只有材质不同**。
///
/// 为什么做成一个修饰器，而不是在每个视图里写 `if #available`：
/// 这类判断一旦散开，迟早出现"卡片是玻璃、底部栏还是平面"的割裂感。
/// 收在一处，将来换材质只改这个文件。
struct DSGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = DS.Radius.m
    var tint: Color? = nil
    /// 回退到平面时要不要描边。玻璃自带边缘高光，不需要再叠一圈线。
    var fallbackStroke: Bool = true
    var interactive: Bool = false
    /// 玻璃本身要不要吃语义色。
    ///
    /// **大面积的语义块（状态条）必须关掉它。** 系统玻璃对 tint 的放大远超过
    /// 原来平面上的 9% 淡色：一点"已授权"的绿会变成一整块高饱和绿，
    /// `secondary` 会变成两块脏灰。关掉之后只留彩色图标，颜色信息不丢，视觉却干净。
    var tintGlass: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
                .background(tint.map { DS.Palette.tint($0) } ?? DS.Palette.surface,
                            in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    if fallbackStroke {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(tint?.opacity(0.25) ?? DS.Palette.stroke, lineWidth: 1)
                    }
                }
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var value: Glass = .regular
        // 即便允许染色，也只给到 22% —— 全强度 tint 在玻璃上会压掉文字对比度。
        if let tint, tintGlass { value = value.tint(tint.opacity(0.22)) }
        if interactive { value = value.interactive() }
        return value
    }
}

extension View {
    /// 给容器套一层玻璃（不改变任何尺寸与间距）。
    func dsGlass(cornerRadius: CGFloat = DS.Radius.m,
                 tint: Color? = nil,
                 fallbackStroke: Bool = true,
                 interactive: Bool = false,
                 tintGlass: Bool = true) -> some View {
        modifier(DSGlassSurface(cornerRadius: cornerRadius,
                                tint: tint,
                                fallbackStroke: fallbackStroke,
                                interactive: interactive,
                                tintGlass: tintGlass))
    }

    /// 主操作按钮。macOS 26 起用玻璃高光样式，更早保持系统默认外观。
    @ViewBuilder
    func dsPrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self
        }
    }
}

/// 分段控件里被选中的那一片。
///
/// **只有它用玻璃，外层容器保持平面。** 玻璃叠玻璃会糊成一片，
/// 而"选中块浮在平面上"恰好是分段控件想要的层次。
struct DSGlassPill: View {
    var cornerRadius: CGFloat = DS.Radius.s

    var body: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.primary.opacity(0.04))
                .glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.primary.opacity(0.10))
        }
    }
}

// MARK: - 临时提示气泡

/// 底部居中的临时反馈：写入成功、自动保存、撤销恢复这类"刚发生"的事。
///
/// 用气泡而不是 alert：这些反馈不需要用户确认，弹窗反而要多点一下才能继续干活。
/// 材质走和全局一致的玻璃；`undo` 有值时右侧出现「撤销」。
struct DSToastBubble: View {
    let text: String
    var icon: String = "checkmark.circle.fill"
    var tint: Color = DS.Status.ok
    var undo: (() -> Void)? = nil

    var body: some View {
        if #available(macOS 26.0, *) {
            bubble.glassEffect(.regular, in: Capsule())
        } else {
            bubble
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Palette.stroke, lineWidth: DS.Optical.hairline))
        }
    }

    private var bubble: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)

            Text(text).font(DS.Fonts.label)

            if let undo {
                Button("撤销", action: undo)
                    .buttonStyle(.link)
                    .font(DS.Fonts.label)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }
}

// MARK: - 骨架组件

/// 页面头：标题 + 一句说明。所有页面统一用它，保证字号与间距一致。
struct DSScreenHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title).font(DS.Fonts.screenTitle)
            Text(subtitle)
                .font(DS.Fonts.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.screen)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }
}

/// 统一卡片。带标题时左侧显示一个小图标。
struct DSCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let title {
                HStack(spacing: DS.Optical.compact) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundStyle(tint ?? .secondary)
                    }
                    Text(title).font(DS.Fonts.cardTitle)
                }
            }
            content
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsGlass(cornerRadius: DS.Radius.m, tint: tint, fallbackStroke: tint != nil)
    }
}

/// 键值行。左侧标签固定宽度，保证多行之间对齐。
struct DSInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var mono = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Text(label)
                .font(DS.Fonts.label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : DS.Fonts.label)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// 状态条：一个图标 + 主文案 + 补充说明。权限、登录、同步结果都用它。
struct DSStatusBar: View {
    let icon: String
    let tint: Color
    let title: String
    var detail: String? = nil
    var busy = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Group {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint) }
            }
            .frame(width: 16)
            .padding(.top, DS.Optical.hairline)

            VStack(alignment: .leading, spacing: DS.Optical.snug) {
                Text(title).font(DS.Fonts.rowTitle)
                if let detail {
                    Text(detail)
                        .font(DS.Fonts.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 只让图标带语义色，整块玻璃保持中性。
        .dsGlass(cornerRadius: DS.Radius.m, tint: tint, fallbackStroke: true, tintGlass: false)
    }
}

/// 底部操作栏。所有页面统一用它，按钮尺寸与位置才不会跳。
struct DSFooter<Content: View>: View {
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DS.Space.m) {
            if let note {
                Text(note)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            content
        }
        .padding(.horizontal, DS.Space.screen)
        .padding(.vertical, DS.Space.m)
    }
}

/// 说明条目：左侧一个小图标 + 标题 + 描述。用途说明处统一用它。
struct DSBulletRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, DS.Optical.hairline)
            VStack(alignment: .leading, spacing: DS.Optical.snug) {
                Text(title).font(DS.Fonts.rowTitle)
                Text(detail)
                    .font(DS.Fonts.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 分段切换器。引导流程里凡是「二选一」的地方都用它，动画也统一在这里。
struct DSSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(options, id: \.value) { opt in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        selection = opt.value
                    }
                } label: {
                    Text(opt.label)
                        .font(.system(size: 12, weight: selection == opt.value ? .medium : .regular))
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, DS.Optical.compact)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selection == opt.value {
                                DSGlassPill(cornerRadius: DS.Radius.s)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == opt.value ? .primary : .secondary)
            }
        }
        .padding(DS.Optical.tight)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.s))
    }
}

/// 引导进度指示
struct DSStepIndicator: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                let done = index + 1 < current
                let active = index + 1 == current
                HStack(spacing: DS.Space.xs) {
                    ZStack {
                        Circle()
                            .fill(done || active ? DS.Palette.accent : Color.primary.opacity(0.12))
                            .frame(width: 16, height: 16)
                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(DS.Palette.onAccent)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(active ? DS.Palette.onAccent : Color.secondary)
                        }
                    }
                    Text(title)
                        .font(.system(size: 11, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? .primary : .secondary)
                }
                if index != steps.count - 1 {
                    Rectangle().fill(DS.Palette.divider).frame(width: DS.Space.xl, height: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.screen)
        .padding(.vertical, DS.Space.s)
    }
}

/// 可滚动正文容器。协议、权限清单这类长文本统一用它。
struct DSReaderPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsGlass(cornerRadius: DS.Radius.m, fallbackStroke: true)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
    }
}
