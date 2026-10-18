import AppKit
import SwiftUI

@MainActor
final class EditorShortcuts: ObservableObject {

    static let shared = EditorShortcuts()

    @Published private(set) var hasEditableNote = false

    var sendCommand: ((NoteEditorCommand) -> Void)?

    var flushSave: (() -> Void)?

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

    func performUndo(redo: Bool) {
        if let undo, undo(redo) { return }
        NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
    }
}
