//
//  PyodideBridgeSnapshotFilterTests.swift
//  Terrarium（fork）
//
//  工作区快照过滤器（wsIncludedImpl）单元测试——纯逻辑、无 WebView，
//  Mac `swift test` 秒级完成。覆盖 259b4ca（node_modules/SessionSearch
//  排除 + I-4 .python 排除）与 7ad25a7（App 自有数据排除）引入的规则，
//  以及大小护栏与边界形态（相对路径/嵌套/空串/恰好上限）。
//
//  运行：swift test --filter PyodideBridgeSnapshotFilterTests
//

import XCTest
@testable import Terrarium

final class PyodideBridgeSnapshotFilterTests: XCTestCase {

    // MARK: - 排除目录（前缀规则）

    /// node_modules 必须整树排除（259b4ca 主目标，jetsam 载荷主力）
    func testExcluded_nodeModules_atRootAndNested() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("node_modules/docx/package.json", fileSize: 10))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/node_modules/jszip/lib/index.js", fileSize: 10))
    }

    /// SessionSearch 必须整树排除（259b4ca：子目录漏网修复）
    func testExcluded_sessionSearch_tree() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("SessionSearch/session.db", fileSize: 10))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("SessionSearch/session.db-wal", fileSize: 10))
    }

    /// .python 是 3.14 端供应商目录：排除是 I-4（Errno 44）根因修复，
    /// 同时避免非 pyodide 包源码进 3.13 视图
    func testExcluded_dotPython() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl(".python/lib/python3.14/os.py", fileSize: 10))
    }

    /// App 自有数据（7ad25a7）：根文件与 WAL/SHM 全排除
    func testExcluded_appOwnedRootFiles() {
        for name in ["pyodide_persist.zip", "MCPServers.json", "sessions.db",
                     "sessions.db-wal", "sessions.db-shm", "prio.log"] {
            XCTAssertFalse(PyodideBridge.wsIncludedImpl(name, fileSize: 10), "应排除: \(name)")
        }
    }

    /// 聊天/记忆/收件箱等 App 自管数据不进 pyodide 工作区
    func testExcluded_appPrivateDirs() {
        for dir in ["Conversations/", "Memory/", "Inbox/", "CLIShims/", "backups/"] {
            XCTAssertFalse(PyodideBridge.wsIncludedImpl(dir + "whatever", fileSize: 10), "应排除: \(dir)")
        }
    }

    // MARK: - 大小护栏

    func testMaxFileBytes_exactLimitBoundary() {
        let max = PyodideBridge.wsMaxFileBytes
        // 恰好等于上限：放行（<= 语义）；超限一个字节：排除
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tests/edge_exact.bin", fileSize: max), "恰好上限应放行")
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tests/edge_over.bin", fileSize: max + 1), "超限应排除")
    }

    func testMaxFileBytes_oversizedEvenInAllowedDir() {
        // 大文件即使在用户工作目录也排除
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tests/huge.bin", fileSize: PyodideBridge.wsMaxFileBytes + 1024))
    }

    // MARK: - 放行侧（用户工作产物）

    func testIncluded_userWorkingFiles() {
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tests/hello.py", fileSize: 100))
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("pyodide_figures/fig.png", fileSize: 2048))
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tmp/scratch.txt", fileSize: 1))
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("data.csv", fileSize: 500))
    }

    // MARK: - 边界形态（前缀规则的经典陷阱）

    /// 前缀必须按目录段匹配：**不能**把 "BackupX/" 或 "MemoryVault/a" 之类
    /// 共享前缀的非同目录文件误杀（hasPrefix 裸匹配会 false-positive）
    func testPrefix_noFalsePositiveOnSimilarNames() {
        // "Memory/" 排除不应波及 "MemoryVault/"
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("MemoryVault/notes.txt", fileSize: 10),
                      "MemoryVault 不得被 Memory/ 前缀误杀")
        // "Inbox/" 排除不应波及 "InboxArchive/"
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("InboxArchive/a.txt", fileSize: 10),
                      "InboxArchive 不得被 Inbox/ 前缀误杀")
        // ".python/" 排除不应波及 ".pythonrc"
        XCTAssertTrue(PyodideBridge.wsIncludedImpl(".pythonrc", fileSize: 10))
    }

    /// 排除文件清单是精确名匹配：同名不同目录不受牵连
    func testExcludedFiles_exactNameOnly() {
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tmp/sessions.db", fileSize: 10),
                      "tmp/ 下同名 sessions.db 不在排除清单（根文件名才排除）——若这是意外放行请修注释而非测试")
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("sessions.db", fileSize: 10))
    }

    /// 空串/奇怪输入不崩、语义明确
    func testEdgeCases_dontCrash() {
        // 空路径无前缀命中，按大小放行
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("", fileSize: 10))
        // 0 字节放行
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tmp/empty", fileSize: 0))
    }
}
