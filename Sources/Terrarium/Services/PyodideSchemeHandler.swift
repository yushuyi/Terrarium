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
//    pyodide-local://net?u=<b64url>&r=<b64url>  → 原生网络代理
//
//  网络代理为什么走 SchemeHandler 而不是 postMessage 桥：
//  - 沙箱内 requests/urllib 是同步代码，postMessage 往返是异步的，
//    同步 Python 无法等待异步回调；SchemeHandler 的响应交付由 WebKit
//    跨进程完成，页面用「同步 XMLHttpRequest」阻塞等待即可，天然兼容
//    全部同步 HTTP 库
//  - 原生 URLSession 发请求不受浏览器规则限制：Referer/CORS/UA 全部
//    可控（新浪行情等站点的 Referer 校验因此可通过）
//
//  代理协议：u = 目标 URL（b64url），r = 请求规格 JSON 的 b64url
//  {method, headers: {..}, bodyB64?}；响应镜像目标状态码，
//  目标响应头整体编码进 X-Ms-Headers（b64url JSON）供 Python 重组。
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

    /// 进行中的代理请求：SchemeTask 标识 → URLSessionTask（stop 时取消）
    private var inflightProxy: [ObjectIdentifier: URLSessionTask] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == Self.scheme else {
            respond(task, status: 404, body: Data("pyodide-local: invalid request".utf8))
            return
        }
        // 原生网络代理分支（pyodide-local://net?u=..&r=..）
        if url.host == "net" {
            startProxy(task, proxyURL: url)
            return
        }
        guard let dirName = url.host.flatMap({ Self.hostToDirectory[$0] }),
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
            // 404 是离线链路排查的关键线索，务必留日志
            NSLog("[PyodideSchemeHandler] 404: \(url.absoluteString)")
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
        let taskId = ObjectIdentifier(task)
        lock.lock()
        stoppedTasks.insert(taskId)
        let urlTask = inflightProxy.removeValue(forKey: taskId)
        lock.unlock()
        urlTask?.cancel()
    }

    // MARK: - 原生网络代理

    /// 沙箱发来的请求规格（JSON r 参数）
    private struct ProxyRequestSpec: Decodable {
        let method: String?
        let headers: [String: String]?
        let bodyB64: String?

        func urlRequest(target: URL) -> URLRequest? {
            // 只放行 http/https，防 file:// 等本地 scheme 穿越
            guard target.scheme == "http" || target.scheme == "https" else { return nil }
            var request = URLRequest(url: target)
            request.httpMethod = (method ?? "GET").uppercased()
            request.timeoutInterval = 60
            headers?.forEach { key, value in
                guard !key.isEmpty else { return }
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let bodyB64, let body = Self.b64urlDecode(bodyB64), !body.isEmpty {
                request.httpBody = body
            }
            return request
        }

        static func b64urlDecode(_ s: String) -> Data? {
            var t = s.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)
        }
    }

    private func startProxy(_ task: WKURLSchemeTask, proxyURL: URL) {
        let taskId = ObjectIdentifier(task)
        guard
            let comps = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
            let query = comps.queryItems,
            let targetB64 = query.first(where: { $0.name == "u" })?.value,
            let reqB64 = query.first(where: { $0.name == "r" })?.value,
            let targetData = ProxyRequestSpec.b64urlDecode(targetB64),
            let targetString = String(data: targetData, encoding: .utf8),
            let targetURL = URL(string: targetString),
            let reqData = ProxyRequestSpec.b64urlDecode(reqB64),
            let spec = try? JSONDecoder().decode(ProxyRequestSpec.self, from: reqData),
            let request = spec.urlRequest(target: targetURL)
        else {
            NSLog("[PyodideSchemeHandler] 代理请求参数无效: \(proxyURL.absoluteString.prefix(200))")
            deliver(task) { task.didFailWithError(URLError(.badURL)) }
            return
        }

        let urlTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // SchemeTask 只能在主线程操作；URLSession 回调线程任意
            DispatchQueue.main.async {
                guard let self else { return }
                self.lock.lock()
                self.inflightProxy.removeValue(forKey: taskId)
                let stopped = self.stoppedTasks.contains(taskId)
                self.lock.unlock()
                guard !stopped else { return }
                self.finishProxy(task, data: data, response: response, error: error, target: targetURL)
            }
        }
        lock.lock()
        let stopped = stoppedTasks.contains(taskId)
        if !stopped { inflightProxy[taskId] = urlTask }
        lock.unlock()
        guard !stopped else { urlTask.cancel(); return }
        urlTask.resume()
    }

    private func finishProxy(
        _ task: WKURLSchemeTask, data: Data?, response: URLResponse?,
        error: Error?, target: URL
    ) {
        // 统一 JSON 信封：{"status", "headers", "bodyB64"} / {"status": 0, "error"}
        // 固定 200 交付，真实状态在信封内——Python 侧零歧义解析，
        // 不依赖同步 XHR 的字符集行为
        let envelope: [String: Any]
        if let error {
            NSLog("[PyodideSchemeHandler] 代理失败 \(target.absoluteString.prefix(120)): \(error.localizedDescription)")
            envelope = ["status": 0, "error": error.localizedDescription]
        } else {
            let http = response as? HTTPURLResponse
            envelope = [
                "status": http?.statusCode ?? 502,
                "headers": http?.allHeaderFields as? [String: String] ?? [:],
                "bodyB64": data?.base64EncodedString() ?? "",
            ]
        }
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data("{}".utf8)
        let out = HTTPURLResponse(
            url: task.request.url ?? target,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        deliver(task) { task.didReceive(out) }
        deliver(task) { task.didReceive(body) }
        deliver(task) { task.didFinish() }
    }

    private static func b64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
