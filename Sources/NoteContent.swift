import Foundation

struct RenderedNote {

    var html: String

    var images: [String: Data]

    static let empty = RenderedNote(html: "", images: [:])
}

enum NoteAlign: Equatable {
    case leading, center, trailing
}

struct NoteRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var code = false

    var background: String?

    var link: String?
}

enum NoteBlock: Equatable {

    case heading(level: Int, runs: [NoteRun])

    case paragraph(align: NoteAlign, indent: Int, runs: [NoteRun])

    case bullet(indent: Int, runs: [NoteRun])

    case numbered(indent: Int, number: Int, runs: [NoteRun])

    case checkbox(indent: Int, checked: Bool, runs: [NoteRun])

    case quote(runs: [NoteRun])

    case codeBlock(String)

    case divider

    case image(fileId: String)
}
