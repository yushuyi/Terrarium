//
//  PyodideBridgeSmokeTests.swift
//  Terrarium（fork）
//
//  端到端冒烟：真实 WKWebView + 本地 scheme 伺服的完整离线链路。
//  在 macOS 上跑（WKWebView 于 macOS 同样可用），验证：
//    1. SchemeHandler 能离线喂出 pyodide 运行时（bootstrap 成功）
//    2. runPython 正常执行并回传 stdout
//    3. 流式 onOutput 逐行回调
//    4. import numpy（bundle 内 wheel）可用
//
//  运行：swift test --filter PyodideBridgeSmokeTests
//

import XCTest
@testable import Terrarium

@MainActor
final class PyodideBridgeSmokeTests: XCTestCase {

    /// bootstrap + 基础执行 + 流式输出（整条离线链路）
    func testBootstrapRunAndStream() async throws {
        let bridge = PyodideBridge.shared

        // 首次调用触发 bootstrap（编译 wasm，耗时数十秒属正常）
        try await bridge.awaitReady()

        var streamed: [String] = []
        let result = await bridge.runPython(
            code: "print('hello from pyodide')\nprint('line two')",
            onOutput: { line in
                if !line.isStderr { streamed.append(line.text) }
            },
            timeout: 120
        )

        XCTAssertEqual(result.exitCode, 0, "exception: \(result.exception ?? "nil") / stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("hello from pyodide"), "stdout: \(result.stdout)")
        XCTAssertTrue(streamed.contains("hello from pyodide"), "流式回调未收到输出: \(streamed)")
        XCTAssertTrue(streamed.contains("line two"), "流式回调缺行: \(streamed)")
    }

    /// bundle 内闭包包可用（numpy 走本地 wheel，不走 CDN）
    func testNumpyFromOfflineBundle() async throws {
        let bridge = PyodideBridge.shared
        try await bridge.awaitReady()

        let result = await bridge.runPython(
            code: """
            import numpy as np
            a = np.array([1, 2, 3])
            print("sum:", int(a.sum()))
            """,
            onOutput: nil,
            timeout: 120
        )

        XCTAssertEqual(result.exitCode, 0, "exception: \(result.exception ?? "nil") / stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("sum: 6"), "stdout: \(result.stdout)")
    }

    /// 核心验收场景：pandas DataFrame（实施方案 Phase 3 用例，macOS 预演）
    func testPandasFromOfflineBundle() async throws {
        let bridge = PyodideBridge.shared
        try await bridge.awaitReady()

        let result = await bridge.runPython(
            code: """
            import pandas as pd
            df = pd.DataFrame({'a': [1, 2, 3]})
            print("total:", int(df['a'].sum()))
            """,
            onOutput: nil,
            timeout: 180
        )

        XCTAssertEqual(result.exitCode, 0, "exception: \(result.exception ?? "nil") / stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("total: 6"), "stdout: \(result.stdout)")
    }
}
