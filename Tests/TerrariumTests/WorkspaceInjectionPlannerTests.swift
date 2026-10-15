//
//  WorkspaceInjectionPlannerTests.swift
//  Terrarium（fork）
//
//  二期按需注入：注入集预测器单测（二期方案 §3.1-3.3）——纯文件系统 +
//  逻辑判定，Mac `swift test` 秒级完成，无 WebView 依赖。
//
//  覆盖：三形态路径归一 / 排除规则复用（与全量注入同一 wsIncludedImpl）/
//  空集回退 / 超限回退 / skill 目录树与本地 import 可见面（审查 P1-2）/
//  office-common / 根散 .py 与 <256KB 配置 / pathHints 存在性探测收编。
//
//  运行：swift test --filter WorkspaceInjectionPlannerTests
//

import XCTest
@testable import Terrarium

final class WorkspaceInjectionPlannerTests: XCTestCase {

    private var docs: URL!
    private var docsPath: String!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsplanner-\(UUID().uuidString)", isDirectory: true)
        docs = tmp.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        docsPath = docs.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: docs.deletingLastPathComponent())
    }

    private func write(_ rel: String, _ content: String = "x") throws {
        let url = docs.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func plan(argv: [String]?, pathHints: [String]? = nil) -> Set<String>? {
        WorkspaceInjectionPlanner.plan(argv: argv, pathHints: pathHints, docsPath: docsPath)
    }

    // MARK: - 回退语义（永不比现状差）

    func testNilArgv_fallsBackToFull() {
        XCTAssertNil(plan(argv: nil))
        XCTAssertNil(plan(argv: []))
    }

    func testScriptOutsideDocuments_fallsBack() {
        // 脚本不在 Documents：import 可见面无法保证 → 回退全量（保守）
        XCTAssertNil(plan(argv: ["/usr/bin/elsewhere.py"]))
        XCTAssertNil(plan(argv: ["/tmp/fake/script.py"]))
    }

    // MARK: - 路径归一 documentsRel

    func testDocumentsRel_forms() {
        XCTAssertEqual(
            WorkspaceInjectionPlanner.documentsRel("/var/a/b/Documents/data/x.csv", docsPath: "/var/a/b/Documents"),
            "data/x.csv")
        // /private 形态归一（真机 getcwd/enumerator 实测两种都出）
        XCTAssertEqual(
            WorkspaceInjectionPlanner.documentsRel("/private/var/a/b/Documents/data/x.csv", docsPath: "/var/a/b/Documents"),
            "data/x.csv")
        // /Documents/ 锚点兜底（docsPath 形态不匹配时）
        XCTAssertEqual(
            WorkspaceInjectionPlanner.documentsRel("/weird/root/Documents/x.csv", docsPath: "/elsewhere"),
            "x.csv")
        // 非法形态：空尾 / 穿越 / Documents 本身
        XCTAssertNil(WorkspaceInjectionPlanner.documentsRel("/var/a/b/Documents", docsPath: "/var/a/b/Documents"))
        XCTAssertNil(WorkspaceInjectionPlanner.documentsRel("/var/a/b/Documents/../evil", docsPath: "/var/a/b/Documents"))
        XCTAssertNil(WorkspaceInjectionPlanner.documentsRel("/var/other/file", docsPath: "/var/a/b/Documents"))
    }

    // MARK: - script 形态：目录树 + 根散

    func testScriptAtDocumentsRoot_rootScatterCollected() throws {
        try write("s.py")
        try write("helpers.py")
        try write("data.csv")
        try write(".env")
        // 根散 256KB 以上非 py 文件不收
        try write("big.bin", String(repeating: "x", count: 300 * 1024))
        let set = try XCTUnwrap(plan(argv: [docsPath + "/s.py"]))
        XCTAssertEqual(set, ["s.py", "helpers.py", "data.csv", ".env"])
    }

    func testSkillScript_importSurfaceThreeLayers() throws {
        // Documents/skills/a/b/skill.py：sd 整树 + p1(skills) 整树 + root 根散
        try write("skills/a/b/skill.py")
        try write("skills/a/b/util.py")
        try write("skills/c/other.py")
        try write("skills/c/helper.py")
        try write("root_mod.py")
        try write("data.csv") // 根散非 py 非 <256KB 配置类 → 收（<256KB）
        let set = try XCTUnwrap(plan(argv: [docsPath + "/skills/a/b/skill.py"]))
        XCTAssertEqual(set, [
            "skills/a/b/skill.py", "skills/a/b/util.py",   // sd 整树
            "skills/c/other.py", "skills/c/helper.py",     // p1 整树（兄弟 skill 互导）
            "root_mod.py",                                  // root 层根散 .py
            "data.csv",                                     // 根散配置类（<256KB）
        ])
    }

    func testOfficeCommon_includedWhenExists() throws {
        try write("skills/a/skill.py")
        try write("office-common/entry_utils.py")
        try write("office-common/deep/lib.py")
        let set = try XCTUnwrap(plan(argv: [docsPath + "/skills/a/skill.py"]))
        XCTAssertTrue(set.contains("office-common/entry_utils.py"))
        XCTAssertTrue(set.contains("office-common/deep/lib.py"))
    }

    // MARK: - -c 形态

    func testCForm_tmpTreeAndRootScatter() throws {
        try write("tmp/scratch.py")
        try write("tmp/sub/deep.py")
        try write("root_mod.py")
        let set = try XCTUnwrap(plan(argv: ["-c"]))
        XCTAssertEqual(set, ["tmp/scratch.py", "tmp/sub/deep.py", "root_mod.py"])
    }

    // MARK: - pathHints 探测收编（§3.3：扫出的 token 一律不当真）

    func testPathHints_existingFileCollected_missingDropped() throws {
        try write("s.py")
        try write("data/绝味.csv")
        let set = try XCTUnwrap(plan(
            argv: [docsPath + "/s.py"],
            pathHints: [docsPath + "/data/绝味.csv",
                        docsPath + "/report_2026.csv"])) // 不存在的输出名 → 出局
        XCTAssertEqual(set, ["s.py", "data/绝味.csv"])
    }

    func testPathHints_directoryExpandsToTree() throws {
        try write("s.py")
        try write("data/a.csv")
        try write("data/sub/b.json")
        let set = try XCTUnwrap(plan(
            argv: [docsPath + "/s.py"],
            pathHints: [docsPath + "/data"]))
        XCTAssertEqual(set, ["s.py", "data/a.csv", "data/sub/b.json"])
    }

    func testPathHints_excludedRulesApply() throws {
        try write("s.py")
        try write("node_modules/pkg/index.js")
        try write("diag.log")
        try write("sessions.db")
        let set = try XCTUnwrap(plan(
            argv: [docsPath + "/s.py"],
            pathHints: [docsPath + "/node_modules", docsPath + "/diag.log",
                        docsPath + "/sessions.db", docsPath + "/../evil"]))
        // 排除集文件一律不进注入集（与全量注入/写回校验三处口径对称）
        XCTAssertEqual(set, ["s.py"])
    }

    func testPathHints_privateVarFormAnchored() throws {
        try write("s.py")
        try write("data/x.csv")
        let set = try XCTUnwrap(plan(
            argv: [docsPath + "/s.py"],
            pathHints: ["/private" + docsPath + "/data/x.csv"]))
        XCTAssertEqual(set, ["s.py", "data/x.csv"])
    }

    // MARK: - 临时脚本与排除目录

    func testTempScriptExcluded_butTmpTreeCollected() throws {
        // run_script_<uuid>.py（36 位 UUID 尾）被排除规则滤掉——无影响：
        // 源码已内嵌引导码，脚本文件本身不需进 MEMFS（方案 §3.1 防困惑）
        let uuid = "0123456789ABCDEF0123456789ABCDEF0123"
        XCTAssertEqual(uuid.count, 36)
        try write("tmp/run_script_\(uuid).py")
        try write("tmp/keep.csv")
        let set = try XCTUnwrap(plan(argv: [docsPath + "/tmp/run_script_\(uuid).py"]))
        XCTAssertEqual(set, ["tmp/keep.csv"])
    }

    // MARK: - 超限回退（注入集体积闸门，方案 §3.4）

    func testOverLimitInjectionSet_fallsBackToFull() throws {
        try write("s.py")
        // 5 × 7MB = 35MB > 32MB 护栏（单文件均在 8MB 上限内）
        let chunk = String(repeating: "x", count: 7 * 1024 * 1024)
        for i in 0..<5 {
            try write("big/\(i).bin", chunk)
        }
        let set = plan(argv: [docsPath + "/s.py"],
                       pathHints: (0..<5).map { docsPath + "/big/\($0).bin" })
        XCTAssertNil(set, "注入集超护栏应回退全量（nil）")
    }

    // MARK: - 指纹/打包集合口径（B-3，与全量口径同构）

    func testFingerprintWithSet_matchesFullForSameContent() throws {
        // 集合口径与全量口径对同一 included 内容产出同构指纹
        // （rel|size|mtime 排序拼接）——口径切换后 skip 不得误命中
        try write("a.csv", "aaa")
        try write("b.csv", "bb")
        try write(".log", "junk")          // 排除后缀：两口径都不该看见
        try write("node_modules/x.js", "j")
        let full = PyodideBridge.documentsFingerprintImpl(docs: docs, set: nil)
        let scoped = PyodideBridge.documentsFingerprintImpl(docs: docs, set: ["a.csv", "b.csv"])
        XCTAssertEqual(full, scoped, "集合恰为全量 included 时两口径指纹应一致")
        // 集合缩小 → 指纹不同（按需切换后同命令重跑会正确重注入）
        let subset = PyodideBridge.documentsFingerprintImpl(docs: docs, set: ["a.csv"])
        XCTAssertNotEqual(full, subset)
    }

    func testFingerprintWithSet_missingFileReturnsNil() throws {
        // 集合内文件被删（预测与实况竞态）→ 指纹 nil → 调用方回退全量
        try write("a.csv", "aaa")
        XCTAssertNil(PyodideBridge.documentsFingerprintImpl(docs: docs, set: ["a.csv", "ghost.csv"]))
        // 集合内文件落入排除集（如被用户换成超大文件）同样 nil
        try write("big.bin", String(repeating: "x", count: PyodideBridge.wsMaxFileBytes + 1))
        XCTAssertNil(PyodideBridge.documentsFingerprintImpl(docs: docs, set: ["big.bin"]))
    }
}
