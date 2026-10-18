import SwiftUI
import AppKit

/// 把承载视图所在的 NSWindow 调成透明。
///
/// SwiftUI 没有暴露"窗口不透明度"，只能拿到底层 `NSWindow` 改三个属性：
/// `isOpaque = false`、`backgroundColor = .clear`、`titlebarAppearsTransparent`。
/// 三者缺一不可——少设置 `isOpaque`，窗口仍会先铺一层不透明底色，玻璃就透不到桌面。
///
/// **只对引导页启用。** 主界面是三栏实心内容，窗口透明后拖动时会露出桌面，
/// 看起来像没渲染完；引导页内容少、以浮层为主，透明才有意义。
///
/// 切换状态时 SwiftUI 会重新调用 `updateNSView`，所以从引导页进主界面时
/// 窗口会被还原成不透明，不会留下"半透明主窗口"这种诡异状态。
struct WindowTransparency: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSView) {
        // 视图刚加进层级时 window 还是 nil，要等下一轮 runloop。
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let transparent = enabled
            window.isOpaque = !transparent
            window.backgroundColor = transparent ? .clear : .windowBackgroundColor
            window.titlebarAppearsTransparent = transparent
            window.isMovableByWindowBackground = transparent
        }
    }
}
