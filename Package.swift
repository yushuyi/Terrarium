// swift-tools-version: 5.9
//
// Terrarium（fork）— iOS 离线 Pyodide 桥接包。
//
// 本包只保留「Pyodide 桥」：在隐藏 WKWebView 中运行 Pyodide
// （CPython 3.13 编译到 WebAssembly），为宿主 App 提供
// numpy / pandas / matplotlib 等 C 扩展包的执行通道。
//
// 原生 CPython 执行由宿主负责（MianShu 内嵌 BeeWare CPython 3.14.2）。
// 上游自带的 Python.xcframework、python-stdlib、lib-dynload、
// site-packages、包管理器、脚本管理器与全部 UI 已剥离。
//
// 上游：https://github.com/haplollc/Terrarium（MIT）
// 手术记录与路由设计：MianShu 主仓 MianshuAgent/docs/Terrarium-Pyodide离线运行时-*.md
//

import PackageDescription

let package = Package(
    name: "Terrarium",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "Terrarium", targets: ["Terrarium"]),
    ],
    targets: [
        .target(
            name: "Terrarium",
            path: "Sources/Terrarium",
            resources: [
                // Pyodide WKWebView 宿主页（host.html / host.js）
                .copy("Resources/pyodide-host"),
                // 离线运行时：pyodide-core + numpy/pandas/matplotlib 依赖闭包（~30MB）
                // 由 Scripts/fetch-pyodide.sh 生成，随包提交
                .copy("Resources/pyodide-runtime"),
            ]
        ),
        // 端到端冒烟测试：在 macOS 上驱动真实 WKWebView 走完整离线链路
        // （scheme 伺服 → Pyodide bootstrap → 执行代码 → 流式输出）
        .testTarget(
            name: "TerrariumTests",
            dependencies: ["Terrarium"],
            path: "Tests/TerrariumTests"
        ),
    ]
)
