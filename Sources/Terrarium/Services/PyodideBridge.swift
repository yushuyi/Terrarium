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
    public nonisolated static let pyodide = OSLog(subsystem: "com.yushuyi.MianshuAgentClient", category: "Pyodide")
}

// 整类主 actor：webView 创建/挂窗/evaluateJavaScript 全是主线程要求
// 的 UIKit/WebKit 操作，此前仅靠调用方恰在主线程（全新安装首启的
// 包管理页在后台 Task 调 awaitReady，ensureWebAttached 的 addSubview
// 直接崩布局引擎断言）
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
        os_log("[Pyodide] webview 已挂窗 scene=%{public}@ window=%{public}@", log: Log.pyodide, type: .info,
               window.windowScene?.activationState.rawValue.description ?? "nil", String(describing: window))
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
    ///
    /// 重载竞态防线（2026-09-18 事故）：loadHostPage 后旧页面尚未 commit、
    /// 新页面 bootstrap 未跑完时，探针可能命中旧页面残留的等待标志，把镜像
    /// 撕裂注入到新旧两页（差值恰为整块 + "undefined" 9 字符前缀）。三层防御：
    /// 1. epoch 绑定——探针必须读到「与上次已知值不同的新戳」才算新页面就绪；
    /// 2. chunk 级中止——每块注入脚本内联 epoch 校验，页面中途重载立即失效；
    /// 3. 撕裂兜底——长度校验失败时清空注入串，让 bootstrap 按「无镜像」放行，
    ///    绝不把残缺数据交给 zipfile（BadZipFile 曾致三方包全丢）。
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
            // 1s（超时竞速），60 次为预算上限，页面始终未就绪则放弃注入。
            // epoch 绑定：探针读到「与上次已知值不同的新戳」才认定本页就绪，
            // 旧页面残留的等待标志不会命中（旧页戳 == 上次已知值）
            var probes = 0
            var sawReady = false
            var epoch = ""
            while probes < 60 {
                guard let self else { return }
                guard generation == self.seedGeneration else {
                    os_log("[Pyodide] seedPersist 代数过期（页面已重载），放弃注入", log: Log.pyodide)
                    return
                }
                let probe = await self.evaluate(
                    "String(window.__MS_PERSIST_EPOCH__ || (window.__MS_PERSIST_WAIT__ ? 'legacy-wait' : ''))"
                )
                probes += 1
                if !probe.isEmpty && probe != lastKnownPersistEpoch {
                    // 新戳 = 新页面 bootstrap 已跑到这里；记录为已知值
                    lastKnownPersistEpoch = probe
                    epoch = probe
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
            os_log("[Pyodide] seedPersist 页面就绪（%{public}ld 次探针）开始注入 epoch=%{public}@",
                   log: Log.pyodide, probes, epoch)
            // 分块注入，单次 evaluate 传 MB 级字符串易触发 WebKit 上限。
            // 每块脚本内联 epoch 校验：页面中途重载（超时/异常再重载）时，
            // 剩余块在新页面上整段 no-op，绝不落到 undefined 变量上
            var injected = 0
            if !b64.isEmpty {
                var idx = b64.startIndex
                while idx < b64.endIndex {
                    guard generation == self.seedGeneration else {
                        os_log("[Pyodide] seedPersist 注入中止（代数过期，已注入 %{public}d 块）",
                               log: Log.pyodide, Int32(injected))
                        return
                    }
                    let end = b64.index(idx, offsetBy: 1_000_000, limitedBy: b64.endIndex) ?? b64.endIndex
                    let chunk = String(b64[idx..<end])
                    let op = injected == 0 ? "=" : "+="
                    _ = await self.evaluate(
                        "if (window.__MS_PERSIST_EPOCH__ === '\(epoch)') { window.__MS_PERSIST_B64__ \(op) '\(chunk)'; 'ok' } else { 'stale' }"
                    )
                    injected += 1
                    idx = end
                }
            }
            // M3 校验：比对页面侧实际长度，任何一块 evaluate 丢失都能在此暴露。
            // 失败 = 注入撕裂/丢失：清空注入串走「无镜像」路径（bootstrap 对
            // 空 b64 直接跳过恢复），绝不把残缺数据交给 zipfile
            let got = await self.evaluate(
                "String(window.__MS_PERSIST_B64__ ? window.__MS_PERSIST_B64__.length : 0)"
            )
            if got == String(b64.count) {
                os_log("[Pyodide] 持久化镜像注入完成 镜像=%{public}@ 块数=%{public}d 长度校验一致",
                       log: Log.pyodide, b64.isEmpty ? "无" : "有", Int32(injected))
            } else {
                os_log("[Pyodide] 持久化镜像注入长度不符 期望=%{public}@ 实际=%{public}@，清空按无镜像放行",
                       log: Log.pyodide, String(b64.count), got.isEmpty ? "0" : got)
                // 清空也走 epoch 校验 + 返回值判定：与块注入防线一致。
                // 迟到的清空若落在新页面，会把新页刚注入的合法 b64 置 ''——
                // 由新页 bootstrap 的 4 倍数防线兜底（本次会话无包，不崩溃）
                let cleared = await self.evaluate(
                    "if (window.__MS_PERSIST_EPOCH__ === '\(epoch)') { window.__MS_PERSIST_B64__ = ''; 'cleared' } else { 'stale' }"
                )
                if cleared.isEmpty {
                    os_log("[Pyodide] 持久化镜像清空确认超时（页面可能已重载），按无镜像放行",
                           log: Log.pyodide)
                }
            }
            // 容器根注入：host.js bootstrap 用它固化 pyodide 的 HOME
            // （与原生 CPython 的 PythonBridge.m setenv 对齐），须在
            // SEEDED 置位前就绪。容器 UUID 路径不含引号，直接拼接安全
            _ = await self.evaluate(
                "window.__MS_DOCROOT__ = '\(NSHomeDirectory())'; 'docroot'"
            )
            _ = await self.evaluate("window.__MS_PERSIST_SEEDED__ = true; 'seeded'")
        }
    }

    /// 上一次注入认定的页面 epoch（跨 loadHostPage 保留）：探针只有读到
    /// 与之不同的新戳才认定新页面就绪，旧页面残留标志不会再次命中。
    /// ponytail: 整类 @MainActor，实例属性与 static 语义等价，用实例免 Swift 6 报警
    private var lastKnownPersistEpoch = ""

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
        os_log("[Pyodide] prewarm 调用", log: Log.pyodide, type: .info)
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            try? await PyodideBridge.shared.awaitReady()
            // SPM 包内 NSLog 不落 syslog（采不到即误判预热未跑），必须 os_log
            os_log("[Pyodide] 预热完成", log: Log.pyodide, type: .info)
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

    // MARK: - 工作区快照桥（测试计划 I-4 根治）
    //
    // pyodide FS 是纯 MEMFS，Documents 对它不可见——import C 扩展包的
    // 脚本被路由到 pyodide 后，文件读写与原生侧完全脱节（第二期 I-4）。
    // 桥接机制：run 前 Swift 把 Documents 打包注入 MEMFS 容器根路径
    // （HOME 已固化，open 绝对路径即命中），run 后 host.js 收集 diff
    // 回传，Swift 写回宿主——两侧文件视图保持一致。

    /// 快照护栏：Documents 超过该字节数/文件数则放弃注入（MEMFS 退化为
    /// 隔离态，guard 的内存态警告保持启用，行为与修复前一致）
    private nonisolated static let wsMaxTotalBytes = 32 * 1024 * 1024
    private nonisolated static let wsMaxFileCount = 2000
    /// 单文件上限：大二进制（数据库/媒体）不进快照，避免注入与收集
    /// 载荷把同步 XHR/postMessage 通道拖垮（首版全量打包曾卡死 App）
    private nonisolated static let wsMaxFileBytes = 8 * 1024 * 1024
    /// 快照排除：App 私有数据目录与运行时通道文件。persist zip 走专用
    /// 镜像通道；其余是聊天/记忆/收件箱等 App 自管数据，不参与 pyodide
    /// 工作区。快照只覆盖用户工作产物（tests/、pyodide_figures/、tmp/
    /// 与脚本数据文件等）。
    /// tmp/ 曾被排除（当时的临时脚本语义），I-8 起 pyodide 的 /tmp
    /// symlink 以 Documents/tmp 为宿主落点——写回、注入、指纹必须
    /// 全链一致放行，否则 collect 对账会把写回的文件再删掉（震荡）；
    /// run_script 临时脚本自带 defer 删除 + 残留清扫，不会在快照累积
    private nonisolated static let wsExcludedPrefixes: Set<String> = [
        "Conversations/", "Memory/", "Inbox/", "CLIShims/", "backups/",
        // 原生 CPython 的 pip 安装目录（PIL/defusedxml 等 + 大量 __pycache__）：
        // 数千文件会把快照撑爆护栏（>2000 文件）导致整包跳过、MEMFS 退化为
        // 隔离态（I-4 用例 Errno 44 的根因）；且原生 3.14 的包源码不应进入
        // pyodide 3.13 的文件视图，pyodide 包体系走 persist zip 专用通道
        ".python/",
    ]
    private nonisolated static let wsExcludedFiles: Set<String> = [
        "pyodide_persist.zip", "MCPServers.json",
    ]

    /// 上次注入的 Documents 指纹（相对路径|大小|mtime 稳定排序拼接）。
    /// 收集写回后更新——宿主与 MEMFS 一致期间跳过重复注入。
    private var wsLastFingerprint: String?
    /// 当前页面已注入标志（页面重载后 JS 变量清空，须与指纹双重判断）
    private var wsInjectedIntoCurrentPage = false

    /// 显式前缀剥离取相对 Documents 路径。此前 dropFirst(count+1) 隐式
    /// 计算在真机上多剥 2 字符（'Documents'→'cuments'），排除前缀失效、
    /// restore 错位写入——改为 hasPrefix 匹配，不匹配返回 nil 由调用方跳过
    private func wsRelativePath(_ url: URL, docs: URL) -> String? {
        // standardizedFileURL 统一双方：真机 enumerator 会给出
        // /private/var/... 形态而 documentDirectory 是 /var/...，
        // 不归一化则前缀永不匹配 → 指纹恒空串 → 恒"一致"跳过注入
        let prefix = docs.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// 快照范围判定：排除 App 私有数据/大文件，只保留用户工作产物
    private func wsIncluded(_ rel: String, fileSize: Int) -> Bool {
        Self.wsIncludedImpl(rel, fileSize: fileSize)
    }

    private nonisolated static func wsIncludedImpl(_ rel: String, fileSize: Int) -> Bool {
        if wsExcludedFiles.contains(rel) || wsExcludedPrefixes.contains(where: { rel.hasPrefix($0) }) {
            return false
        }
        return fileSize <= wsMaxFileBytes
    }

    /// 打包 Documents 快照（review M6）：文件 IO + base64 全在后台线程，
    /// 避免主线程数百毫秒卡顿。entry 的 p 统一为相对容器根（Documents/
    /// 前缀），与 host.js 的 restore 落位（join(DOCROOT, p)）及收集/
    /// 写回的 key 语义一致
    private nonisolated static func packSnapshotEntries() -> ([[String: String]], String)? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let enumerator = fm.enumerator(at: docs, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return nil
        }
        var entries: [[String: String]] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let docsPath = docs.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(docsPath + "/") else { continue }
            let rel = String(path.dropFirst(docsPath.count + 1))
            guard wsIncludedImpl(rel, fileSize: values.fileSize ?? 0),
                  let data = try? Data(contentsOf: url) else { continue }
            entries.append(["p": "Documents/" + rel, "d": data.base64EncodedString()])
        }
        guard let payloadData = try? JSONSerialization.data(withJSONObject: entries),
              let payload = String(data: payloadData, encoding: .utf8) else { return nil }
        return (entries, payload)
    }

    /// Documents 递归指纹。返回 nil 表示超护栏或枚举失败（不启用快照桥）。
    private func documentsFingerprint() -> String? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let enumerator = fm.enumerator(
            at: docs,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ) else { return nil }
        var parts: [String] = []
        var totalSize = 0
        var count = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            guard let rel = wsRelativePath(url, docs: docs) else { continue }
            let size = values.fileSize ?? 0
            guard wsIncluded(rel, fileSize: size) else { continue }
            let mtime = Int((values.contentModificationDate ?? Date()).timeIntervalSince1970)
            parts.append("\(rel)|\(size)|\(mtime)")
            count += 1
            totalSize += size
            if totalSize > Self.wsMaxTotalBytes || count > Self.wsMaxFileCount { return nil }
        }
        parts.sort()
        return parts.joined(separator: "\u{1F}")
    }

    /// run 前调用：宿主 Documents 快照注入 MEMFS。
    /// 注入的是 [{p: 相对Documents路径, d: base64}] JSON（分块，单次
    /// evaluate 传 MB 级字符串易触发 WebKit 上限）；解包由 host.js 的
    /// runUser 开头执行（b64 就位时先 restore 再跑用户代码）。指纹与
    /// 页面标志双重判断，宿主未变且 MEMFS 仍持有快照时零开销跳过。
    func seedWorkspaceMirror() async -> String {
        // 必须让 JS 返回 String：boolean 会被 evaluate 的 as? String 丢弃
        let readyOnPage = await evaluate("String(window.__MS_WS_READY__ === true)")
        // 页面标志是 window 变量，pyodide 实例重建后仍可能遗留 true 而
        // MEMFS 已空——跳过判断前必须实测 MEMFS 里快照子树还在
        let memfsHasDocs = await evaluate(
            "String(pyodide.FS.analyzePath(window.__MS_DOCROOT__ + '/Documents').exists)"
        )
        if readyOnPage != "true" || memfsHasDocs != "true" {
            wsInjectedIntoCurrentPage = false
            wsLastFingerprint = nil
        }
        if wsInjectedIntoCurrentPage,
           let fp = wsLastFingerprint,
           fp == documentsFingerprint() {
            return "" // MEMFS 与宿主一致，零开销跳过
        }
        guard let fingerprint = documentsFingerprint() else {
            os_log("[Pyodide] 工作区快照跳过：Documents 超护栏（>32MB 或 >2000 文件）",
                   log: Log.pyodide)
            return ""
        }
        let packed = await Task.detached(priority: .userInitiated) {
            Self.packSnapshotEntries()
        }.value
        guard let (entries, payload) = packed else { return "" }
        var injected = 0
        var idx = payload.startIndex
        while idx < payload.endIndex {
            let end = payload.index(idx, offsetBy: 1_000_000, limitedBy: payload.endIndex) ?? payload.endIndex
            let chunk = String(payload[idx..<end])
            let op = injected == 0 ? "=" : "+="
            _ = await evaluate("window.__MS_WS_B64__ \(op) \(Self.jsStringLiteral(chunk)); 'ok'")
            injected += 1
            idx = end
        }
        // 注入完成校验（review M2）：evaluate 1s 竞速可能静默丢块，长度
        // 不符则清空 b64 并不置标志——host.js 不 restore，下轮重注入
        let actual = await evaluate("String(window.__MS_WS_B64__ ? window.__MS_WS_B64__.length : 0)")
        guard actual == String(payload.utf16.count) else {
            _ = await evaluate("window.__MS_WS_B64__ = null; 'ok'")
            os_log("[Pyodide] 工作区快照注入长度校验失败（期望 %{public}ld 实际 %{public}@），本轮不恢复",
                   log: Log.pyodide, Int32(payload.utf16.count), actual)
            return ""
        }
        wsLastFingerprint = fingerprint
        wsInjectedIntoCurrentPage = true
        os_log("[Pyodide] 工作区快照注入完成 文件数=%{public}ld payload=%{public}ld 字节",
               log: Log.pyodide, Int32(entries.count), Int32(payload.utf8.count))
        return ""
    }

    /// run 后调用：把 host.js 收集的 MEMFS 变更写回宿主 Documents。
    /// 载荷为 b64(JSON{w: {相对路径: b64内容}, d: [待删相对路径]})。
    /// 写回后重算指纹——宿主与 MEMFS 已一致，下次 run 可跳过注入。
    /// - Parameter done: 写回与指纹重算全部完成后回调（保证紧随的原生
    ///   读看到最新宿主状态）；载荷无效时同步回调
    private func applyWorkspaceWrites(base64Payload: String, done: @escaping () -> Void) {
        guard let data = Data(base64Encoded: base64Payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let writes = obj["w"] as? [String: String],
              let deletes = obj["d"] as? [String] else {
            os_log("[Pyodide] 工作区收集载荷无效，忽略", log: Log.pyodide)
            done()
            return
        }
        let docsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        // 写回 IO 放后台（review M6）不占主线程；但 run 结果在写回完成后
        // 才对工具层可见——竞态窗口已在源头消除
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.applyWritesIO(writes: writes, deletes: deletes, docsPath: docsPath)
            await MainActor.run { [weak self] in
                guard let self else { done(); return }
                // 宿主已与 MEMFS 对齐：以写回后的宿主状态重算指纹。
                // 任一写/删失败（review m4）则不置注入标志，下轮重注入自愈
                self.wsLastFingerprint = self.documentsFingerprint()
                self.wsInjectedIntoCurrentPage = !result.failed
                if result.applied > 0 {
                    os_log("[Pyodide] 工作区收集写回 %{public}ld 个文件", log: Log.pyodide, Int32(result.applied))
                }
                done()
            }
        }
    }

    /// 写回 IO（后台线程执行）：校验与落点复验见 validatedRel/validatedTarget
    private nonisolated static func applyWritesIO(writes: [String: String], deletes: [String], docsPath: String) -> (applied: Int, failed: Bool) {
        let fm = FileManager.default
        let docs = URL(fileURLWithPath: docsPath, isDirectory: true)
        let docsPrefix = docsPath + "/"
        // 路径安全（review C1）：载荷可被运行时内代码伪造 print 产生，
        // 校验必须与注入侧排除集对称——排除 App 私有数据与大文件、
        // 拒绝绝对路径/穿越/'.' 成分/空路径，并复验标准化落点仍在
        // Documents 子树内，防止 "Documents/" 与 "Documents/." 归一化
        // 后命中目录本身（递归删空整个 Documents）
        func validatedRel(_ rel: String) -> String? {
            guard !rel.hasPrefix("/"), rel.hasPrefix("Documents/") else { return nil }
            let tail = String(rel.dropFirst("Documents/".count))
            guard !tail.isEmpty else { return nil }
            let comps = tail.split(separator: "/").map(String.init)
            guard !comps.contains(".."), !comps.contains(".") else { return nil }
            guard wsIncludedImpl(tail, fileSize: 0) else { return nil }
            return tail
        }
        func validatedTarget(_ tail: String) -> URL? {
            let target = docs.appendingPathComponent(tail).standardizedFileURL
            guard target.path.hasPrefix(docsPrefix) else { return nil }
            return target
        }
        var applied = 0
        var failed = false
        for (rel, b64) in writes {
            guard let tail = validatedRel(rel),
                  let target = validatedTarget(tail),
                  let content = Data(base64Encoded: b64) else {
                os_log("[Pyodide] 工作区写回拒绝非法路径: %{public}@（越界/排除集/载荷无效）", log: Log.pyodide, rel)
                continue
            }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try content.write(to: target, options: .atomic)
                applied += 1
            } catch {
                failed = true
                os_log("[Pyodide] 工作区写回失败 %{public}@: %{public}@", log: Log.pyodide, rel, String(describing: error))
            }
        }
        for rel in deletes {
            guard let tail = validatedRel(rel), let target = validatedTarget(tail) else { continue }
            do {
                try fm.removeItem(at: target)
            } catch {
                failed = true
                os_log("[Pyodide] 工作区删除失败 %{public}@: %{public}@", log: Log.pyodide, rel, String(describing: error))
            }
        }
        return (applied, failed)
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
        await seedWorkspaceMirror() // I-4：Documents 快照注入（指纹一致时零开销跳过）
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
            // I-4：run 后工作区 diff 收集，写回宿主 Documents。
            // 写回完成（含指纹重算）后才 resume——紧随的原生读必须看到
            // 写回结果；否则批次/脚本里"pyodide 写完立刻 shell 读"会踩
            // 写回后台任务的竞态窗口
            let runOutput = PyodideRunResult(
                stdout: (body["stdout"] as? String) ?? "",
                stderr: (body["stderr"] as? String) ?? "",
                exception: body["exception"] as? String,
                exitCode: (body["exitCode"] as? Int) ?? 0,
                durationMs: (body["durationMs"] as? Int) ?? 0
            )
            if let wsB64 = body["wsWriteB64"] as? String, !wsB64.isEmpty {
                applyWorkspaceWrites(base64Payload: wsB64) { cont.resume(returning: runOutput) }
                return
            }
            cont.resume(returning: runOutput)
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
