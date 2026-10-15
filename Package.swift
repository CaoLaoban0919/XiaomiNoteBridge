// swift-tools-version: 5.9
import PackageDescription

// ⚠️ 这个文件**不参与正式构建**。
//
// 正式构建走 `build.sh`：swiftc 编译 → 手工组 .app → codesign → hdiutil 打 dmg。
// swiftc 那边有 -parse-as-library、-disable-sandbox、-framework Carbon 等参数，
// 是一步步实测出来的，不能交给 SwiftPM 代劳。
//
// 那这个文件为什么存在？
//   为了让 **Xcode 正确理解项目结构**。没有它的时候，Xcode 会把整个文件夹
//   当成一个编译单元，于是 Tools/ 下的两个独立脚本（独立脚本必须写顶层代码）
//   会被当成应用源码一起编译，报出一片
//   "statements are not allowed at the top level"。
//
//   下面把应用目标限定在 Sources/，并 exclude 掉 Tools/、Resources/、build/，
//   Xcode 就知道那三个工具/资源不属于应用目标，不再误报。
//
// 改动须知：**不要往这里搬构建逻辑**。它只是给 IDE 看的结构声明。
let package = Package(
    name: "MiNoteBridge",
    // **必须和代码实际用到的 API 对齐。**
    //
    // 原来是 .v13，结果 SwiftPM 按 macOS 13 编译并校验 API，
     // `LayoutProbe.swift` 里的 `onChange(of:) { _, s in }`（两参数版）是 macOS 14 才有的，
    // 于是 `swift build` 直接失败。
    //
    // 注意 build.sh **不设部署目标**（用 SDK 默认），所以那边一直没问题——
    // 这种"正式构建能过、IDE/SwiftPM 构建过不了"的不一致，只会在别人用 Xcode 时才暴露。
    // 改这里之前先确认代码里没有更高版本的 API。
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiNoteBridge",
            path: ".",
            exclude: ["Tools", "Resources", "build", ".build"],
            sources: ["Sources"],
            linkerSettings: [
                // AEDeterminePermissionToAutomateTarget 需要
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
