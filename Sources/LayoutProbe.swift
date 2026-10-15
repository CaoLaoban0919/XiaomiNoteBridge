import SwiftUI

/// 布局测量探针。
///
/// 只在设置了环境变量 `MINB_MEASURE=1` 时生效，把界面各区块的**实际渲染尺寸**写进
/// `/tmp/minb_layout.txt`，用来把窗口定成"刚好装下、不用滚动"的大小。
///
/// 为什么不靠估算：字体行高、控件内边距、文字折行数都会影响最终高度，
/// 估算一次错一次。量一次就有准数了，之后每次改布局也能重新量。
///
/// 用法：
/// ```
/// MINB_MEASURE=1 ./build/MiNoteBridge.app/Contents/MacOS/MiNoteBridge
/// ```
enum LayoutProbe {

    static let enabled = ProcessInfo.processInfo.environment["MINB_MEASURE"] == "1"

    private static let url = URL(fileURLWithPath: "/tmp/minb_layout.txt")
    private static var reported = Set<String>()

    static func report(_ key: String, size: CGSize) {
        guard enabled else { return }
        // 同一 key 只记第一次出现，避免尺寸抖动把文件刷爆
        let stamp = "\(key)@\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        guard !reported.contains(stamp) else { return }
        reported.insert(stamp)

        let line = String(format: "%-22@ %4d x %4d\n",
                          key as NSString,
                          Int(size.width.rounded()),
                          Int(size.height.rounded()))
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension View {
    /// 把该视图的实际渲染尺寸报告给 `LayoutProbe`
    func measureSize(_ key: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { LayoutProbe.report(key, size: geo.size) }
                    .onChange(of: geo.size) { _, s in LayoutProbe.report(key, size: s) }
            }
        )
    }
}
