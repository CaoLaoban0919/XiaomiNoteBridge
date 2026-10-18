import SwiftUI

struct ChatMarkdown: View {
    let text: String
    var bodySize: CGFloat = 13
    var body: some View { ChatRichContentView(text: text, bodySize: bodySize) }
}
