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

    // MARK: - 2026-10-11 超护栏现场排查新增规则

    /// .git 目录整树排除：Documents/.git 是 App 自动提交仓库（881 松散对象
    /// 只增不减），included 集字节破 32MB 护栏推手之一
    func testExcluded_gitDir_atRootAndNested() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl(".git/objects/00/1f29bdcfe5", fileSize: 10))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl(".git/index", fileSize: 10))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("myproj/.git/HEAD", fileSize: 10),
                       "用户项目内嵌套 .git 同样按目录段排除")
    }

    /// .git 排除不得误杀同名前缀文件
    func testExcluded_gitDir_noFalsePositive() {
        XCTAssertTrue(PyodideBridge.wsIncludedImpl(".gitignore", fileSize: 10),
                      ".gitignore 是普通文件，不得被 .git/ 目录排除牵连")
        XCTAssertTrue(PyodideBridge.wsIncludedImpl(".gitattributes", fileSize: 10))
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("myproj/.github/workflows/ci.yml", fileSize: 10),
                      ".github/ 目录不受 .git/ 排除影响")
    }

    /// .log 后缀全深度排除：diag-*.log（13.4MB）/applog-*.log 是 included 集
    /// 字节破 32MB 护栏的主力；此前精确名单追着文件名跑，改为规则
    func testExcluded_logSuffix_anyDepth() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("diag-base-fix.log", fileSize: 4_905_818))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("applog-20261001.log", fileSize: 943_734))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/run.log", fileSize: 10),
                       ".log 后缀在子目录同样生效")
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("TRACE.LOG", fileSize: 10),
                       "后缀匹配大小写不敏感")
    }

    /// .log 后缀规则的边界：非 .log 后缀、用户数据不受牵连
    func testExcluded_logSuffix_noFalsePositive() {
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("rec_20261010-203115-1yav.zip", fileSize: 416_608),
                      "会话录制 zip 是用户数据，保持注入（超护栏排查结论：不随日志一并排除）")
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("catalog.logx", fileSize: 10),
                      "仅 .log 结尾才排除，.logx 是普通文件")
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("logs/notes.txt", fileSize: 10),
                      "logs/ 目录本身不在排除规则（规则按文件后缀，不按目录名）")
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("高性价比人生指南.epub", fileSize: 1_001_049),
                      "用户内容保持注入")
    }

    /// 空串/奇怪输入不崩、语义明确
    func testEdgeCases_dontCrash() {
        // 空路径无前缀命中，按大小放行
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("", fileSize: 10))
        // 0 字节放行
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tmp/empty", fileSize: 0))
    }

    // MARK: - 临时脚本（UUID 尾）指纹排除

    /// 真机实证形态：36 字符 UUID（8-4-4-4-12）
    private let uuid = "2D61D33E-1A2B-4C3D-9E8F-0A1B2C3D4E5F"

    /// 三类临时脚本 → 排除。真机实证形态 `tmp/run_script_<UUID>.py`
    /// （无 Documents/ 前缀），故规则统一作用于**末段**
    func testExcluded_tempScripts_threeRealShapes() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/run_script_\(uuid).py", fileSize: 512))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/.inline_py_\(uuid).py", fileSize: 512))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/.grep_o_\(uuid).py", fileSize: 512))
    }

    /// .sh 变体一并覆盖（TerminalCommandRewriter 亦产 .sh）
    func testExcluded_tempScripts_shVariant() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/run_script_\(uuid).sh", fileSize: 512))
    }

    /// 任意深度生效：命中判定只看末段，与所在目录无关
    func testExcluded_tempScripts_anyDepthAndRoot() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("run_script_\(uuid).py", fileSize: 512),
                       "Documents 根层的临时脚本同样排除")
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/a/b/.inline_py_\(uuid).py", fileSize: 512),
                       "嵌套子目录同样排除")
    }

    /// 大小写不敏感：UUID 十六进制可能全大写或全小写
    func testExcluded_tempScripts_caseInsensitive() {
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/run_script_\(uuid.lowercased()).py", fileSize: 512))
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/RUN_SCRIPT_\(uuid.uppercased()).PY", fileSize: 512))
    }

    /// **误杀防护（本规则的核心价值）**：v1 的 `run_script_*.py` 裸前缀匹配
    /// 会命中用户自建文档 `run_script_notes.py`——pyodide 改写它后 collect
    /// 上报写回、validatedRel 拒绝 → 用户修改静默丢失，且读它直接
    /// FileNotFoundError。UUID 长度锚定后这类文件必须放行
    func testIncluded_tempScriptLookalikes_mustNotBeExcluded() {
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("run_script_notes.py", fileSize: 512),
                      "用户自建的 run_script_notes.py 必须放行")
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("docs/run_script_tutorial.py", fileSize: 512))
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("my.inline_py_abc.py", fileSize: 512),
                      "非 UUID 尾的同形态文件必须放行")
        XCTAssertTrue(PyodideBridge.wsIncludedImpl(".inline_py_notes.py", fileSize: 512))
    }

    /// 长度边界：UUID 恰好 36 位才命中，35 / 37 位都不是临时脚本
    func testTempScript_uuidLengthBoundary() {
        let uuid35 = String(uuid.dropLast())
        let uuid37 = uuid + "A"
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tmp/run_script_\(uuid35).py", fileSize: 512),
                      "35 位不命中（长度锚定生效）")
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tmp/run_script_\(uuid37).py", fileSize: 512),
                      "37 位不命中")
        XCTAssertFalse(PyodideBridge.wsIncludedImpl("tmp/run_script_\(uuid).py", fileSize: 512),
                       "36 位命中")
    }

    /// 非 UUID 字符集不命中（含下划线等非法字符）
    func testTempScript_uuidCharSet() {
        let bad = "ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ"      // 长度对但含非十六进制字母
        XCTAssertTrue(PyodideBridge.wsIncludedImpl("tmp/run_script_\(bad).py", fileSize: 512))
        XCTAssertFalse(PyodideBridge.isUUIDTail("not-a-uuid"))
        XCTAssertFalse(PyodideBridge.isUUIDTail(""))
    }

    /// 直接断言判定函数（含空串/无后缀/纯文件名等边界）
    func testIsTempScriptPath_directCases() {
        XCTAssertTrue(PyodideBridge.isTempScriptPath("tmp/run_script_\(uuid).py"))
        XCTAssertTrue(PyodideBridge.isTempScriptPath("run_script_\(uuid).sh"))
        XCTAssertFalse(PyodideBridge.isTempScriptPath(""))
        XCTAssertFalse(PyodideBridge.isTempScriptPath("tmp/notes.txt"))
        XCTAssertFalse(PyodideBridge.isTempScriptPath("run_script_\(uuid).txt"),
                       "只认 .py/.sh 两种后缀")
    }

    // MARK: - 体检页状态分级（WorkspaceSnapshotHealth.Level）

    private func makeHealth(
        includedBytes: Int64,
        includedFileCount: Int,
        overGuard: Bool = false,
        overGuardReason: WorkspaceSeedOverGuardReason = .overLimit,
        mode: WorkspaceInjectionMode = .full,
        lastPayloadBytes: Int = 0,
        lastUncompressedBytes: Int = 0,
        skipped: Bool = false
    ) -> WorkspaceSnapshotHealth {
        WorkspaceSnapshotHealth(
            includedFileCount: includedFileCount,
            includedBytes: includedBytes,
            maxBytes: 32 * 1024 * 1024,
            maxFileCount: 2000,
            folders: [],
            lastInjectionAt: nil,
            lastInjectionFileCount: includedFileCount,
            lastInjectionPayloadBytes: lastPayloadBytes,
            lastInjectionUncompressedBytes: lastUncompressedBytes,
            lastSeedSkipped: skipped,
            lastSeedOverGuard: overGuard,
            lastInjectionMode: mode,
            lastSeedOverGuardReason: overGuardReason,
            fingerprintStable: false
        )
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    /// 余量充足 → 健康
    func testLevel_healthy_belowThreshold() {
        let h = makeHealth(includedBytes: 20 * 1024 * 1024, includedFileCount: 599)
        XCTAssertEqual(h.level, .healthy)
        XCTAssertLessThan(h.byteRatio, 0.7)
    }

    /// 体积或文件数任一 ≥80% 即预警（取先到的那条腿）。
    /// 真机 2026-10-12 实测 26.8MB / 599 文件 → 84%，落在这一档，
    /// 说明预警阈值定得有意义：当前设备确实已经贴脸。
    func testLevel_warning_onEitherDimension() {
        XCTAssertEqual(makeHealth(includedBytes: 27 * 1024 * 1024, includedFileCount: 599).level, .warning,
                       "体积 84% 触警（真机当前就处在这一档）")
        XCTAssertEqual(makeHealth(includedBytes: 20 * 1024 * 1024, includedFileCount: 1700).level, .warning,
                       "文件数 85% 触警")
        XCTAssertEqual(makeHealth(includedBytes: 20 * 1024 * 1024, includedFileCount: 599).level, .healthy,
                       "两个维度都安全时不误报")
    }

    /// 触顶或超护栏 → 退化态
    func testLevel_overGuard_onOverflowOrGuard() {
        XCTAssertEqual(makeHealth(includedBytes: 33 * 1024 * 1024, includedFileCount: 599).level, .overGuard)
        XCTAssertEqual(makeHealth(includedBytes: 32 * 1024 * 1024, includedFileCount: 599).level, .overGuard,
                       "恰好等于上限也算触顶（guard 是 > 比较，体检从严）")
        XCTAssertEqual(makeHealth(includedBytes: 20 * 1024 * 1024, includedFileCount: 2100).level, .overGuard,
                       "文件数破 2000 同样退化")
        XCTAssertEqual(makeHealth(includedBytes: 1, includedFileCount: 1, overGuard: true).level, .overGuard,
                       "上次 seed 已超护栏时，即使当前体积回落也维持退化态提示")
    }

    // MARK: - 上次注入文案（两段式：原始 → 压缩）

    /// 正常注入：必须同时给出压缩前与压缩后两个数。只给一个是没意义的——
    /// 压缩比完全取决于 included 集的内容构成，两个数字摆在一起才能看出
    /// 当前落在「文本为主（压得动）」还是「二进制为主（压不动）」
    func testLastInjectionVolumeText_normal_isTwoLegged() {
        let h = makeHealth(
            includedBytes: 20 * 1024 * 1024,
            includedFileCount: 599,
            lastPayloadBytes: 5_500_000,
            lastUncompressedBytes: 37_000_000
        )
        XCTAssertEqual(
            h.lastInjectionVolumeText,
            "599 个文件 · 原始 \(byteText(37_000_000)) → 压缩 \(byteText(5_500_000))"
        )
    }

    /// skip 分支必须带体积（v4 验收项）。指纹一致是稳态、这一行被看得最多，
    /// 不带体积等于把最该被观察的状态藏起来——历史上正是这里最先被省掉
    func testLastInjectionVolumeText_skippedStillCarriesVolume() {
        let h = makeHealth(
            includedBytes: 20 * 1024 * 1024,
            includedFileCount: 599,
            lastPayloadBytes: 5_500_000,
            lastUncompressedBytes: 37_000_000,
            skipped: true
        )
        let text = h.lastInjectionVolumeText
        XCTAssertTrue(text.hasPrefix("指纹一致，零开销跳过"), text)
        XCTAssertTrue(text.contains(byteText(37_000_000)), "skip 行必须带体积：\(text)")
        XCTAssertFalse(text.contains("个文件"), "skip 本轮没搬文件，不该报文件数：\(text)")
    }

    /// 超护栏分支维持原口径（此时没有体积可展示，讲的是降级通道）
    func testLastInjectionVolumeText_overGuard() {
        let h = makeHealth(includedBytes: 33 * 1024 * 1024, includedFileCount: 599, overGuard: true)
        XCTAssertEqual(h.lastInjectionVolumeText, "超护栏放弃注入，MEMFS 退化为隔离态")
    }

    /// overGuard 细分（二期步骤 E，一期遗留顺路项）：压缩失败≠超护栏——
    /// 前者是瞬时故障（重试即可），后者是持久性问题（要清理）。口径混在
    /// 一起会把「重试就行」误报成「快去清理」
    func testLastInjectionVolumeText_overGuard_compressFailed() {
        let h = makeHealth(
            includedBytes: 33 * 1024 * 1024, includedFileCount: 599,
            overGuard: true, overGuardReason: .compressFailed
        )
        XCTAssertEqual(h.lastInjectionVolumeText, "压缩失败，本轮未注入（下次 run 自动重试）")
        XCTAssertEqual(h.level, .overGuard, "细分只改文案，状态机不变")
    }

    // MARK: - 注入模式行（二期步骤 E，§六 #1）

    /// 模式文案三态：按需 / 全量 / 按需回退。回退态必须显式暴露——
    /// 「预测失效」只有在这里可见，混进全量口径里灰度期就没人看得到了
    func testInjectionModeDisplayText() {
        XCTAssertEqual(WorkspaceInjectionMode.onDemand.displayText, "按需注入")
        XCTAssertEqual(WorkspaceInjectionMode.full.displayText, "全量注入")
        XCTAssertEqual(WorkspaceInjectionMode.fullFallback.displayText, "全量注入（按需回退）")
    }

    /// 模式行详情文案：按需态必须把「体积小是特性」写在明面上——
    /// 防止 22.9MB → KB 量级的骤降被当 bug 报（§六 #1 的核心诉求）
    func testInjectionModeDetailText_onDemandExplainsShrinkage() {
        let onDemand = makeHealth(includedBytes: 331_000, includedFileCount: 12, mode: .onDemand)
        XCTAssertTrue(onDemand.lastInjectionModeDetailText.contains("按需注入"), onDemand.lastInjectionModeDetailText)
        XCTAssertTrue(onDemand.lastInjectionModeDetailText.contains("特性"), onDemand.lastInjectionModeDetailText)
        let fallback = makeHealth(includedBytes: 7_000_000, includedFileCount: 406, mode: .fullFallback)
        XCTAssertTrue(fallback.lastInjectionModeDetailText.contains("回退"), fallback.lastInjectionModeDetailText)
        let full = makeHealth(includedBytes: 7_000_000, includedFileCount: 406)
        XCTAssertTrue(full.lastInjectionModeDetailText.contains("全量"), full.lastInjectionModeDetailText)
    }

    /// 新字段带默认值：既有构造点（体检页 VC、本文件工厂）不传也能编译。
    /// memberwise init 对带默认值属性会生成默认参数，但它是 internal 的，
    /// 公开 struct 跨模块构造必须显式 init——这条用例锁住「扩展不破坏
    /// 调用方」这个前提。
    /// review fix：必须**裸调 init 省略新参数**才能真正锁住默认值——
    /// 走 makeHealth 工厂时新参数被工厂自己的默认值显式填上了，
    /// 删掉 init 的 `= 0` 该测试也照样通过（防线比声称的弱一档）
    func testLastInjectionUncompressedBytes_defaultsToZero() {
        let h = WorkspaceSnapshotHealth(
            includedFileCount: 1,
            includedBytes: 1,
            maxBytes: 32 * 1024 * 1024,
            maxFileCount: 2000,
            folders: [],
            lastInjectionAt: nil,
            lastInjectionFileCount: 0,
            lastInjectionPayloadBytes: 0,
            lastSeedSkipped: false,
            lastSeedOverGuard: false,
            fingerprintStable: false
        )
        XCTAssertEqual(h.lastInjectionUncompressedBytes, 0)
    }

    /// 旧 b64 通道删除的回归防线。留着旧变量会让「取数到底走哪条」在排障时
    /// 多一个分叉，且 Swift 侧已不再写它——JS 侧留分支等于留一段死代码
    func testHostJs_hasNoLegacyB64Channel() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/TerrariumTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // 包根
            .appendingPathComponent("Sources/Terrarium/Resources/pyodide-host/host.js")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("__MS_WS_B64__"), "host.js 不得再出现旧通道变量")
        XCTAssertTrue(text.contains("__MS_WS_URL__"), "新通道变量必须还在")
        XCTAssertTrue(text.contains("_msz.decompress(_ws_buf, -15)"),
                      "仍须用 -15 解裸 DEFLATE（Apple COMPRESSION_ZLIB 无头无校验尾）")
        XCTAssertTrue(text.contains("raise RuntimeError('ws buffer missing')"),
                      "buffer 缺失要显式报错，不能退化成静默空解")
    }
}
