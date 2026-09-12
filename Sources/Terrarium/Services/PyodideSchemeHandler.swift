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
//  {method, headers: {..}, bodyB64?, timeoutMs?}；响应统一 JSON 信封
//  {"status","headers","bodyB64"} 固定 200 交付（Python 侧重组标准
//  HTTPResponse）；Transfer-Encoding/失真的 Content-Length 与
//  Content-Encoding 由 Swift 侧剔除，body 恒为最终原始字节。
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

    /// 已被 stop 的任务——之后对它调用 didReceive 会崩溃，必须过滤。
    /// 只记录「仍有异步交付在途」的任务（stop 时 inflightProxy 命中才插入），
    /// 交付生命周期结束即移除：防止集合无界增长，也防止已释放任务的
    /// ObjectIdentifier 地址被新任务复用而遭误判（会静默丢交付、同步 XHR 永挂）。
    private let lock = NSLock()
    private var stoppedTasks = Set<ObjectIdentifier>()

    /// 进行中的代理请求：SchemeTask 标识 → URLSessionTask（stop 时取消）
    private var inflightProxy: [ObjectIdentifier: URLSessionTask] = [:]

    /// 代理专用会话：ephemeral + 关 Cookie——沙箱请求不得携带/污染
    /// App 的 HTTPCookieStorage.shared 凭据；资源超时与请求超时同限 60s，
    /// 防慢速滴流服务器把同步 XHR 拖过 WebKit 看门狗
    private lazy var proxySession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

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
        let urlTask = inflightProxy.removeValue(forKey: taskId)
        // 仅异步在途任务需要记录 stopped；同步交付的任务（文件/错误分支）
        // 在 start 回调内主线程完成，stop 无法插队，无需记录
        if urlTask != nil {
            stoppedTasks.insert(taskId)
        }
        lock.unlock()
        urlTask?.cancel()
    }

    // MARK: - 原生网络代理

    /// 沙箱发来的请求规格（JSON r 参数）
    private struct ProxyRequestSpec: Decodable {
        let method: String?
        let headers: [String: String]?
        let bodyB64: String?
        let timeoutMs: Int?

        func urlRequest(target: URL) -> URLRequest? {
            // 只放行 http/https，防 file:// 等本地 scheme 穿越
            guard target.scheme == "http" || target.scheme == "https" else { return nil }
            var request = URLRequest(url: target)
            request.httpMethod = (method ?? "GET").uppercased()
            // 1s ~ 300s 夹取，防沙箱侧传异常值拖垮同步 XHR
            let timeoutS = Double(min(max(timeoutMs ?? 60_000, 1), 300_000)) / 1000.0
            request.timeoutInterval = timeoutS
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
        let comps = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false)
        let query = comps?.queryItems
        // 只记录目标 URL（u），不落 r 参数（内含 Authorization/Cookie 等凭据头）
        let loggedTarget = query?.first(where: { $0.name == "u" })?.value?.prefix(120) ?? "?"
        guard
            let targetB64 = query?.first(where: { $0.name == "u" })?.value,
            let reqB64 = query?.first(where: { $0.name == "r" })?.value,
            let targetData = ProxyRequestSpec.b64urlDecode(targetB64),
            let targetString = String(data: targetData, encoding: .utf8),
            let targetURL = URL(string: targetString),
            let reqData = ProxyRequestSpec.b64urlDecode(reqB64),
            let spec = try? JSONDecoder().decode(ProxyRequestSpec.self, from: reqData),
            let request = spec.urlRequest(target: targetURL)
        else {
            NSLog("[PyodideSchemeHandler] 代理请求参数无效: \(loggedTarget)")
            deliver(task) { task.didFailWithError(URLError(.badURL)) }
            return
        }

        let urlTask = proxySession.dataTask(with: request) { [weak self] data, response, error in
            // SchemeTask 只能在主线程操作；URLSession 回调线程任意
            DispatchQueue.main.async {
                guard let self else { return }
                self.lock.lock()
                self.inflightProxy.removeValue(forKey: taskId)
                let stopped = self.stoppedTasks.contains(taskId)
                if stopped {
                    // 交付生命周期在此终结，解除标记防 ObjectIdentifier 复用误判
                    self.stoppedTasks.remove(taskId)
                }
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
            // 逐项转换防「个别非 String 值导致整个头字典丢失」
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers["\(key)"] = "\(value)"
            }
            let bodyCount = data?.count ?? 0
            // URLSession 已交付解 chunk 的最终 body，原样回传的头会自相矛盾：
            // - Transfer-Encoding: chunked 必剔（body 已不再是 chunk 编码）
            // - Content-Length 与实际不符（透明解压/去 chunk）必剔，让
            //   Python 侧走 read-until-EOF（信封 body 就是完整 body）
            // - Content-Encoding 在发生透明解压时必剔，防二次解压
            headers.removeValue(forKey: "Transfer-Encoding")
            headers.removeValue(forKey: "transfer-encoding")
            let expected = http?.expectedContentLength ?? -1
            if expected < 0 || expected != bodyCount {
                headers.removeValue(forKey: "Content-Length")
                headers.removeValue(forKey: "content-length")
                headers.removeValue(forKey: "Content-Encoding")
                headers.removeValue(forKey: "content-encoding")
            }
            envelope = [
                "status": http?.statusCode ?? 502,
                "headers": headers,
                "bodyB64": data?.base64EncodedString() ?? "",
            ]
        }
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data("{}".utf8)
        let out = HTTPURLResponse(
            url: task.request.url ?? target,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            // 宿主页源是 pyodide-local://host，net 分支跨源：没有 ACAO
            // 同步 XHR 会被 CORS 拦成 status 0
            headerFields: [
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
            ]
        )!
        deliver(task) { task.didReceive(out) }
        deliver(task) { task.didReceive(body) }
        deliver(task) { task.didFinish() }
        lock.lock()
        stoppedTasks.remove(ObjectIdentifier(task))
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
