import SwiftUI
import AppKit

struct AIChatView: View {

    @ObservedObject private var session: AIChatSession

    @State private var showingAttachmentList = false

    var onApply: ((String) -> Void)?

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

        VStack(spacing: 0) {

            transcript
                .frame(minHeight: 0)

                .clipped()

            if !session.messages.isEmpty {
                Divider()
            }

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

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(DS.Palette.accent)
            Text("AI 助手").font(DS.Fonts.cardTitle)
            Spacer(minLength: 0)

            Button("清空对话") { session.clear() }
                .controlSize(.small)
                .disabled(session.isSending || session.isEmpty)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }

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

                    guard let last = session.messages.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

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

                    Button("重试") { session.retry() }
                        .controlSize(.small)
                        .disabled(!session.canRetry)
                }
            case .done:
                if !message.text.isEmpty {
                    if message.role == .assistant {

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

    private var attachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                ForEach(Array(session.pending.prefix(6))) { item in

                    ZStack(alignment: .topTrailing) {
                        Button {
                            showingAttachmentList = true
                        } label: {
                            thumbnail(item)
                        }
                        .buttonStyle(.plain)
                        .help(item.summaryLine)

                        Button {
                            session.removeAttachment(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("移除此附件")
                        .offset(x: 5, y: -5)
                    }
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

    private var composer: some View {

        HStack(alignment: .bottom, spacing: DS.Space.s) {
            attachMenu
            skillMenu
            draftField
            sendButton
        }
        .padding(DS.Space.l)
    }

    /// 技能选择：切换会换掉 system prompt 里的行为规范（重构/总结/答疑/对话）。
    private var skillMenu: some View {
        Menu {
            ForEach(AISkill.all) { skill in
                Button {
                    session.activeSkill = skill
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(skill.name)
                            Text(skill.summary).font(.caption)
                        }
                    } icon: {
                        Image(systemName: skill.icon)
                    }
                }
            }
        } label: {
            // 每个功能键各自一颗独立的圆形玻璃按钮。
            Image(systemName: session.activeSkill.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(DS.Palette.stroke, lineWidth: 0.8))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(session.activeSkill.name)：\(session.activeSkill.summary)")
    }

    private var attachMenu: some View {
        Menu {

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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(DS.Palette.stroke, lineWidth: 0.8))
                    .contentShape(Circle())

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

        TextField("输入问题，⇧↩ 换行", text: $session.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(DS.Fonts.body)
            .lineLimit(1...5)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(DS.Palette.nest, in: RoundedRectangle(cornerRadius: DS.Radius.m))
            // 回车发送，⇧↩ 换行。
            // 多行 TextField 里回车默认插换行、`.onSubmit` 不会被调用，
            // 所以在按键阶段拦：Shift 按住就放行。
            .onKeyPress(.return) {
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
