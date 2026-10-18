import AppKit
import Foundation
import UniformTypeIdentifiers

/// 附件选择与读取。
///
/// 两个入口：图片读成原始字节交给视觉模型；表格转成**制表符分隔文本**交给语言模型。
/// 之所以把表格转成文本而不是二进制，是因为这条 AI 链路只认文本 + 图片两种输入，
/// 而「制表符 + 换行」是模型读得最准、也最省 token 的表格表示。
@MainActor
enum AttachmentReader {

    /// 单个文件上限。
    ///
    /// 附件最终要拼进请求体，20 MB 已经足够一份正常表格/截图；
    /// 超过就静默跳过（只打日志），因为从选文件到发消息之间没有合适的弹窗时机。
    private static let maxFileSize = 20 * 1024 * 1024

    // MARK: - 图片

    /// 弹选择面板挑图片，可多选。
    static func pickImages() async -> [ChatAttachment] {
        // 用扩展名反查 UTType，比硬编码 UTType.png 之类更能覆盖系统注册的类型；
        // jpg 与 jpeg 会得到同一个类型，重复无副作用。
        let types = ["png", "jpg", "jpeg", "heic", "gif", "webp"]
            .compactMap { UTType(filenameExtension: $0) }

        let urls = runPanel(allowedTypes: types, title: "选择图片")
        guard !urls.isEmpty else { return [] }

        var out: [ChatAttachment] = []
        for url in urls {
            // 图片必须拿到原始字节：视觉模型看的是像素，不是文本
            guard let data = readData(url) else { continue }
            out.append(ChatAttachment(kind: .image,
                                      displayName: url.lastPathComponent,
                                      rawData: data,
                                      mimeType: mimeType(forImage: url)))
        }
        return out
    }

    // MARK: - 表格

    /// 弹选择面板挑表格（.xlsx / .csv），可多选。
    ///
    /// 只认 xlsx 与 csv：xls 是二进制 OLE 格式，没有系统级解析器、也不值得为此写一个；
    /// numbers/pages 同理，用户可先另存为 xlsx。
    static func pickSpreadsheets() async -> [ChatAttachment] {
        let types = ["xlsx", "csv"].compactMap { UTType(filenameExtension: $0) }
        let urls = runPanel(allowedTypes: types, title: "选择表格")
        guard !urls.isEmpty else { return [] }

        var out: [ChatAttachment] = []
        for url in urls {
            guard let data = readData(url) else { continue }

            let text: String?
            switch url.pathExtension.lowercased() {
            case "xlsx":
                text = xlsxText(at: url)
            case "csv":
                text = csvText(from: data)
            default:
                text = nil
            }

            guard let text, !text.isEmpty else { continue }
            out.append(ChatAttachment(kind: .spreadsheet,
                                      displayName: url.lastPathComponent,
                                      extractedText: text))
        }
        return out
    }

    /// 从**拖拽进来的文件**生成附件。
    ///
    /// 拖拽只给一个 URL，不经过选择面板；这里按扩展名分派到同一套读取逻辑，
    /// 保证「拖进来」和「点加号选」走同一条解析路径，不会出现两种不同的行为。
    static func make(from url: URL) -> ChatAttachment? {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp":
            guard let data = readData(url) else { return nil }
            return ChatAttachment(kind: .image,
                                  displayName: name,
                                  rawData: data,
                                  mimeType: mimeType(forImage: url))

        case "xlsx":
            guard let text = xlsxText(at: url), !text.isEmpty else { return nil }
            return ChatAttachment(kind: .spreadsheet,
                                  displayName: name,
                                  extractedText: text)

        case "csv":
            guard let data = readData(url), let text = csvText(from: data), !text.isEmpty else { return nil }
            return ChatAttachment(kind: .spreadsheet,
                                  displayName: name,
                                  extractedText: text)

        case "txt", "md":
            guard let data = readData(url) else { return nil }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else { return nil }
            return ChatAttachment(kind: .text,
                                  displayName: name,
                                  extractedText: text)

        default:
            return nil
        }
    }

    // MARK: - 选择面板

    /// 同步弹面板。
    ///
    /// 在 `@MainActor` 上直接 `runModal()` 是安全的：AppKit 会自己跑一个
    /// 模态事件循环，面板照常能点能拖，不会把界面卡死。
    private static func runPanel(allowedTypes: [UTType], title: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = allowedTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    // MARK: - 读取

    /// 带体积上限地读文件。超限或读失败返回 nil（调用方跳过该文件）。
    private static func readData(_ url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxFileSize {
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            return nil
        }
    }

    /// 按扩展名推断图片 MIME。
    ///
    /// 不嗅探文件头：扩展名与实际内容不符的概率很低，而嗅探要多读一遍字节。
    private static func mimeType(forImage url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic", "heif": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    // MARK: - CSV

    /// CSV 转制表符分隔文本。
    ///
    /// 编码先试 UTF-8，再试 GB18030——国内用户导出的表格大多是 GBK 系，
    /// 只认 UTF-8 会把一大半文件读成 nil。GB18030 是 GBK/GB2312 的超集，
    /// 用它一个就够，不必再单独判断 GBK。
    private static func csvText(from data: Data) -> String? {
        var raw: String?
        if let utf8 = String(data: data, encoding: .utf8) {
            raw = utf8
        } else {
            let gb18030 = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
            raw = String(data: data, encoding: gb18030)
        }

        guard var text = raw else {
            return nil
        }

        // 去掉 UTF-8 BOM，否则第一个单元格会带一个不可见字符，影响模型识别表头
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        // Windows 换行统一成 \n，避免单元格里残留 \r
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: - XLSX

    /// 解析 xlsx，返回制表符分隔的全部行。
    ///
    /// 为什么用 `unzip` 子进程而不是自己解 ZIP：
    /// ZIP 要读中央目录、处理 deflate 压缩流，而 Swift 标准库/Foundation 都没有
    /// 公开的解压 API（只有 Compression 框架，还得自己拼 ZIP 结构）。
    /// 自己撸一个 ZIP 解析器意味着几百行容易出错、还要处理 zip64/加密/数据描述符的代码，
    /// 而 macOS 自带 `/usr/bin/unzip`，用 `Process` 调它是系统依赖、不是第三方依赖。
    /// 代价是要落盘一份临时文件，所以解析完必须删干净。
    private static func xlsxText(at url: URL) -> String? {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("MiNote-xlsx-\(UUID().uuidString)", isDirectory: true)

        defer {
            // 无论成功失败都清理，避免临时目录越积越多
            try? fm.removeItem(at: tmpDir)
        }

        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            try unzip(url, to: tmpDir)
        } catch {
            return nil
        }

        // 共享字符串表：单元格里 t="s" 时，<v> 存的是这张表的下标。
        // 文件可能不存在（纯数字表格就没有），此时按空表处理。
        let sharedStrings = parseSharedStrings(at: tmpDir)

        guard let sheetURL = firstWorksheet(in: tmpDir) else {
            return nil
        }

        let rows = parseWorksheet(at: sheetURL, sharedStrings: sharedStrings)
        guard !rows.isEmpty else { return nil }

        return rows
            .map { $0.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    /// 调系统 unzip 解包到指定目录。
    private static func unzip(_ file: URL, to dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -o 覆盖、-qq 只报错误。参数走数组，不经过 shell，文件名里有空格/引号也不会出事
        process.arguments = ["-o", "-qq", file.path, "-d", dir.path]
        try process.run()
        process.waitUntilExit()

        // 1 表示「有警告但已解出内容」，这类文件通常仍可读（比如末尾有多余字节），
        // 所以不当成失败；真正的解压错误是 2 以上。
        guard process.terminationStatus <= 1 else {
            throw NSError(domain: "AttachmentReader",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "unzip 退出码 \(process.terminationStatus)"])
        }
    }

    /// 定位第一个工作表。
    ///
    /// 已知限制：按文件名取 `sheet1.xml`，而不是按 `workbook.xml` 里的 sheet 顺序。
    /// 用户在 Excel 里拖动调整过工作表顺序时，这两个可能对不上。
    /// 只有第一个文件缺失时才退化成「取 worksheets 目录下按名字排序的第一个」。
    private static func firstWorksheet(in dir: URL) -> URL? {
        let fm = FileManager.default
        let worksheets = dir.appendingPathComponent("xl/worksheets", isDirectory: true)

        let sheet1 = worksheets.appendingPathComponent("sheet1.xml")
        if fm.fileExists(atPath: sheet1.path) { return sheet1 }

        let entries = (try? fm.contentsOfDirectory(at: worksheets,
                                                  includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// 读 `xl/sharedStrings.xml`，按出现顺序返回字符串数组。
    private static func parseSharedStrings(at dir: URL) -> [String] {
        let url = dir.appendingPathComponent("xl/sharedStrings.xml")
        guard let data = try? Data(contentsOf: url) else { return [] }

        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    /// 读工作表，返回按行组织的单元格文本。
    private static func parseWorksheet(at url: URL, sharedStrings: [String]) -> [[String]] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        let delegate = WorksheetParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }
}

// MARK: - sharedStrings 解析

/// 只关心 `<si>` 里的 `<t>`。
///
/// 一个 `<si>` 可能是富文本，内部有多个 `<r><t>` 片段（比如部分字加粗），
/// 这些片段要拼起来才是完整的单元格值，所以按 `si` 聚合而不是按 `t` 逐个存。
private final class SharedStringsParser: NSObject, XMLParserDelegate {

    private(set) var strings: [String] = []
    private var buffer = ""
    private var insideSI = false
    private var insideT = false

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "si":
            insideSI = true
            buffer = ""
        case "t":
            // 只要 si 直属的 t，`<rPh>`（日文注音）里的 t 不该混进来
            if insideSI { insideT = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // 长文本会被 XMLParser 分多次回调，所以用 += 而不是 =
        if insideT { buffer += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "t":
            insideT = false
        case "si":
            strings.append(buffer)
            buffer = ""
            insideSI = false
        default:
            break
        }
    }
}

// MARK: - 工作表解析

/// 把 `<sheetData>` 转成二维字符串数组。
///
/// 关键规则：`<c t="s"><v>3</v></c>` 里的 3 是 sharedStrings 的下标，不是数字 3；
/// 没有 `t` 属性的 `<c>` 是数值，`<v>` 就是字面值（日期也是字面值，见已知限制）。
private final class WorksheetParser: NSObject, XMLParserDelegate {

    private(set) var rows: [[String]] = []

    private let sharedStrings: [String]
    private var row: [String] = []
    /// 当前写到第几列（0 起），由单元格的 r 属性（如 "C5"）还原
    private var column = 0
    private var cellType: String?
    private var cellText = ""
    private var insideValue = false
    private var insideInlineText = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "row":
            row = []
            column = 0
        case "c":
            cellType = attributeDict["t"]
            cellText = ""
            // 有 r 就用它定列号：Excel 会省略空单元格，必须靠 r 补出空缺的列
            if let ref = attributeDict["r"], let index = Self.columnIndex(from: ref) {
                column = index
            }
        case "v":
            insideValue = true
        case "t":
            // 内联字符串写法：<c t="inlineStr"><is><t>文本</t></is></c>
            if cellType == "inlineStr" { insideInlineText = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideValue || insideInlineText { cellText += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "v":
            insideValue = false
        case "t":
            insideInlineText = false
        case "c":
            // 补齐被省略的空列，保证每行的制表符位置和列号严格对应
            while row.count < column { row.append("") }
            row.append(resolvedText())
            column += 1
            cellText = ""
            cellType = nil
        case "row":
            // 整行为空就不输出：Excel 常在末尾留一大片空行，带进上下文纯浪费 token
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                rows.append(row)
            }
            row = []
        default:
            break
        }
    }

    /// 按 `t` 属性还原单元格文本。
    private func resolvedText() -> String {
        switch cellType {
        case "s":
            // 共享字符串：<v> 是下标，查表还原
            guard let index = Int(cellText), sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        case "inlineStr":
            return cellText
        case "b":
            // 布尔值 Excel 存 0/1，直接给数字会让模型误以为是计数
            return cellText == "1" ? "TRUE" : "FALSE"
        default:
            // 数值、公式结果（t="str"）都是字面值
            return cellText
        }
    }

    /// "AB12" → 27（0 起）。
    ///
    /// 只需要字母前缀；遇到数字就停。Excel 列名是 26 进制的 A=1，
    /// 但这里要的是 0 起的下标，所以边算边减 1 的等价值：acc = acc * 26 + (c - 'A' + 1)，最后 -1。
    private static func columnIndex(from ref: String) -> Int? {
        var value = 0
        var sawLetter = false
        for scalar in ref.unicodeScalars {
            let ascii = scalar.value
            guard ascii >= 65, ascii <= 90 else { break }   // 'A'...'Z'
            sawLetter = true
            value = value * 26 + Int(ascii - 64)
        }
        guard sawLetter else { return nil }
        return value - 1
    }
}
