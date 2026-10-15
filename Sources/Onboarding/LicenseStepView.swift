import SwiftUI

/// 第 1 步：用户许可。
///
/// 排版参照 macOS 系统自带的软件许可协议界面：正文可滚动、底部按钮固定，
/// **不强制滚动到底才能同意**——强制滚动只会训练用户盲滚，而不是真的去读。
struct LicenseStepView: View {
    let onAgree: () -> Void
    let onDecline: () -> Void

    private var licenseText: String {
        if let url = Bundle.main.url(forResource: "首次使用许可", withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return "米记桥 软件许可协议\n\n未能载入协议正文。请重新安装本应用后再试。"
    }

    var body: some View {
        VStack(spacing: 0) {
            DSScreenHeader(
                title: "米记桥 软件许可协议",
                subtitle: "使用本软件之前，请完整阅读以下条款。继续使用即表示你已阅读、理解并接受全部条款。"
            )

            DSReaderPane {
                MarkdownLite(text: licenseText, bodySize: 13)
            }
            .padding(.horizontal, DS.Space.screen)

            Divider()

            DSFooter {
                Button("不同意，退出") { onDecline() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Button("同意并继续") { onAgree() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
