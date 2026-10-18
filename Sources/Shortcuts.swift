import AppKit
import SwiftUI

/// 编辑命令的中央路由。
///
/// **为什么不在视图里直接挂 `.keyboardShortcut`。**
/// 快捷键得出现在菜单栏里才有发现性（用户不必背文档），而菜单属于 Scene、
/// 拿不到 `MainView` 的 `@State`。这里用一个极小的单例做中转：
/// `MainView` 在出现时注册闭包，菜单只负责转发。
/// 单窗口应用，一组闭包就够；将来多窗口时把它改成按窗口注册的表即可。
@MainActor
final class EditorShortcuts: ObservableObject {

    static let shared = EditorShortcuts()

    /// 当前是否有一条可编辑的笔记。菜单按它决定置灰，避免"点了没反应"。
    @Published private(set) var hasEditableNote = false

    /// 把一条格式指令交给正文编辑器。
    var sendCommand: ((NoteEditorCommand) -> Void)?
    /// 立即把正文落盘（⌘S）。
    var flushSave: (() -> Void)?
    /// 撤销 / 重做。返回 `true` 表示已经由正文编辑器处理，不必再往下传。
    var undo: ((_ redo: Bool) -> Bool)?

    func setEditableNote(_ value: Bool) {
        guard hasEditableNote != value else { return }
        hasEditableNote = value
    }

    func send(_ command: NoteEditorCommand) {
        guard hasEditableNote else { return }
        sendCommand?(command)
    }

    func flush() {
        guard hasEditableNote else { return }
        flushSave?()
    }

    /// 撤销 / 重做：正文有焦点就交给编辑器，否则走响应者链。
    ///
    /// 为什么不能只走响应者链：WKWebView 的 `undoManager` 主要覆盖原生文本控件，
    /// 对 contenteditable 的支持并不总是可用——表现就是菜单亮着、按下去没反应。
    /// 而编辑器自己的 `.undo` 指令走的是 `document.execCommand('undo')`，
    /// 用的是 WebKit 同一个撤销栈，效果等价且确定。
    ///
    /// 反过来，也**不能**无条件交给编辑器：用户在 AI 输入框里按 ⌘Z，
    /// 要撤的是他刚打的字，不是背后的笔记正文。
    func performUndo(redo: Bool) {
        if let undo, undo(redo) { return }
        NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
    }
}
