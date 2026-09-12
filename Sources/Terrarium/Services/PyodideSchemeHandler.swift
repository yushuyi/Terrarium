//
//  PyodideSchemeHandler.swift
//  Terrarium（fork）
//
//  自定义 URL scheme「pyodide-local://」的本地资源伺服。
//
//  为什么需要它：WKWebView 里 fetch()/XHR 对 file:// 一律拒绝
//  （loadFileURL 的读权限只覆盖 <script>/<img> 等子资源），而 Pyodide
//  加载 wasm / stdlib / wheel 全靠 fetch。用 WKURLSchemeHandler 从
//  App Bundle 伺服资源即可完全离线，且宿主页与资源全同源，无 CORS 变数。
//
//  URL 约定：
//    pyodide-local://bundle/<file>  → Bundle 内 pyodide-runtime/<file>
//    pyodide-local://host/<file>    → Bundle 内 pyodide-host/<file>
//
//  注意：.wasm 必须返回 Content-Type: application/wasm，
//  否则 WebAssembly.instantiateStreaming 会拒收。
//

import Foundation
import WebKit

final class PyodideSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "pyodide-local"

    /// scheme host → Bundle 内资源目录名
    private static let hostToDirectory = [
        "bundle": "pyodide-runtime",
        "host": "pyodide-host",
    ]

    /// 已被 stop 的任务——之后对它调用 didReceive 会崩溃，必须过滤
    private let lock = NSLock()
    private var stoppedTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              url.scheme == Self.scheme,
              let dirName = url.host.flatMap { Self.hostToDirectory[$0] },
              let base = Self.resourceDirectory(dirName),
              let relative = url.path.removingPercentEncoding,
              relative.count > 1 else {
            respond(task, status: 404, body: Data("pyodide-local: invalid request".utf8))
            return
        }

        // 防目录穿越 + 存在性检查
        let fileURL = base.appendingPathComponent(String(relative.dropFirst()))
        guard fileURL.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            respond(task, status: 404, body: Data("pyodide-local: not found: \(url.lastPathComponent)".utf8))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": Self.mimeType(for: fileURL.pathExtension),
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "*",
                ]
            )!
            deliver(task) { task.didReceive(response) }
            deliver(task) { task.didReceive(data) }
            deliver(task) { task.didFinish() }
        } catch {
            respond(task, status: 500, body: Data("pyodide-local: read failed: \(error)".utf8))
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock()
        stoppedTasks.insert(ObjectIdentifier(task))
        lock.unlock()
    }

    // MARK: - Helpers

    private func deliver(_ task: WKURLSchemeTask, _ block: () -> Void) {
        lock.lock()
        let stopped = stoppedTasks.contains(ObjectIdentifier(task))
        lock.unlock()
        if !stopped { block() }
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, body: Data) {
        guard let url = task.request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain; charset=utf-8"]
        )!
        deliver(task) { task.didReceive(response) }
        deliver(task) { task.didReceive(body) }
        deliver(task) { task.didFinish() }
    }

    private static func resourceDirectory(_ name: String) -> URL? {
        if let dir = Bundle.module.url(forResource: name, withExtension: nil) {
            return dir
        }
        // 兜底：SPM 资源目录直接以子目录形式存在于资源 bundle 根
        return Bundle.module.resourceURL?.appendingPathComponent(name, isDirectory: true)
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wasm": return "application/wasm"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "html": return "text/html"
        case "zip", "whl": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}
