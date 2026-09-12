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
import os
import WebKit

@MainActor
public enum Log {
    public static let pyodide = OSLog(subsystem: "com.yushuyi.MianshuAgentClient", category: "Pyodide")
}

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
        // 类是 @MainActor，init 已在主 actor 上——同步初始化。
        // 不能用 Task 调度：首次访问 shared 的调用方可能先于该 Task
        // 执行 awaitReady → ensureWebAttached，webView 仍为 nil 直接崩溃。
        setupWebView()
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

        webView = WKWebView(frame: CGRect(x: -1, y: -1, width: 1, height: 1), configuration: config)
        // 必须挂到 window：WebKit 对不属于可见窗口的 WebContent 进程只持
        // 后台级断言，iOS 会随时冻结该进程（JS 一进异步等待就冻），
        // 表现为 runResult 永不返回。1x1 + 近零 alpha + 禁触摸，用户不可见。
        ensureWebAttached()

        loadHostPage()
    }

    /// 把 webview 挂到 key window（幂等）。只有 webview 处于前台场景的
    /// 窗口层级内，WebKit 才为 WebContent 进程持前台断言，JS 才能持续存活。
    private func ensureWebAttached() {
        #if os(iOS)
        // setupWebView 可能尚未执行（历史调用序列防御），此时无从挂载
        guard webView != nil else { return }
        // 已挂在仍处于前台场景的 window 上 → 无需处理
        if let current = webView.window,
           current.windowScene?.activationState == .foregroundActive { return }
        // 找不到可用目标时保留现状不强拆，避免从「旧窗」退化为「无窗」
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              webView.superview !== window else { return }
        webView.removeFromSuperview()
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        // 无障碍屏蔽：alpha 0.01 达不到系统「视为隐藏」阈值，
        // 不屏蔽会进入 VoiceOver 焦点序与视图转储
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        window.addSubview(webView)
        #endif
    }

    private func loadHostPage() {
        // 宿主页经本地 scheme 加载（pyodide-local://host/host.html），
        // 与 pyodide-local://bundle/ 下的运行时资源全同源，完全离线。
        guard let url = URL(string: "\(PyodideSchemeHandler.scheme)://host/host.html") else {
            loadError = "无法构造 pyodide-local scheme URL（PyodideSchemeHandler.scheme 异常）"
            return
        }
        webView.load(URLRequest(url: url))
        seedPersistMirror()
    }

    /// 注入任务代数：loadHostPage 每次递增；旧 Task 发现代数过期即退出，
    /// 避免超时重载后新旧两个 Task 交错写同一 JS 变量。
    private var seedGeneration = 0

    /// 把 Documents 里的持久化镜像（pip 已装包的 zip）注入运行时。
    /// host.js 的 bootstrap 会等待 __MS_PERSIST_SEEDED__（15s 超时兜底），
    /// 本方法轮询页面 JS 就绪后分块注入，注入完成置位。
    private func seedPersistMirror() {
        let zipURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pyodide_persist.zip")
        // 全新安装预装机制：Documents 无持久镜像时，若 bundle 提供
        // persist 种子（Resources/pyodide_persist_seed.zip，由运行态
        // 镜像按 RECORD 瘦身而成）则释放，保证预装包开箱即用；已有
        // 镜像（覆盖安装/运行回写）不动。当前无种子资产（tushare 等
        // 由用户按需 pip install），需要预装时放入该 zip 即生效
        if !FileManager.default.fileExists(atPath: zipURL.path),
           let seed = Bundle.module.url(forResource: "pyodide_persist_seed", withExtension: "zip") {
            do {
                try FileManager.default.copyItem(at: seed, to: zipURL)
                os_log("[Pyodide] 全新安装：释放 persist 预装种子", log: Log.pyodide)
            } catch {
                os_log("[Pyodide] 种子释放失败: %{public}s", log: Log.pyodide, String(describing: error))
            }
        }
        let data = (try? Data(contentsOf: zipURL))
        let b64 = data?.base64EncodedString() ?? ""
        os_log("[Pyodide] seedPersistMirror 启动 b64len=%{public}lu", log: Log.pyodide, UInt(b64.count))
        seedGeneration += 1
        let generation = seedGeneration
        Task { @MainActor [weak self] in
            // 等 host.js 设出等待标志（页面 JS 环境就绪）；每次 probe 最多
            // 1s（超时竞速），60 次为预算上限，页面始终未就绪则放弃注入
            var probes = 0
            var sawReady = false
            while probes < 60 {
                guard let self else { return }
                guard generation == self.seedGeneration else {
                    os_log("[Pyodide] seedPersist 代数过期（页面已重载），放弃注入", log: Log.pyodide)
                    return
                }
                let probe = await self.evaluate("typeof window.__MS_PERSIST_WAIT__")
                probes += 1
                if probe == "boolean" {
                    sawReady = true
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self, self.webView != nil else { return }
            guard generation == self.seedGeneration, sawReady else {
                os_log("[Pyodide] seedPersist 页面未就绪或已重载（%{public}ld 次探针），跳过注入", log: Log.pyodide, probes)
                return
            }
            os_log("[Pyodide] seedPersist 页面就绪（%{public}ld 次探针）开始注入", log: Log.pyodide, probes)
            // 分块注入，单次 evaluate 传 MB 级字符串易触发 WebKit 上限
            var injected = 0
            if !b64.isEmpty {
                var idx = b64.startIndex
                while idx < b64.endIndex {
                    let end = b64.index(idx, offsetBy: 1_000_000, limitedBy: b64.endIndex) ?? b64.endIndex
                    let chunk = String(b64[idx..<end])
                    let op = injected == 0 ? "=" : "+="
                    _ = await self.evaluate(
                        "window.__MS_PERSIST_B64__ \(op) '\(chunk)'; 'ok'"
                    )
                    injected += 1
                    idx = end
                }
            }
            // M3 校验：比对页面侧实际长度，任何一块 evaluate 丢失都能在此暴露
            let got = await self.evaluate(
                "String(window.__MS_PERSIST_B64__ ? window.__MS_PERSIST_B64__.length : 0)"
            )
            if got == String(b64.count) {
                os_log("[Pyodide] 持久化镜像注入完成 镜像=%{public}@ 块数=%{public}d 长度校验一致",
                       log: Log.pyodide, b64.isEmpty ? "无" : "有", Int32(injected))
            } else {
                os_log("[Pyodide] 持久化镜像注入长度不符 期望=%{public}ld 实际=%{public}@（本次会话可能无包）",
                       log: Log.pyodide, b64.count, got.isEmpty ? "0" : got)
            }
            _ = await self.evaluate("window.__MS_PERSIST_SEEDED__ = true; 'seeded'")
        }
    }

    /// 持久化镜像落盘：b64 非空 → 原子写入 Documents（仅接受 zip 魔数，
    /// 防标记行伪造/数据损坏后覆盖好镜像）；b64 空串 → 删除镜像（卸载/清空同步）。
    private func storePersistMirror(base64: String) {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pyodide_persist.zip")
        guard !base64.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            os_log("[Pyodide] 持久化镜像已删除（卸载/清空同步）", log: Log.pyodide)
            return
        }
        guard let data = Data(base64Encoded: base64),
              data.starts(with: [0x50, 0x4B]) else { // PK zip 魔数
            os_log("[Pyodide] 持久化镜像数据无效（解码失败或非 zip），保留原镜像", log: Log.pyodide)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            os_log("[Pyodide] 持久化镜像已落盘 %{public}ld 字节", log: Log.pyodide, data.count)
        } catch {
            os_log("[Pyodide] 持久化镜像写入失败: %{public}@", log: Log.pyodide, String(describing: error))
        }
    }

    /// evaluateJavaScript 的 async 封装；失败/超时返回空串（注入是尽力而为）。
    /// 页面 navigation 未 commit 时 completionHandler 可能永不回调，
    /// 必须用超时竞速兜底，否则轮询 Task 卡死。
    @MainActor
    private func evaluate(_ script: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            var finished = false
            webView?.evaluateJavaScript(script) { result, _ in
                guard !finished else { return }
                finished = true
                cont.resume(returning: (result as? String) ?? "")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard !finished else { return }
                finished = true
                cont.resume(returning: "")
            }
        }
    }

    /// 预热：提前触发 bootstrap（wasm 编译 + micropip 就绪），首次执行零等待。
    /// 幂等——内部收敛到 awaitReady，与首次执行并发安全。
    public func prewarm() {
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            try? await PyodideBridge.shared.awaitReady()
            NSLog("[Pyodide] 预热完成")
        }
    }

    /// Await Pyodide finishing its bootstrap (loading the WASM module,
    /// mounting IDBFS, pre-loading micropip). Safe to call repeatedly.
    public func awaitReady() async throws {
        ensureWebAttached() // bootstrap 是冻结最高危阶段，须先确保挂窗（所有入口都经此）
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
        ensureWebAttached() // window 就绪晚于 bridge 初始化的场景兜底
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
            // pip 持久化镜像：写入 Documents，下次启动 bootstrap 注回运行时。
            // WebKit 对自定义 scheme 页面的 IndexedDB 是临时的，IDBFS 不可依赖。
            if let b64 = body["persistB64"] as? String {
                storePersistMirror(base64: b64)
            }
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
            // 卸载后镜像重生成：非空覆写、空串删除（防止被卸包重启复活）
            if let b64 = body["persistB64"] as? String {
                storePersistMirror(base64: b64)
            }
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
            // 全量清空：宿主固定回空串 → 删除 Documents 镜像
            if let b64 = body["persistB64"] as? String {
                storePersistMirror(base64: b64)
            }
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
