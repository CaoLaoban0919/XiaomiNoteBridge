import SwiftUI

enum LayoutProbe {

    static let enabled = ProcessInfo.processInfo.environment["MINB_MEASURE"] == "1"

    private static let url = URL(fileURLWithPath: "/tmp/minb_layout.txt")
    private static var reported = Set<String>()

    static func report(_ key: String, size: CGSize) {
        guard enabled else { return }

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
