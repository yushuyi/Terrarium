//
//  WorkspaceInjectionPlanner.swift
//  Terrarium（fork）
//
//  二期按需注入：注入集预测器（二期方案 §三「预测注入」）。
//
//  把「这条命令实际需要的文件」从 Documents 全量 included 集（实测
//  27.2MB）降到 KB~MB 级。输入是 dispatcher 信号 JSON 顶层透传的
//  argv 与 path_hints（步骤 A/B 管道），输出是本次注入集（Documents
//  相对路径集合）；返回 nil 表示回退全量注入（现行行为）。
//
//  总原则（方案 §3.1）：**宁多勿漏**——误报（多搬一个文件）代价 KB 级
//  传输，无害且有护栏兜底；漏报（读了没预测到）代价是一整轮补漏重跑。
//  优化目标是压漏报率，不是省字节。
//
//  回退语义（方案 §0 原则「保守降级，永不比现状差」）：argv 缺失 /
//  脚本定位失败 / 注入集超护栏 → nil，调用方落全量。
//

import Foundation

enum WorkspaceInjectionPlanner {

    /// 根散配置类文件的体积上限（方案 §3.1：Documents 根散 <256KB 的
    /// 配置类——.env 等——常驻注入集，成本低）
    nonisolated static let rootScatterConfigMaxBytes = 256 * 1024

    /// 注入集体积/数量超限（回退全量的信号）
    struct OverLimitError: Error {}

    // MARK: - 入口

    /// 计算本次注入集。
    ///
    /// - Parameters:
    ///   - argv: dispatcher 透传的 [prog] + sys.argv[1:]（argv[0] 为脚本
    ///     路径，-c 形态为 "-c"）；nil = 管道未通，回退全量
    ///   - pathHints: dispatcher 两层扫描归一后的绝对路径候选（相对 token
    ///     的 cwd 解析已在 dispatcher 侧完成，本层不做 cwd 语义——审查
    ///     P2-4 修订）；nil/空 = 无字面量提示，仍有 argv/import 面兜底
    ///   - docsPath: 宿主 Documents 绝对路径（测试注入临时目录用）
    ///   - fm: 文件系统门面（测试注入）
    /// - Returns: 注入集（Documents 相对路径集合）；nil = 回退全量
    nonisolated static func plan(
        argv: [String]?,
        pathHints: [String]?,
        docsPath: String,
        fm: FileManager = .default
    ) -> Set<String>? {
        guard let argv, !argv.isEmpty else { return nil }
        do {
            var acc = Accumulator()

            // ── ① 脚本定位 + 本地 import 可见面（承重，审查 P1-2）──
            // dispatcher 给 Pyodide 的 sys.path 补插四层：sd ∪ p1 ∪ root
            // ∪ office-common——注入集必须覆盖这个有效导入面，否则本地
            // 模块 import 断裂，且 MNFE 不走 FN 补漏、会被 auto-install
            // 拿去 PyPI 装错包（静默错误行为）
            let scriptRel: String?
            if argv[0] == "-c" {
                // -c 形态：源码已内嵌引导码，脚本约定落 Documents/tmp
                // （TerminalCommandRewriter 语义）。sd=tmp；p1=Documents
                // 根（收根散 .py）；root=HOME 容器根——锚定 Documents
                // 后自然为空集，不是漏算（方案 §3.1 防困惑说明）
                scriptRel = "tmp/"
            } else {
                scriptRel = documentsRel(argv[0], docsPath: docsPath)
            }
            guard let scriptRel else { return nil } // 脚本不在 Documents：import 面无法保证 → 回退
            try collectImportSurface(scriptRel: scriptRel, docsPath: docsPath,
                                     fm: fm, into: &acc)

            // ── ② pathHints 收编（§3.3）：一律不当真，存在性探测后才收 ──
            // 误报代价收敛为几次 stat；不存在的输出文件名自动出局。
            // glob 模式串（"data/*.csv"）本体探测必然失败——截掉首个通配
            // 符起尾段，对目录前缀整树收编（2026-10-15 收口，宁多勿漏）
            for hint in pathHints ?? [] {
                guard let rel = documentsRel(hint, docsPath: docsPath) else { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: docsPath + "/" + rel, isDirectory: &isDir) {
                    if isDir.boolValue {
                        try collectDirectory(rel, docsPath: docsPath, fm: fm, into: &acc)
                    } else {
                        try collectFile(rel, docsPath: docsPath, fm: fm, into: &acc)
                    }
                } else if let dirRel = globDirectoryPrefix(rel) {
                    try collectDirectory(dirRel, docsPath: docsPath, fm: fm, into: &acc)
                }
            }

            // ── ③ argv 其余 token（§3.2）：dispatcher 已归一为绝对形态，
            // 与 pathHints 同一探测收编路径（argv 尾部 token 已被 dispatcher
            // 并入 path_hints，此处不再重复扫 argv——单一来源防双口径）──

            // ── ④ 根散常驻（§3.1）：根散 *.py/*.pyi + <256KB 配置类 ──
            try collectRootScatter(docsPath: docsPath, fm: fm, into: &acc)

            return acc.files
        } catch is OverLimitError {
            // 注入集自身超护栏 → 回退全量（方案 §3.4；全量仍超限走现行
            // SKIPPED 白纸降级，不引入新的失败模式）
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - 路径归一

    /// 绝对路径 → Documents 相对路径。支持 /var 与 /private/var 双形态
    /// （真机 enumerator/getcwd 两种都出过），前缀不匹配时按 dispatcher
    /// 同款「/Documents/ 锚点」兜底剥离；拒绝空尾与 ".."/"." 成分。
    nonisolated static func documentsRel(_ abs: String, docsPath: String) -> String? {
        var p = abs
        if p.hasPrefix("/private/") && docsPath.hasPrefix("/var/") {
            p = String(p.dropFirst("/private".count))
        }
        var tail: String?
        if p.hasPrefix(docsPath + "/") {
            tail = String(p.dropFirst(docsPath.count + 1))
        } else if let r = p.range(of: "/Documents/") {
            tail = String(p[r.upperBound...])
        }
        guard var t = tail, !t.isEmpty else { return nil }
        if t.hasSuffix("/") { t = String(t.dropLast()) }
        guard !t.isEmpty else { return nil }
        let comps = t.split(separator: "/").map(String.init)
        guard !comps.contains(".."), !comps.contains(".") else { return nil }
        return t
    }

    /// glob 模式串 → 目录前缀（首个 `*`/`?`/`[` 起的尾段截掉）。
    /// "data/*.csv" → "data"；"data/202[3-9]/*.csv" → "data"（宁多勿漏，
    /// 字符类前的层级整树收编）；无通配或通配前无目录（"*.csv"）→ nil，
    /// 交补漏兜底。模式串本体探测必然失败，此助手是它唯一的收编通道。
    nonisolated static func globDirectoryPrefix(_ rel: String) -> String? {
        guard let firstWild = rel.firstIndex(where: { "*?[".contains($0) }) else { return nil }
        let prefix = rel[rel.startIndex..<firstWild]
        guard let lastSlash = prefix.lastIndex(of: "/"), lastSlash > rel.startIndex else { return nil }
        let dir = String(prefix[rel.startIndex..<lastSlash])
        return dir.isEmpty ? nil : dir
    }

    // MARK: - 收集器

    /// 累计状态：体积/数量闸门共用一份（护栏判定对象 = 本次注入集，§3.4）
    private struct Accumulator {
        var files = Set<String>()
        var totalBytes = 0

        mutating func checkLimit() throws {
            if totalBytes > PyodideBridge.wsMaxTotalBytes
                || files.count > PyodideBridge.wsMaxFileCount {
                throw OverLimitError()
            }
        }
    }

    /// 本地 import 可见面（§3.1）：sd ∪ p1 ∪ root 三层 + office-common。
    /// 层目录 == Documents 根时只收根散 *.py/*.pyi（整树=全量注入，违背
    /// 按需本意）；层目录越出 Documents（-c 的 root=HOME 容器根）为空集。
    private static func collectImportSurface(scriptRel: String, docsPath: String,
                                             fm: FileManager, into acc: inout Accumulator) throws {
        // sd：脚本目录整树。-c 形态 scriptRel 以 "/" 结尾表示目录本身
        let sd = scriptRel.hasSuffix("/")
            ? String(scriptRel.dropLast())
            : (scriptRel as NSString).deletingLastPathComponent
        var layers = [sd]
        var cur = sd
        // 只走 sd/p1/root 三层（审查 P2 修复）：与 dispatcher sys.path 补插
        // （_mianshu_dispatcher boot：sd/p1/root 三层）严格对齐，也与本函数
        // docstring 一致。旧 while 会为深度 ≥4 的脚本多走上探一层——
        // skills/docx/scripts/sub/x.py 会把 skills/ 整树收进注入集（所有
        // skill 的语料），而 dispatcher 的 sys.path 根本不含该层，纯多搬
        for _ in 0..<2 {
            cur = (cur as NSString).deletingLastPathComponent
            if cur.isEmpty { break }
            layers.append(cur)
        }
        for layer in layers {
            if layer.isEmpty {
                // 层 == Documents 根：整树=全量注入，违背按需本意——只收
                // 根散（.py/.pyi + <256KB 配置类，collectRootScatter 统一口径）
                try collectRootScatter(docsPath: docsPath, fm: fm, into: &acc)
            } else {
                try collectDirectory(layer, docsPath: docsPath, fm: fm, into: &acc)
            }
        }
        // office-common：skill 脚本的兄弟目录依赖靠它解析（dispatcher
        // sys.path 第四层），存在即整树注入
        if fm.fileExists(atPath: docsPath + "/office-common") {
            try collectDirectory("office-common", docsPath: docsPath, fm: fm, into: &acc)
        }
    }

    /// 目录整树收编：逐 regular file 过 wsIncludedImpl 既有排除规则
    /// （排除目录/文件/后缀/临时脚本 + 8MB 单文件上限），不重入集合
    private static func collectDirectory(_ rel: String, docsPath: String,
                                         fm: FileManager, into acc: inout Accumulator) throws {
        let dirURL = URL(fileURLWithPath: docsPath, isDirectory: true)
            .appendingPathComponent(rel, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: dirURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
        let dirPrefix = dirURL.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(dirPrefix) else { continue }
            let fileRel = rel + "/" + String(path.dropFirst(dirPrefix.count))
            try collectFile(fileRel, docsPath: docsPath, fm: fm, into: &acc)
        }
    }

    /// 单文件收编：wsIncludedImpl 排除规则复用（与全量注入/写回校验
    /// 同一规则集——三处口径对称是 restore 不误删的前提）
    private static func collectFile(_ rel: String, docsPath: String,
                                    fm: FileManager, into acc: inout Accumulator) throws {
        guard !acc.files.contains(rel) else { return }
        let attrs = try? fm.attributesOfItem(atPath: docsPath + "/" + rel)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard PyodideBridge.wsIncludedImpl(rel, fileSize: size) else { return }
        acc.files.insert(rel)
        acc.totalBytes += size
        try acc.checkLimit()
    }

    /// 根散常驻（§3.1）：根散 *.py/*.pyi（p1/root 链可达的根级模块，
    /// 不限体积——wsIncludedImpl 的 8MB 单文件上限终审）+ 其余散文件中
    /// <256KB 的配置类（.env 等，成本低）。全过 wsIncludedImpl 排除规则。
    private static func collectRootScatter(docsPath: String,
                                           fm: FileManager, into acc: inout Accumulator) throws {
        guard let items = try? fm.contentsOfDirectory(atPath: docsPath) else { return }
        var isDir: ObjCBool = false
        for name in items.sorted() {
            guard fm.fileExists(atPath: docsPath + "/" + name, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            let isPython = name.hasSuffix(".py") || name.hasSuffix(".pyi")
            if !isPython {
                let attrs = try? fm.attributesOfItem(atPath: docsPath + "/" + name)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                guard size <= rootScatterConfigMaxBytes else { continue }
            }
            try collectFile(name, docsPath: docsPath, fm: fm, into: &acc)
        }
    }
}
