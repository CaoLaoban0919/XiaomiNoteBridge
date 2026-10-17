import SwiftUI
import AppKit

// 对话式 AI 助手。
//
// 三层结构，从上到下固定：标题行 → 消息区 → 输入区。
// 消息区与输入区之间用分隔线断开，是因为输入区随时可能多出一行待发附件卡片，
// 没有分隔线时那排卡片看起来像最后一条消息的一部分。
//
// 三条设计取舍：
// 1. **气泡宽度不设固定值。** 用「另一侧留一段 Spacer」把气泡挤向目标边，
//    宽屏下长回答能自然占满，窄屏下又不会溢出——写死 maxWidth 两头都要照顾。
// 2. **失败提示留在气泡里，不改用 alert。** 出错的是这一条回复，
//    弹窗会遮住上下文，用户想对照着改问题时反而看不到了。
// 3. **空状态与消息列表叠在同一个滚动容器上。** 空状态要真正垂直居中，
//    塞进 ScrollView 里只能靠算高度，叠一层 ZStack 是免费的。

// MARK: - 界面

struct AIChatView: View {

    @ObservedObject private var session: AIChatSession
    /// 是否正在看附件详情列表
    @State private var showingAttachmentList = false
    /// 点「写入这条笔记」时的回调。为 nil 时不显示按钮（例如没有关联笔记的场景）。
    var onApply: ((String) -> Void)?

    /// 引导用的示例提问。都指向「笔记 + 数据」这条主线，
    /// 用户点一下就明白这个助手能拿附件干活，而不是只能闲聊。
    private static let examples = [
        "把这段文字精简到一半",
        "对比这两张表有什么差异",
        "把表格里的旧名称批量替换成新的"
    ]

    private static let scrollAnchor = "ai.chat.bottom"

    init(session: AIChatSession, onApply: ((String) -> Void)? = nil) {
        self.session = session
        self.onApply = onApply
    }

    var body: some View {
        // 最精简形态：没有标题栏，只有「消息区 + 输入区」。
        // 这块嵌在详情栏里，外层已经写明是哪条笔记，再加一行"AI 助手"
        // 只是把上下文重复一遍，还占掉一行高度。
        VStack(spacing: 0) {
            // `minHeight: 0` + 给输入区更高的布局优先级，是必须的：
            // ScrollView 在 VStack 里会尽可能索要空间，高度只有 68 时
            // 它会把 composer 挤出可视区——表现就是"对话框跑到图层下面"。
            transcript
                .frame(minHeight: 0)
                // 高度被压到很小时，消息区里的内容（气泡、空状态文字）
                // 会溢出到 AI 区外面，视觉上像"压到了图层下面"。裁掉即可。
                .clipped()

            // **只在有消息时才画分隔线。**
            // 空对话时 transcript 高度是 0，线上面什么都没有，
            // 留下的就是"一根线上方空了一层"的观感。线是给内容分段的，
            // 没有内容就不该有它。
            if !session.messages.isEmpty {
                Divider()
            }

            // 附件缩略预览：只在选了文件时出现，发出去就自动消失。
            if !session.pending.isEmpty {
                attachmentPreview
            }

            composer
                .layoutPriority(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingAttachmentList) {
            attachmentListSheet
        }
    }

    // MARK: 标题

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(DS.Palette.accent)
            Text("AI 助手").font(DS.Fonts.cardTitle)
            Spacer(minLength: 0)
            // 清空是不可撤销的动作，但这里不做二次确认：
            // 对话本身就是一次性的草稿，多一层弹窗只会拖慢"问下一题"的节奏。
            Button("清空对话") { session.clear() }
                .controlSize(.small)
                .disabled(session.isSending || session.isEmpty)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }

    // MARK: 消息区

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(session.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    .padding(DS.Space.l)
                }
                .onChange(of: session.messages.count) { _, _ in
                    // 新消息的插入点永远在底部，所以滚到末尾即可，
                    // 不需要记住"用户当前看到哪一条"——对话本身就是线性往下读的。
                    guard let last = session.messages.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// 用户消息靠右、助手消息靠左。
    ///
    /// 用 Spacer 而不是 `frame(maxWidth:alignment:)` 来分边：
    /// 后者会把气泡拉伸到整行宽，多行回答看起来像一整块色块。
    private func messageRow(_ message: AIChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: DS.Space.xl) }

            bubble(message)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(bubbleFill(message.role),
                            in: RoundedRectangle(cornerRadius: DS.Radius.l))
                .fixedSize(horizontal: false, vertical: true)

            if message.role == .assistant { Spacer(minLength: DS.Space.xl) }
        }
    }

    private func bubbleFill(_ role: AIChatMessage.Role) -> Color {
        role == .user ? DS.Palette.accent : DS.Palette.surface
    }

    @ViewBuilder
    private func bubble(_ message: AIChatMessage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: DS.Optical.snug) {
                    ForEach(message.attachments) { item in
                        attachmentLine(item, emphasized: message.role == .user)
                    }
                }
            }

            switch message.state {
            case .sending:
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("正在思考…")
                        .font(DS.Fonts.body)
                        .foregroundStyle(.secondary)
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Status.warn)
                        Text(reason)
                            .font(DS.Fonts.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 重试就地点、就在这条气泡里：用户刚看到原因，
                    // 让他换个位置再找按钮，等于把"知道该干什么"和"能干什么"拆开了。
                    Button("重试") { session.retry() }
                        .controlSize(.small)
                        .disabled(!session.canRetry)
                }
            case .done:
                if !message.text.isEmpty {
                    if message.role == .assistant {
                        // 助手回复渲染 Markdown：模型输出的是 `**粗体**`、表格、列表这类标记，
                        // 直接当纯文本显示就是一堆星号和竖线。
                        // 用户自己的消息不渲染——他们说的话就是原意，不该被当成语法。
                        ChatMarkdown(text: message.text, bodySize: 13)
                            .foregroundStyle(.primary)
                    } else {
                        Text(message.text)
                            .font(DS.Fonts.body)
                            .foregroundStyle(DS.Palette.onAccent)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 助手回复下方给一个「写入这条笔记」。
                // 对话里最有用的动作就是"照这个改"；让用户复制粘贴、
                // 再自己找位置替换，等于把 AI 的价值砍掉一半。
                if message.role == .assistant,
                   !message.text.isEmpty,
                   let onApply {
                    Button("写入这条笔记") { onApply(message.text) }
                        .controlSize(.small)
                        .help("用这段内容替换当前笔记的正文")
                }
            }
        }
    }

    private func attachmentLine(_ item: ChatAttachment, emphasized: Bool) -> some View {
        HStack(spacing: DS.Optical.compact) {
            Image(systemName: item.symbolName)
                .font(.system(size: 11))
            Text(item.summaryLine)
                .font(DS.Fonts.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(emphasized ? DS.Palette.onAccent.opacity(0.85) : .secondary)
    }

    // MARK: 附件预览

    /// 待发附件的缩略预览。
    ///
    /// 最多露 6 个：再多就撑满一行，把输入框挤走。
    /// 超过 6 个时最后一个变成「+N」，点它看完整列表。
    private var attachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                ForEach(Array(session.pending.prefix(6))) { item in
                    Button {
                        showingAttachmentList = true
                    } label: {
                        thumbnail(item)
                    }
                    .buttonStyle(.plain)
                    .help(item.summaryLine)
                }

                if session.pending.count > 6 {
                    Button {
                        showingAttachmentList = true
                    } label: {
                        Text("+\(session.pending.count - 6)")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.Palette.accent)
                            .frame(width: 44, height: 44)
                            .background(DS.Palette.nest,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.s))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.s)
                                    .stroke(DS.Palette.accent.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("还有 \(session.pending.count - 6) 个，点击查看全部")
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.top, DS.Space.s)
        }
    }

    /// 单个缩略图：图片显示真实画面，表格/文本显示图标。
    private func thumbnail(_ item: ChatAttachment) -> some View {
        Group {
            if item.kind == .image,
               let data = item.rawData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Palette.accent)
            }
        }
        .frame(width: 44, height: 44)
        .background(DS.Palette.nest)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.s)
                .stroke(DS.Palette.stroke, lineWidth: 1)
        )
    }

    /// 完整附件列表。缩略图只够看"有没有选上"，确认文件名和数量还得靠这里。
    private var attachmentListSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("已附加 \(session.pending.count) 个文件")
                    .font(DS.Fonts.cardTitle)
                Spacer()
                Button("完成") { showingAttachmentList = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.l)

            Divider()

            ScrollView {
                VStack(spacing: DS.Space.s) {
                    ForEach(session.pending) { item in
                        HStack(spacing: DS.Space.m) {
                            thumbnail(item)

                            VStack(alignment: .leading, spacing: DS.Optical.snug) {
                                Text(item.displayName)
                                    .font(DS.Fonts.label)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(item.kindLabel) · \(item.summaryLine)")
                                    .font(DS.Fonts.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: DS.Space.s)

                            Button {
                                session.removePending(item.id)
                                // 删光了就自动收起，留一个空列表没有意义
                                if session.pending.isEmpty { showingAttachmentList = false }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("移除")
                        }
                        .padding(DS.Space.s)
                        .background(DS.Palette.surface,
                                    in: RoundedRectangle(cornerRadius: DS.Radius.m))
                    }
                }
                .padding(DS.Space.l)
            }
        }
        .frame(width: 440, height: 380)
    }

    private func exampleButton(_ text: String) -> some View {
        Button {
            // 只填不进发送队列：示例是"半成品问题"，
            // 用户多半要补一句"哪张表""哪段文字"再发。
            session.draft = text
        } label: {
            HStack(spacing: DS.Space.s) {
                Text(text)
                    .font(DS.Fonts.label)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.m))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m)
                    .stroke(DS.Palette.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m))
        }
        .buttonStyle(.plain)
    }

    // MARK: 输入区

    private var composer: some View {
        // **输入区只留三件东西：加号、输入框、发送。**
        //
        // 附件不再单独占一行预览：那条横排会把输入框往下推，
        // 而且用户此刻还没开始打字，屏幕最珍贵的位置不该被文件名占住。
        // 选中数量改由加号上的小角标提示；发出去之后，附件会出现在消息气泡里，
        // 那才是它需要被看见的地方。
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            attachMenu
            draftField
            sendButton
        }
        .padding(DS.Space.l)
    }

    private var attachMenu: some View {
        Menu {
            // 两项各对应一个系统选择面板。异步取回后统一走 attach，
            // 视图不关心附件是怎么解析出来的。
            Button {
                Task { @MainActor in
                    let items = await AttachmentReader.pickImages()
                    session.attach(items)
                }
            } label: {
                Label("选择图片", systemImage: "photo")
            }

            Button {
                Task { @MainActor in
                    let items = await AttachmentReader.pickSpreadsheets()
                    session.attach(items)
                }
            } label: {
                Label("选择表格", systemImage: "tablecells")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: DS.Space.xl, height: DS.Space.xl)
                    .background(DS.Palette.surface, in: Circle())

                // 没有预览行之后，这里是"附件选上了没有"的唯一反馈。
                // 不显示具体文件名是为了保持加号本身的体积不变——
                // 一换成长条，三个元素的排布就散了。
                if !session.pending.isEmpty {
                    Text("\(session.pending.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Palette.onAccent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(DS.Palette.accent, in: Capsule())
                        .offset(x: 5, y: -4)
                }
            }
            .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加图片或表格")
    }

    private var draftField: some View {
        // 1–5 行自适应：低于一行放不下占位文案，高于五行会把消息区压得太窄。
        TextField("输入问题，⇧↩ 换行", text: $session.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(DS.Fonts.body)
            .lineLimit(1...5)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(DS.Palette.nest, in: RoundedRectangle(cornerRadius: DS.Radius.m))
            // **回车发送，⇧↩ 换行。**
            // 多行 TextField 里回车默认是换行，`.onSubmit` 不会被调用，
            // 所以要在按键阶段拦：Shift 按住就放行（换行），否则直接发送。
            .onKeyPress(.return) {
                // 这个重载不带 KeyPress 参数，修饰键从全局当前状态读
                if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                session.send()
                return .handled
            }
    }

    private var sendButton: some View {
        Button {
            session.send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: DS.Space.xl, height: DS.Space.xl)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .disabled(!session.canSend)
        .help("发送")
    }

    /// 待发附件：横向一排，放不下就横向滚动。
    /// 纵向堆叠会随附件数量把输入框越挤越高，而用户此时还没开始打字。
    private var pendingStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                ForEach(session.pending) { item in
                    pendingCard(item)
                }
            }
        }
    }

    private func pendingCard(_ item: ChatAttachment) -> some View {
        HStack(spacing: DS.Optical.compact) {
            Image(systemName: item.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(DS.Palette.accent)

            VStack(alignment: .leading, spacing: DS.Optical.snug) {
                Text(item.displayName)
                    .font(DS.Fonts.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.kindLabel)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(.tertiary)
            }

            Button {
                session.removePending(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("移除附件")
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Optical.compact)
        .background(DS.Palette.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.s))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.s)
                .stroke(DS.Palette.stroke, lineWidth: 1)
        )
    }
}
