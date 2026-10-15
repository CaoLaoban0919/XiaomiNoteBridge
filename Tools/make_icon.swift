// 运行方式：swift Tools/make_icon.swift <输出路径.png>
//
//  make_icon.swift
//  MiNoteBridge
//
//  用途：用纯 CoreGraphics 绘制并导出一张 1024×1024 的 macOS 应用图标 PNG。
//
//  运行方式：
//      swift Tools/make_icon.swift /path/to/output.png
//
//  依赖：只用 Foundation / CoreGraphics / ImageIO 系统框架，无第三方库。
//
//  设计说明：
//    - 背景是 macOS 规范的「圆角矩形」（圆角半径 = 边长的 22.4%）。
//    - 底色是青绿 → 靛蓝的对角线性渐变。
//    - 前景是纯白图形：一座「桥拱」(∩ 形)，桥洞中横着三条粗线，
//      既表示「笔记的正文行」，也呼应「把内容从一端渡到另一端」的桥。
//    - 不含任何文字/字母，纯几何形状，保证小尺寸下依然可辨认。
//    - 轮廓刻意加粗（线宽 104px），缩到 16×16 时仍是一个清晰的拱形剪影。
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - 常量

/// 画布边长（正方形）。
let side: CGFloat = 1024
/// macOS 图标圆角半径 ≈ 22.4% × 边长。
let cornerRadius: CGFloat = 229
/// 圆角矩形外侧留白：图形不画满整个画布，预留系统图标的视觉边距。
let canvasSize = CGSize(width: side, height: side)

// MARK: - 命令行参数检查

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(
        "用法: swift make_icon.swift <输出路径.png>\n".data(using: .utf8)!
    )
    exit(1)
}
let outputPath = args[1]
let outputURL = URL(fileURLWithPath: outputPath)

// MARK: - 创建位图上下文
//
// 注意坐标系：CGContext 原点在左下角，y 轴向上。
// 因此「画布顶部」对应 y = side，「画布底部」对应 y = 0。
// 用 CGBitmapContext 画出来的 CGImage 存成 PNG 时不会有翻转问题：
// CG 内部会把 y-up 的绘制坐标映射到 PNG 的「首行在上」的像素排布。

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

guard let ctx = CGContext(
    data: nil,
    width: Int(side),
    height: Int(side),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    FileHandle.standardError.write("错误：无法创建 CGContext\n".data(using: .utf8)!)
    exit(1)
}

// 让 CoreGraphics 用高质量的抗锯齿插值。
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: - 1. 圆角矩形背景 + 对角渐变

let backgroundPath = CGPath(
    roundedRect: CGRect(origin: .zero, size: canvasSize),
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

ctx.saveGState()
ctx.addPath(backgroundPath)
ctx.clip()  // 后续的渐变只在这个圆角矩形内生效

// 青绿（左上）→ 靛蓝（右下）
let teal = CGColor(colorSpace: colorSpace, components: [0.12, 0.78, 0.71, 1.0])!
let indigo = CGColor(colorSpace: colorSpace, components: [0.29, 0.31, 0.83, 1.0])!
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [teal, indigo] as CFArray,
    locations: [0.0, 1.0]
)!

ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: side),      // 左上
    end: CGPoint(x: side, y: 0),        // 右下
    options: []
)
ctx.restoreGState()

// MARK: - 2. 前景图形，统一用白色

let white = CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!
ctx.setStrokeColor(white)
ctx.setFillColor(white)

// --- 2a. 桥拱（∩）：一段上半圆 + 两条竖直的桥墩 ---
//
// 用一条 open path 描边：从左桥墩底 → 上行到起拱线 → 上半圆 → 右桥墩底。
// 配合 round lineCap / lineJoin，拐角与端点都是圆头，视觉更柔和。

let archCenterX: CGFloat = 512
let archCenterY: CGFloat = 512          // 起拱线（半圆圆心）高度
let archRadius: CGFloat = 300           // 半圆半径（描边中线）
let archLineWidth: CGFloat = 104        // 粗描边
let legBottomY: CGFloat = 212           // 桥墩底端

ctx.saveGState()
ctx.setLineWidth(archLineWidth)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let archPath = CGMutablePath()
archPath.move(to: CGPoint(x: archCenterX - archRadius, y: legBottomY))          // 左桥墩底
archPath.addLine(to: CGPoint(x: archCenterX - archRadius, y: archCenterY))      // 上行到起拱线
archPath.addArc(                                                                 // 上半圆（自左向右经过顶点）
    center: CGPoint(x: archCenterX, y: archCenterY),
    radius: archRadius,
    startAngle: .pi,
    endAngle: 0,
    clockwise: true
)
archPath.addLine(to: CGPoint(x: archCenterX + archRadius, y: legBottomY))       // 下行到右桥墩底

ctx.addPath(archPath)
ctx.strokePath()
ctx.restoreGState()

// --- 2b. 桥洞里的三条「笔记行」 ---
//
// 三条圆角短横线，宽度递减，暗示一页笔记的正文。
// 放在拱洞内部（拱顶内缘以下），与桥拱共用白色，形成整体的拱形剪影。

/// 画一条居中的圆角横线。
func drawNoteLine(centerY: CGFloat, width: CGFloat, height: CGFloat) {
    let rect = CGRect(
        x: archCenterX - width / 2,
        y: centerY - height / 2,
        width: width,
        height: height
    )
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: height / 2,
        cornerHeight: height / 2,
        transform: nil
    )
    ctx.addPath(path)
    ctx.fillPath()
}

let noteLineHeight: CGFloat = 46
drawNoteLine(centerY: 618, width: 268, height: noteLineHeight)   // 第一行（最长）
drawNoteLine(centerY: 516, width: 268, height: noteLineHeight)   // 第二行
drawNoteLine(centerY: 414, width: 158, height: noteLineHeight)   // 第三行（较短）

// MARK: - 3. 导出 PNG

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write("错误：无法从 CGContext 生成 CGImage\n".data(using: .utf8)!)
    exit(1)
}

guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    "public.png" as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write("错误：无法在 \(outputPath) 创建 PNG 写入器\n".data(using: .utf8)!)
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)

guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("错误：PNG 写入失败\n".data(using: .utf8)!)
    exit(1)
}

print("已生成图标: \(outputPath) (\(Int(side))×\(Int(side)))")
