import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum AttachmentReader {

    private static let maxFileSize = 20 * 1024 * 1024

    static func pickImages() async -> [ChatAttachment] {

        let types = ["png", "jpg", "jpeg", "heic", "gif", "webp"]
            .compactMap { UTType(filenameExtension: $0) }

        let urls = runPanel(allowedTypes: types, title: "选择图片")
        guard !urls.isEmpty else { return [] }

        var out: [ChatAttachment] = []
        for url in urls {

            guard let data = readData(url) else { continue }
            out.append(ChatAttachment(kind: .image,
                                      displayName: url.lastPathComponent,
                                      rawData: data,
                                      mimeType: mimeType(forImage: url)))
        }
        return out
    }

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

        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }

        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func xlsxText(at url: URL) -> String? {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("MiNote-xlsx-\(UUID().uuidString)", isDirectory: true)

        defer {

            try? fm.removeItem(at: tmpDir)
        }

        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            try unzip(url, to: tmpDir)
        } catch {
            return nil
        }

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

    private static func unzip(_ file: URL, to dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")

        process.arguments = ["-o", "-qq", file.path, "-d", dir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus <= 1 else {
            throw NSError(domain: "AttachmentReader",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "unzip 退出码 \(process.terminationStatus)"])
        }
    }

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

    private static func parseSharedStrings(at dir: URL) -> [String] {
        let url = dir.appendingPathComponent("xl/sharedStrings.xml")
        guard let data = try? Data(contentsOf: url) else { return [] }

        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private static func parseWorksheet(at url: URL, sharedStrings: [String]) -> [[String]] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        let delegate = WorksheetParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }
}

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

            if insideSI { insideT = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {

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

private final class WorksheetParser: NSObject, XMLParserDelegate {

    private(set) var rows: [[String]] = []

    private let sharedStrings: [String]
    private var row: [String] = []

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

            if let ref = attributeDict["r"], let index = Self.columnIndex(from: ref) {
                column = index
            }
        case "v":
            insideValue = true
        case "t":

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

            while row.count < column { row.append("") }
            row.append(resolvedText())
            column += 1
            cellText = ""
            cellType = nil
        case "row":

            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                rows.append(row)
            }
            row = []
        default:
            break
        }
    }

    private func resolvedText() -> String {
        switch cellType {
        case "s":

            guard let index = Int(cellText), sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        case "inlineStr":
            return cellText
        case "b":

            return cellText == "1" ? "TRUE" : "FALSE"
        default:

            return cellText
        }
    }

    private static func columnIndex(from ref: String) -> Int? {
        var value = 0
        var sawLetter = false
        for scalar in ref.unicodeScalars {
            let ascii = scalar.value
            guard ascii >= 65, ascii <= 90 else { break }
            sawLetter = true
            value = value * 26 + Int(ascii - 64)
        }
        guard sawLetter else { return nil }
        return value - 1
    }
}
