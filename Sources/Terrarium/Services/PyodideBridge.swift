//
//  PyodideBridge.swift
//  Terrarium（fork）
//
//  在隐藏 WKWebView 中嵌入 Pyodide（CPython 3.13 编译到 WebAssembly）。
//  对外提供 async Swift API；执行走哪条通道（原生 CPython / Pyodide）
//  由宿主 App（MianShu）的路由逻辑决定，本包不做路由。
//
//  Why a WebView?
//    iOS doesn't ship a public WASM runtime usable from Swift. The most
//    reliable way to run WASM in an iOS app is to load a JS host page
//    inside WKWebView — JavaScriptCore handles the WASM, we bridge
//    Swift ↔ JS via WKScriptMessageHandler. The view is never shown.
//
//  Why bother (vs. cross-compiling wheels)?
//    Pyodide ships with ~250 pre-built WASM wheels of the scientific
//    Python stack (numpy, pandas, scipy, matplotlib, scikit-learn, …).
//    Packages download lazily from Pyodide's CDN on first import and
//    cache to disk via IDBFS. Users only pay storage for what they use,
//    and the per-package install/uninstall is wired into our existing
//    `%pip install` magic without any of mobile-forge's build pipeline.
//

import Foundation
import WebKit

@MainActor
public final class PyodideBridge: NSObject, ObservableObject {

    public static let shared = PyodideBridge()

    // MARK: Published state

    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var pyodideVersion: String?

    // MARK: Private state

    private var webView: WKWebView!
    private var messageHandler: MessageHandler!

    /// Per-call continuation map. Each `runPython`/`installPackage`/etc.
    /// generates a UUID, parks its continuation here, and the JS host
    /// posts back with the same id when done.
    private var pendingRun: [String: CheckedContinuation<PyodideRunResult, Never>] = [:]
    private var pendingInstall: [String: CheckedContinuation<PyodideInstallResult, Never>] = [:]
    private var pendingUninstall: [String: CheckedContinuation<Bool, Never>] = [:]
    private var pendingList: [String: CheckedContinuation<[PyodidePackageInfo], Never>] = [:]
    private var pendingClear: [String: CheckedContinuation<Bool, Never>] = [:]

    /// 每次运行的逐行输出回调（流式 stdout/stderr），按运行 id 索引
    private var outputHandlers: [String: (PyodideOutputLine) -> Void] = [:]

    /// Per-install progress callbacks (streamed `Collecting … / Successfully
    /// installed …` lines from micropip). Keyed by the install's call id.
    private var installProgressHandlers: [String: (String) -> Void] = [:]

    /// `bootstrap()` may be awaited by multiple callers before Pyodide has
    /// finished loading; we resume them all in `handleReady`.
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []

    // MARK: Lifecycle

    public override init() {
        super.init()
        Task { @MainActor in
            setupWebView()
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        // Default data store is persistent across launches — IDBFS state
        // (installed packages) survives app restarts automatically.
        config.websiteDataStore = .default()

        // 本地 scheme：离线伺服 Bundle 内的 pyodide 运行时与宿主页
        config.setURLSchemeHandler(PyodideSchemeHandler(), forURLScheme: PyodideSchemeHandler.scheme)

        messageHandler = MessageHandler(owner: self)
        config.userContentController.add(messageHandler, name: "terrariumPyodide")

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        webView = WKWebView(frame: .zero, configuration: config)
        // Never attached to a UIWindow. WKWebView still loads + runs JS
        // perfectly fine off-screen as long as the instance is retained.

        loadHostPage()
    }

    private func loadHostPage() {
        // 宿主页经本地 scheme 加载（pyodide-local://host/host.html），
        // 与 pyodide-local://bundle/ 下的运行时资源全同源，完全离线。
        guard let url = URL(string: "\(PyodideSchemeHandler.scheme)://host/host.html") else {
            loadError = "无法构造 pyodide-local scheme URL（PyodideSchemeHandler.scheme 异常）"
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Await Pyodide finishing its bootstrap (loading the WASM module,
    /// mounting IDBFS, pre-loading micropip). Safe to call repeatedly.
    public func awaitReady() async throws {
        if isReady { return }
        if let err = loadError {
            throw PythonError.initializationFailed("Pyodide: \(err)")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }

    // MARK: Run code

    public func runPython(code: String) async -> PyodideRunResult {
        await runPython(code: code, onOutput: nil, timeout: nil)
    }

    /// 执行 Python 代码。
    /// - Parameters:
    ///   - onOutput: 逐行输出回调（stdout/stderr 流式），行到达即触发
    ///   - timeout: 超时秒数；超时后重载宿主页（JS 死循环无法从外部
    ///     中断，进程级重置是唯一可靠杀法），并以超时错误完成本次调用
    public func runPython(
        code: String,
        onOutput: ((PyodideOutputLine) -> Void)?,
        timeout: TimeInterval?
    ) async -> PyodideRunResult {
        try? await awaitReady()
        guard isReady else {
            return PyodideRunResult(stdout: "", stderr: loadError ?? "Pyodide not ready",
                                    exception: nil, exitCode: -1, durationMs: 0)
        }
        let id = UUID().uuidString
        if let onOutput { outputHandlers[id] = onOutput }
        return await withCheckedContinuation { (cont: CheckedContinuation<PyodideRunResult, Never>) in
            pendingRun[id] = cont
            let escaped = Self.jsStringLiteral(code)
            webView.evaluateJavaScript("window.terrariumRunPython(\(Self.jsStringLiteral(id)), \(escaped));", completionHandler: nil)
            if let timeout { scheduleTimeout(id: id, timeout: timeout) }
        }
    }

    /// 超时兜底：到点仍未回结果 → 清理该次调用的状态并重载宿主页。
    /// 重载后 JS 侧会重新 bootstrap 并再次 post ready。
    private func scheduleTimeout(id: String, timeout: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, let cont = self.pendingRun.removeValue(forKey: id) else { return }
            self.outputHandlers.removeValue(forKey: id)
            self.isReady = false
            self.loadHostPage()
            cont.resume(returning: PyodideRunResult(
                stdout: "",
                stderr: "",
                exception: "执行超时（超过 \(Int(timeout)) 秒），Pyodide 运行时已重置",
                exitCode: -1,
                durationMs: Int(timeout * 1000)
            ))
        }
    }

    // MARK: Install / uninstall

    /// Install `pkg` via micropip. Progress lines stream via `onProgress`
    /// the moment they're emitted (pip-style "Collecting" / "Successfully
    /// installed" / "ERROR: …").
    public func installPackage(_ pkg: String, onProgress: ((String) -> Void)? = nil) async -> PyodideInstallResult {
        try? await awaitReady()
        guard isReady else {
            return .init(ok: false, version: nil, error: loadError ?? "Pyodide not ready")
        }
        let id = UUID().uuidString
        if let onProgress { installProgressHandlers[id] = onProgress }
        defer { installProgressHandlers.removeValue(forKey: id) }
        return await withCheckedContinuation { (cont: CheckedContinuation<PyodideInstallResult, Never>) in
            pendingInstall[id] = cont
            webView.evaluateJavaScript(
                "window.terrariumInstallPackage(\(Self.jsStringLiteral(id)), \(Self.jsStringLiteral(pkg)));",
                completionHandler: nil
            )
        }
    }

    public func uninstallPackage(_ pkg: String) async -> Bool {
        try? await awaitReady()
        guard isReady else { return false }
        let id = UUID().uuidString
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingUninstall[id] = cont
            webView.evaluateJavaScript(
                "window.terrariumUninstallPackage(\(Self.jsStringLiteral(id)), \(Self.jsStringLiteral(pkg)));",
                completionHandler: nil
            )
        }
    }

    public func listPackages() async -> [PyodidePackageInfo] {
        try? await awaitReady()
        guard isReady else { return [] }
        let id = UUID().uuidString
        return await withCheckedContinuation { (cont: CheckedContinuation<[PyodidePackageInfo], Never>) in
            pendingList[id] = cont
            webView.evaluateJavaScript(
                "window.terrariumListPackages(\(Self.jsStringLiteral(id)));",
                completionHandler: nil
            )
        }
    }

    public func clearAllPackages() async -> Bool {
        try? await awaitReady()
        guard isReady else { return false }
        let id = UUID().uuidString
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingClear[id] = cont
            webView.evaluateJavaScript(
                "window.terrariumClearPackageCache(\(Self.jsStringLiteral(id)));",
                completionHandler: nil
            )
        }
    }

    // MARK: Message handler

    fileprivate func handleMessage(_ body: [String: Any]) {
        guard let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            isReady = true
            pyodideVersion = body["version"] as? String
            for cont in readyContinuations { cont.resume(returning: ()) }
            readyContinuations.removeAll()
        case "bootstrapFailed":
            let msg = (body["error"] as? String) ?? "unknown bootstrap error"
            loadError = msg
            let err = PythonError.initializationFailed("Pyodide: \(msg)")
            for cont in readyContinuations { cont.resume(throwing: err) }
            readyContinuations.removeAll()
        case "runResult":
            guard let id = body["id"] as? String,
                  let cont = pendingRun.removeValue(forKey: id) else { return }
            outputHandlers.removeValue(forKey: id)
            cont.resume(returning: PyodideRunResult(
                stdout: (body["stdout"] as? String) ?? "",
                stderr: (body["stderr"] as? String) ?? "",
                exception: body["exception"] as? String,
                exitCode: (body["exitCode"] as? Int) ?? 0,
                durationMs: (body["durationMs"] as? Int) ?? 0
            ))
        case "stdout", "stderr":
            // 流式输出：行到达即回调；无回调方时仅由 JS 侧缓冲进 runResult
            guard let id = body["id"] as? String,
                  let line = body["line"] as? String,
                  let handler = outputHandlers[id] else { return }
            handler(PyodideOutputLine(text: line, isStderr: kind == "stderr"))
        case "installProgress":
            guard let id = body["id"] as? String,
                  let line = body["line"] as? String else { return }
            installProgressHandlers[id]?(line)
        case "installResult":
            guard let id = body["id"] as? String,
                  let cont = pendingInstall.removeValue(forKey: id) else { return }
            cont.resume(returning: PyodideInstallResult(
                ok: (body["ok"] as? Bool) ?? false,
                version: body["version"] as? String,
                error: body["error"] as? String
            ))
        case "uninstallResult":
            guard let id = body["id"] as? String,
                  let cont = pendingUninstall.removeValue(forKey: id) else { return }
            cont.resume(returning: (body["ok"] as? Bool) ?? false)
        case "listResult":
            guard let id = body["id"] as? String,
                  let cont = pendingList.removeValue(forKey: id) else { return }
            let raw = (body["packages"] as? [[String: Any]]) ?? []
            let packages = raw.compactMap { dict -> PyodidePackageInfo? in
                guard let name = dict["name"] as? String,
                      let version = dict["version"] as? String else { return nil }
                let size = (dict["size"] as? Int64) ?? Int64((dict["size"] as? Int) ?? 0)
                return PyodidePackageInfo(name: name, version: version, sizeBytes: size)
            }
            cont.resume(returning: packages)
        case "clearResult":
            guard let id = body["id"] as? String,
                  let cont = pendingClear.removeValue(forKey: id) else { return }
            cont.resume(returning: (body["ok"] as? Bool) ?? false)
        default:
            break
        }
    }

    // MARK: helpers

    /// Safely turn a Swift string into a JS string literal that can be
    /// inlined into evaluateJavaScript. We do JSON encoding so newlines,
    /// quotes, and unicode are all handled.
    private static func jsStringLiteral(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        // Strip the leading `[` and trailing `]` to get the bare literal.
        return String(raw.dropFirst().dropLast())
    }
}

// MARK: - Result types

public struct PyodideRunResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exception: String?
    public let exitCode: Int
    public let durationMs: Int
    public var isSuccess: Bool { exitCode == 0 && exception == nil }
}

/// 逐行流式输出（runPython 的 onOutput 回调载荷）
public struct PyodideOutputLine: Sendable {
    public let text: String
    public let isStderr: Bool
}

public struct PyodideInstallResult: Sendable {
    public let ok: Bool
    public let version: String?
    public let error: String?
}

public struct PyodidePackageInfo: Sendable, Identifiable, Hashable {
    public let name: String
    public let version: String
    public let sizeBytes: Int64
    public var id: String { name.lowercased() }
}

// MARK: - WKScriptMessageHandler shim
//
// MainActor isolation forces us to keep this separate — WKScriptMessageHandler
// is `@MainActor`-isolated in practice but its protocol conformance isn't.
// We bounce through a non-isolated class that holds a weak reference back
// and dispatches onto the main actor.

private final class MessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PyodideBridge?
    init(owner: PyodideBridge) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor [weak owner] in
            owner?.handleMessage(body)
        }
    }
}
