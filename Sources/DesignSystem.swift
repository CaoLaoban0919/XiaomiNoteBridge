import SwiftUI

enum DS {

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let screen: CGFloat = 28
    }

    enum Optical {
        static let hairline: CGFloat = 1
        static let snug: CGFloat = 2
        static let tight: CGFloat = 3
        static let compact: CGFloat = 6
        static let control: CGFloat = 10
    }

    enum Radius {
        static let s: CGFloat = 7
        static let m: CGFloat = 10
        static let l: CGFloat = 12
    }

    enum Size {
        static let qrCode: CGFloat = 144

        static let loginFormWidth: CGFloat = 280

        static let phoneFieldInset: CGFloat = 66

        static let phoneFieldTrailingInset: CGFloat = 78

        static let formSlotWidth: CGFloat = 92

        static let captchaSheetWidth: CGFloat = 420

        static let captchaImageHeight: CGFloat = 64

        static let webFallbackWidth: CGFloat = 760
        static let webFallbackHeight: CGFloat = 620

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

    enum Palette {
        static let surface      = Color.primary.opacity(0.045)
        static let surfaceDeep  = Color.primary.opacity(0.035)

        static let nest         = Color.primary.opacity(0.08)
        static let stroke       = Color.primary.opacity(0.10)
        static let divider      = Color.primary.opacity(0.12)
        static let accent       = Color.accentColor

        static let onAccent     = Color.white

        static func tint(_ color: Color) -> Color { color.opacity(0.09) }
    }

    enum Status {
        static let ok = Color.green
        static let warn = Color.orange
        static let bad = Color.red
        static let idle = Color.secondary
    }

    static let windowSize = CGSize(width: 620, height: 580)

    static let aiSettingsWindowSize = CGSize(width: 720, height: 720)

    static let loginWindowSize = CGSize(width: 1000, height: 760)

    static let mainWindowSize = CGSize(width: 1000, height: 680)
}

struct DSGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = DS.Radius.m
    var tint: Color? = nil

    var fallbackStroke: Bool = true
    var interactive: Bool = false

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

        if let tint, tintGlass { value = value.tint(tint.opacity(0.22)) }
        if interactive { value = value.interactive() }
        return value
    }
}

extension View {

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

    @ViewBuilder
    func dsPrimaryButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self
        }
    }
}

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

        .dsGlass(cornerRadius: DS.Radius.m, tint: tint, fallbackStroke: true, tintGlass: false)
    }
}

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
