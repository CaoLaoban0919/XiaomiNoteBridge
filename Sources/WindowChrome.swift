import SwiftUI
import AppKit

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
