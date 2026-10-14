//
//  PyodideSchemeHandlerWsTests.swift
//  Terrarium（fork）
//
//  `pyodide-local://ws/snapshot` 内存伺服分支单测。用假 WKURLSchemeTask
//  真实跑一遍 handler 分支，断言响应头（CORS / Content-Length / no-store）
//  与 body —— 这些都是真机踩过的坑，靠肉眼看代码容易漏：
//    · 无 ACAO → 跨 host fetch 被拦成 status 0（net 分支历史教训）
//    · 走 respond() → 只有 text/plain，同样无 ACAO
//    · 无 no-store → WebKit 命中内存缓存，MEMFS 停在旧快照
//    · provider == nil 静默交付空 Data → 排障分不清「没 seed」与「seed 失败」
//
//  运行：swift test --filter PyodideSchemeHandlerWsTests
//

import XCTest
import WebKit
@testable import Terrarium

/// 假 SchemeTask：记录 handler 的交付序列（响应 / body / 完成 / 失败）
private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var responses: [URLResponse] = []
    private(set) var bodies: [Data] = []
    private(set) var finished = false
    private(set) var failure: Error?

    init(url: URL) {
        self.request = URLRequest(url: url)
        super.init()
    }

    func didReceive(_ response: URLResponse) { responses.append(response) }
    func didReceive(_ data: Data) { bodies.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { failure = error }

    var statusCode: Int? { (responses.first as? HTTPURLResponse)?.statusCode }
    var header: [AnyHashable: Any] { (responses.first as? HTTPURLResponse)?.allHeaderFields ?? [:] }
}

final class PyodideSchemeHandlerWsTests: XCTestCase {

    private var webView: WKWebView!

    override func setUp() {
        super.setUp()
        webView = WKWebView(frame: .zero)
        PyodideBridge.wsSnapshotProvider = nil
    }

    override func tearDown() {
        PyodideBridge.wsSnapshotProvider = nil
        webView = nil
        super.tearDown()
    }

    private func start(_ path: String) -> FakeSchemeTask {
        let url = URL(string: "pyodide-local://ws/\(path)")!
        let task = FakeSchemeTask(url: url)
        PyodideSchemeHandler().webView(webView, start: task)
        return task
    }

    // MARK: - 正常伺服

    /// 核心用例：200 + 四要素响应头 + body 与 provider 给出的数据逐字节一致
    func testWsSnapshot_servesData_withRequiredHeaders() {
        let payload = Data("[{p,d}]-snapshot-payload".utf8)
        let compressed = try? XCTUnwrap(PyodideBridge.zlibCompress(payload))
        PyodideBridge.wsSnapshotProvider = { compressed }

        let task = start("snapshot")

        XCTAssertEqual(task.statusCode, 200)
        XCTAssertEqual(task.header["Content-Type"] as? String, "application/octet-stream")
        XCTAssertEqual(task.header["Content-Length"] as? String, "\(compressed!.count)")
        XCTAssertEqual(task.header["Access-Control-Allow-Origin"] as? String, "*",
                       "跨 host fetch 必须带 ACAO，否则被拦成 status 0")
        XCTAssertEqual(task.header["Cache-Control"] as? String, "no-store",
                       "必须禁缓存，否则 MEMFS 会停在旧快照")
        XCTAssertEqual(task.bodies.first, compressed, "body 必须与 provider 数据逐字节一致")
        XCTAssertTrue(task.finished)
        XCTAssertNil(task.failure)
    }

    /// 端到端语义：伺服出来的字节能一路解回原始载荷（证明通道不篡改数据）
    func testWsSnapshot_servedBytes_roundTripThroughZlib() {
        var payload = Data()
        while payload.count < 200_000 { payload.append(Data("603517,绝味食品,12.34\n".utf8)) }
        guard let compressed = PyodideBridge.zlibCompress(payload) else { return XCTFail("压缩失败") }
        PyodideBridge.wsSnapshotProvider = { compressed }

        let served = start("snapshot").bodies.first
        guard let served else { return XCTFail("未交付 body") }
        guard let restored = PyodideBridge.zlibDecompress(served, decompressedSize: payload.count) else {
            return XCTFail("伺服字节解不回原始载荷")
        }
        XCTAssertEqual(restored, payload)
    }

    // MARK: - 异常分支

    /// provider == nil（未 seed 或已随宿主页重载清空）→ 明确 404，
    /// 不得静默交付空 Data（排障时要能区分「没 seed」与「seed 失败」）
    func testWsSnapshot_noProvider_returns404() {
        PyodideBridge.wsSnapshotProvider = nil
        let task = start("snapshot")
        XCTAssertEqual(task.statusCode, 404)
        // 404 允许带描述性 body（排障线索），但绝不能是快照数据——
        // 静默交付空 Data 会让 host.js 解压空流、报错不可分辨
        let body = task.bodies.first.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(body.hasPrefix("pyodide-local:"), "404 body 应为描述性消息，实际: \(body)")
    }

    /// provider 存在但返回 nil（压缩失败的降级态）同样 404
    func testWsSnapshot_providerReturnsNil_returns404() {
        PyodideBridge.wsSnapshotProvider = { nil }
        XCTAssertEqual(start("snapshot").statusCode, 404)
    }

    /// 只伺服 /snapshot：其它路径 404（防将来误扩展时的静默放行）
    func testWsSnapshot_otherPath_returns404() {
        PyodideBridge.wsSnapshotProvider = { Data("x".utf8) }
        XCTAssertEqual(start("manifest").statusCode, 404)
        XCTAssertEqual(start("").statusCode, 404)
    }

    /// 重置语义：置 nil 后再请求必须 404（验证 provider 真的被清掉，
    /// 漏清会让下一轮 fetch 拿到上一轮陈旧快照）
    func testWsSnapshot_resetClearsProvider() {
        PyodideBridge.wsSnapshotProvider = { Data("stale".utf8) }
        XCTAssertEqual(start("snapshot").statusCode, 200, "置位后应能伺服")
        PyodideBridge.wsSnapshotProvider = nil
        XCTAssertEqual(start("snapshot").statusCode, 404, "清空后必须 404")
    }

    // MARK: - 回归：其它 host 不受影响

    /// ws 分支不得抢走 bundle/host/net 的既有路由（分流顺序回归）
    func testOtherHosts_unaffected() {
        let bundleURL = URL(string: "pyodide-local://bundle/nonexistent-file.bin")!
        let task = FakeSchemeTask(url: bundleURL)
        PyodideSchemeHandler().webView(webView, start: task)
        XCTAssertNotEqual(task.statusCode, 200, "不存在的 bundle 资源不应 200")
    }
}
