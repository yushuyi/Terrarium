//
//  PyodideBridgeLeakFillTests.swift
//  Terrarium（fork）
//
//  二期步骤 C：补漏判定链 + 学习缓存单测（二期方案 §4.1-4.5）——纯文件
//  系统 + 逻辑判定，Mac `swift test` 秒级完成，无 WebView 依赖。
//
//  覆盖：FN 双源提取正则（exception/stderr/双引号）/ 路径归一三形态 /
//  补漏校验链（宿主存在性前置是审查 P1-1 回归锚点：探测性读不存在的
//  可选文件必须一次报错不重跑）/ 目录补齐阈值（§4.3）/ 学习缓存
//  LRU 与剪除（§4.5）。
//
//  运行：swift test --filter PyodideBridgeLeakFillTests
//

import XCTest
@testable import Terrarium

final class PyodideBridgeLeakFillTests: XCTestCase {

    private var docs: URL!
    private var docsPath: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsleakfill-\(UUID().uuidString)", isDirectory: true)
        docs = tmp.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        docsPath = docs.path
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wslearn-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: docs.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func write(_ rel: String, _ content: String = "x") throws {
        let url = docs.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - FN 提取（§4.2 双源 + 双引号形态）

    func testExtract_directRaise_exceptionSource() {
        let exc = """
        Traceback (most recent call last):
          File "s.py", line 3, in <module>
            open('data/x.csv')
        FileNotFoundError: [Errno 2] No such file or directory: 'data/x.csv'
        """
        XCTAssertEqual(PyodideBridge.extractMissingFilePath(exception: exc, stderr: ""),
                       "data/x.csv")
    }

    func testExtract_asyncioTask_stderrSource() {
        // asyncio 任务内异常只落 stderr（host.js:677 自证）——双源存在的理由
        let stderr = "ERROR:asyncio:Unhandled exception in event loop\n" +
            "FileNotFoundError: [Errno 2] No such file or directory: 'data/y.csv'\n"
        XCTAssertEqual(PyodideBridge.extractMissingFilePath(exception: nil, stderr: stderr),
                       "data/y.csv")
    }

    func testExtract_doubleQuoteForm() {
        let exc = "FileNotFoundError: [Errno 2] No such file or directory: \"/var/mobile/Containers/Data/Application/ABC/Documents/data/z.csv\""
        XCTAssertEqual(PyodideBridge.extractMissingFilePath(exception: exc, stderr: ""),
                       "/var/mobile/Containers/Data/Application/ABC/Documents/data/z.csv")
    }

    func testExtract_noFNText_returnsNil() {
        XCTAssertNil(PyodideBridge.extractMissingFilePath(
            exception: "ModuleNotFoundError: No module named 'pandas'", stderr: ""))
        XCTAssertNil(PyodideBridge.extractMissingFilePath(
            exception: "raise SystemExit(2)", stderr: "some noise"))
        XCTAssertNil(PyodideBridge.extractMissingFilePath(exception: nil, stderr: ""))
    }

    // MARK: - FN 路径归一（§4.2 三形态）

    func testNormalize_memfsAbsoluteForms() {
        XCTAssertEqual(
            PyodideBridge.normalizeMissingRel("/home/pyodide/Documents/data/x.csv",
                                              docsPath: docsPath),
            "data/x.csv")
        XCTAssertEqual(
            PyodideBridge.normalizeMissingRel(docsPath + "/data/x.csv", docsPath: docsPath),
            "data/x.csv")
    }

    func testNormalize_bareRelative() {
        // Pyodide cwd = Documents（host.js:255 已实证）——相对读取的 FN
        // 是裸相对形态入 traceback
        XCTAssertEqual(PyodideBridge.normalizeMissingRel("data/x.csv", docsPath: docsPath),
                       "data/x.csv")
        XCTAssertEqual(PyodideBridge.normalizeMissingRel("./data/x.csv", docsPath: docsPath),
                       "data/x.csv")
    }

    func testNormalize_rejectsTraversalAndForeign() {
        XCTAssertNil(PyodideBridge.normalizeMissingRel("../evil.csv", docsPath: docsPath))
        XCTAssertNil(PyodideBridge.normalizeMissingRel("/etc/passwd", docsPath: docsPath))
        XCTAssertNil(PyodideBridge.normalizeMissingRel("/var/other/file.csv", docsPath: docsPath))
    }

    // MARK: - 补漏校验链（§4.1，P1-1 回归锚点）

    func testExpand_hostMissing_returnsNil() throws {
        // P1-1：探测性读「宿主也没有」的文件 → 校验①不过 → 一次报错
        // 不重跑（副作用 1 遍，与现状一致）
        try write("s.py")
        XCTAssertNil(PyodideBridge.expandInjectionSet(
            base: ["s.py"], missingRel: "config.yaml", docsPath: docsPath))
    }

    func testExpand_existingFile_added() throws {
        try write("s.py")
        try write("data/config.yaml", "k: v")
        let expanded = try XCTUnwrap(PyodideBridge.expandInjectionSet(
            base: ["s.py"], missingRel: "data/config.yaml", docsPath: docsPath))
        XCTAssertEqual(expanded.added, ["data/config.yaml"])
        XCTAssertEqual(expanded.set, ["s.py", "data/config.yaml"])
    }

    func testExpand_excludedFile_returnsNil() throws {
        // 校验②：排除集文件（.log / 排除目录）无法注入 → 原样报错
        try write("s.py")
        try write("diag.log")
        try write("node_modules/pkg/index.js")
        XCTAssertNil(PyodideBridge.expandInjectionSet(
            base: ["s.py"], missingRel: "diag.log", docsPath: docsPath))
        XCTAssertNil(PyodideBridge.expandInjectionSet(
            base: ["s.py"], missingRel: "node_modules/pkg/index.js", docsPath: docsPath))
    }

    func testExpand_alreadyInBase_returnsNil() throws {
        try write("s.py")
        try write("data/x.csv")
        XCTAssertNil(PyodideBridge.expandInjectionSet(
            base: ["s.py", "data/x.csv"], missingRel: "data/x.csv", docsPath: docsPath),
            "已在注入集内的文件不再扩充（理论上不应发生的防御）")
    }

    // MARK: - 目录补齐（§4.3 阈值）

    func testExpand_smallDirectory_fillsWholeTree() throws {
        try write("s.py")
        for i in 0..<10 { try write("data/part\(i).csv") }
        try write("data/sub/nested.json")
        let expanded = try XCTUnwrap(PyodideBridge.expandInjectionSet(
            base: ["s.py"], missingRel: "data/part3.csv", docsPath: docsPath))
        // 整目录补齐：glob 遍历一轮收敛（含子树）——10 个 part + 1 个 nested
        XCTAssertEqual(expanded.added.count, 11)
        XCTAssertTrue(expanded.added.contains("data/sub/nested.json"))
    }

    func testExpand_oversizeDirectory_fillsSingleFileOnly() throws {
        try write("s.py")
        // 8MB+ 目录 → 超出补齐阈值，只补单文件（201 文件形态同判定）
        let chunk = String(repeating: "x", count: 3 * 1024 * 1024)
        for i in 0..<3 { try write("huge/\(i).bin", chunk) }
        try write("huge/target.csv", "small")
        let expanded = try XCTUnwrap(PyodideBridge.expandInjectionSet(
            base: ["s.py"], missingRel: "huge/target.csv", docsPath: docsPath))
        XCTAssertEqual(expanded.added, ["huge/target.csv"])
        XCTAssertFalse(expanded.set.contains("huge/0.bin"))
    }

    func testDirectoryFillEligible_bounds() throws {
        for i in 0..<PyodideBridge.wsDirFillMaxFiles {
            try write("many/f\(i).csv")
        }
        XCTAssertTrue(PyodideBridge.directoryFillEligible("many", docsPath: docsPath),
                      "恰好 200 文件 → 达标")
        try write("many/over.csv")
        XCTAssertFalse(PyodideBridge.directoryFillEligible("many", docsPath: docsPath),
                       "201 文件 → 超阈值（有意降级）")
    }

    func testDirectoryFillEligible_emptyDir_false() throws {
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("empty"),
                                                withIntermediateDirectories: true)
        XCTAssertFalse(PyodideBridge.directoryFillEligible("empty", docsPath: docsPath))
    }

    // MARK: - 学习缓存（§4.5）

    private var cacheURL: URL!

    func testLearnCache_roundTrip() {
        let url: URL = cacheURL
        let code = "print('hello')"
        WorkspaceLearnCache.record(code: code, rels: ["data/config.yaml"], cacheURL: url)
        XCTAssertEqual(WorkspaceLearnCache.learnedRels(
            forKey: WorkspaceLearnCache.key(forCode: code), cacheURL: url),
            ["data/config.yaml"])
        // 同键追加合并去重
        WorkspaceLearnCache.record(code: code, rels: ["data/config.yaml", "data/b.csv"], cacheURL: url)
        XCTAssertEqual(WorkspaceLearnCache.learnedRels(
            forKey: WorkspaceLearnCache.key(forCode: code), cacheURL: url),
            ["data/config.yaml", "data/b.csv"])
        try? FileManager.default.removeItem(at: url)
    }

    func testLearnCache_lruEviction() {
        let url: URL = cacheURL
        for i in 0..<WorkspaceLearnCache.maxEntries {
            WorkspaceLearnCache.record(code: "code-\(i)", rels: ["f\(i).csv"], cacheURL: url)
        }
        XCTAssertEqual(WorkspaceLearnCache.learnedRels(
            forKey: WorkspaceLearnCache.key(forCode: "code-0"), cacheURL: url),
            ["f0.csv"])
        // 第 65 条进入 → 最旧的 code-0 被逐出
        WorkspaceLearnCache.record(code: "code-64", rels: ["f64.csv"], cacheURL: url)
        XCTAssertNil(WorkspaceLearnCache.learnedRels(
            forKey: WorkspaceLearnCache.key(forCode: "code-0"), cacheURL: url))
        XCTAssertNotNil(WorkspaceLearnCache.learnedRels(
            forKey: WorkspaceLearnCache.key(forCode: "code-64"), cacheURL: url))
        try? FileManager.default.removeItem(at: url)
    }

    func testLearnCache_pruneRemovesInvalidRels() {
        let url: URL = cacheURL
        let code = "script"
        WorkspaceLearnCache.record(code: code, rels: ["keep.csv", "ghost.csv"], cacheURL: url)
        WorkspaceLearnCache.prune(key: WorkspaceLearnCache.key(forCode: code),
                                  rels: ["ghost.csv"], cacheURL: url)
        XCTAssertEqual(WorkspaceLearnCache.learnedRels(
            forKey: WorkspaceLearnCache.key(forCode: code), cacheURL: url),
            ["keep.csv"])
        // 剪空 → 整键删除
        WorkspaceLearnCache.prune(key: WorkspaceLearnCache.key(forCode: code),
                                  rels: ["keep.csv"], cacheURL: url)
        XCTAssertNil(WorkspaceLearnCache.learnedRels(
            forKey: WorkspaceLearnCache.key(forCode: code), cacheURL: url))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 学习缓存收编（mergedWithLearned 双闸）

    func testMergedWithLearned_dualGate() throws {
        try write("s.py")
        try write("data/valid.csv")
        try write("diag.log")
        // 缓存里三个 rel：有效 / 已在 base / 失效（不存在）/ 排除集
        let code = "dual-gate"
        WorkspaceLearnCache.record(code: code,
                                   rels: ["data/valid.csv", "s.py", "ghost.csv", "diag.log"],
                                   cacheURL: cacheURL)
        let merged = PyodideBridge.mergedWithLearned(
            code: code, base: ["s.py"], docsPath: docsPath, cacheURL: cacheURL)
        XCTAssertEqual(merged, ["s.py", "data/valid.csv"])
        // 任一闸不过 → 剪除缓存（不存在与排除集文件都永不可注入）
        let after = try XCTUnwrap(WorkspaceLearnCache.learnedRels(
            forKey: WorkspaceLearnCache.key(forCode: code), cacheURL: cacheURL))
        XCTAssertFalse(after.contains("ghost.csv"))
        XCTAssertFalse(after.contains("diag.log"))
    }

    func testMergedWithLearned_noCache_returnsBase() {
        XCTAssertEqual(PyodideBridge.mergedWithLearned(
            code: "never-recorded", base: ["a.csv"], docsPath: docsPath, cacheURL: cacheURL),
            ["a.csv"])
    }
}
