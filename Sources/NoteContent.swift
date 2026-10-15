import Foundation

// 渲染笔记用的**共享数据模型**。
//
// 这个文件是「笔记渲染」这条链路的接口，由两方共同依赖：
//   - 引擎侧：把笔记正文加载成 `RenderedNote`
//   - 渲染侧：把 `[NoteBlock]` 画成 SwiftUI 视图
// 两边都照这份定义来，互不 import 对方。

/// 一条笔记按需加载出来的、可直接渲染的完整内容。
struct RenderedNote {
    /// `XiaomiConvert.toHtmlFragment` 的输出（HTML 片段）
    var html: String
    /// fileId -> 图片字节。只包含已成功下载的图；缺的项渲染侧要显示占位而不是空白。
    var images: [String: Data]

    static let empty = RenderedNote(html: "", images: [:])
}

/// 段落对齐
enum NoteAlign: Equatable {
    case leading, center, trailing
}

/// 行内样式片段：一段连续、样式一致的文字。
///
/// 把一行拆成若干 run，是为了让「加粗的一部分 + 普通的一部分」能在同一个段落里渲染，
/// 而不是把每种样式拆成独立段落。
struct NoteRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var code = false
    /// 背景色，十六进制（不含 `#`）。小米的「荧光笔」标记用它。
    var background: String?
    /// 若这段文字是链接，这里是地址
    var link: String?
}

/// 块级元素。
///
/// 这个枚举**刻意只覆盖小米笔记真正会产出的形态**，不是通用 HTML 模型。
/// 依据的是 `XiaomiConvert.toHtmlFragment` 的实际输出，不是 HTML 规范。
enum NoteBlock: Equatable {
    /// `<h1>` / `<h2>` / `<h3>`（对应小米的 size / mid-size / h3-size）
    case heading(level: Int, runs: [NoteRun])
    /// `<div>` 段落。`indent` 是左缩进像素（来自 `style="margin-left:Npx"`）。
    case paragraph(align: NoteAlign, indent: Int, runs: [NoteRun])
    /// 无序项。**注意：输出是裸 `<li>`，外面没有 `<ul>`**，
    /// 类型要从 `style="list-style-type:disc"` 读，不能靠父标签判断。
    case bullet(indent: Int, runs: [NoteRun])
    /// 有序项。同上，看 `list-style-type:decimal`。
    case numbered(indent: Int, number: Int, runs: [NoteRun])
    /// 待办项。输出形态是 `<div>☑ 文字</div>`，靠开头的 ☑/☐ 判定。
    case checkbox(indent: Int, checked: Bool, runs: [NoteRun])
    /// `<blockquote>`
    case quote(runs: [NoteRun])
    /// `<pre>` / `<code>` 组成的代码块，保留原始换行
    case codeBlock(String)
    /// `<hr/>`
    case divider
    /// `<img fileid="…"/>`。
    /// **注意：它不是普通 img，没有 src**，只有小米的 fileId，
    /// 要拿这个 id 去 `RenderedNote.images` 里取字节。
    case image(fileId: String)
}
