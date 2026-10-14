//
//  PyodideBridgeZlibTests.swift
//  Terrarium（fork）
//
//  工作区快照压缩通道的 zlib 层单测——纯逻辑、无 WebView，Mac `swift test`
//  秒级完成。
//
//  为什么必须单测（而不等真机）：这是全链**唯一**的「格式正确性」锚点——
//  压错了要等到真机 WS_RESTORE 失败才发现，排查成本极高。而
//  Apple↔Apple 往返抓不到 wbits 错误（两边都按裸 DEFLATE 解），
//  必须靠**跨语言夹具**（Python 侧预生成）才能证明格式对。
//
//  运行：swift test --filter PyodideBridgeZlibTests
//

import XCTest
@testable import Terrarium

final class PyodideBridgeZlibTests: XCTestCase {

    // MARK: - 夹具

    /// 与真机同构的最小快照载荷（`[{p,d(base64)}]`）
    private let payload = Data(
        (#"[{"p":"Documents/tmp/a.txt","d":"aGVsbG8gd29ybGQ="},"# +
         #"{"p":"Documents/data/x.csv","d":"YSxiLGMKMSwyLDMK"}]"#).utf8
    )

    /// **跨语言锚点夹具**：Python 侧 `zlib.compressobj(6, zlib.DEFLATED, -15)`
    /// 对上面 payload 预生成的裸 DEFLATE（104 → 86 字节），base64 写死。
    /// 生成方式（勿手改，改动须同步重新生成）：
    ///   python3 -c "import zlib,base64;co=zlib.compressobj(6,zlib.DEFLATED,-15);\
    ///     print(base64.b64encode(co.compress(PAYLOAD)+co.flush()).decode())"
    /// 该夹具已验证：Python `zlib.decompress(raw)` 抛
    /// `Error -3 incorrect header check`（证明无 RFC1950 头），
    /// `zlib.decompress(raw, -15)` 还原成功。
    private let pythonRawDeflateB64 =
        "i65WKlCyUnLJTy7NTc0rKdYvyS3QT9QrqShR0lFKAcokuocVJ7lbpKcYWVYmuQfaKtXqoGtJSSxJ1K/QSy4ug+qJDK7I9HH39fYNLq/0cfH1VqqNBQA="

    // MARK: - 往返（Apple → Apple）

    func testRoundTrip_appleToApple_byteExact() {
        guard let compressed = PyodideBridge.zlibCompress(payload) else {
            return XCTFail("压缩失败")
        }
        XCTAssertLessThan(compressed.count, payload.count, "文本载荷应压得更小")
        guard let restored = PyodideBridge.zlibDecompress(compressed, decompressedSize: payload.count) else {
            return XCTFail("解压失败")
        }
        XCTAssertEqual(restored, payload, "往返必须逐字节一致")
    }

    /// 1MB 级类 CSV 文本：真机 26.8MB 以文本为主，压缩率是可观测收益的核心
    func testRoundTrip_largeText_compressionRatio() {
        let line = "603517,绝味食品,12.34,5678,2026-10-12 15:00:00,买入\n"
        var big = Data()
        while big.count < 1_000_000 { big.append(Data(line.utf8)) }
        guard let compressed = PyodideBridge.zlibCompress(big) else { return XCTFail("压缩失败") }
        let ratio = Double(compressed.count) / Double(big.count)
        XCTAssertLessThan(ratio, 0.5, "文本压缩率应 > 50%（实测 \(String(format: "%.1f", (1 - ratio) * 100))%）")
        guard let restored = PyodideBridge.zlibDecompress(compressed, decompressedSize: big.count) else {
            return XCTFail("解压失败")
        }
        XCTAssertEqual(restored, big)
    }

    // MARK: - 跨语言锚点（本文件的核心价值）

    /// **证明 wbits 正确**：Apple 侧必须能解开 Python 用 `-15`（裸 DEFLATE）
    /// 压出来的流。若误用 RFC1950 语义，这里会失败——而 Apple↔Apple 往返
    /// 抓不到这个错。
    func testCrossLanguage_pythonRawDeflate_decodedByteExact() {
        guard let raw = Data(base64Encoded: pythonRawDeflateB64) else { return XCTFail("夹具 base64 非法") }
        guard let restored = PyodideBridge.zlibDecompress(raw, decompressedSize: payload.count) else {
            return XCTFail("Apple 侧解不开 Python 的裸 DEFLATE——wbits 语义错误")
        }
        XCTAssertEqual(restored, payload, "跨语言还原必须逐字节一致")
    }

    /// 反向：Apple 压缩 → 再走 Apple 解压，且产物与 Python 夹具解出的内容同源
    /// （确保两侧 encode 语义可比，不引入各自为政的私有格式）
    func testCrossLanguage_appleCompressed_isSamePayload() {
        guard let compressed = PyodideBridge.zlibCompress(payload),
              let restored = PyodideBridge.zlibDecompress(compressed, decompressedSize: payload.count),
              let raw = Data(base64Encoded: pythonRawDeflateB64),
              let fromPython = PyodideBridge.zlibDecompress(raw, decompressedSize: payload.count) else {
            return XCTFail("压缩/解压链路失败")
        }
        XCTAssertEqual(restored, fromPython, "两条来源解压出的内容必须一致")
    }

    // MARK: - 边界（都是真机踩过的坑）

    /// ⚠️ 目的缓冲分配陷阱：空工作区 payload 是 `[]` 2 字节，按 src.count
    /// 分配会静默失败返回 0 → 新装设备静默走降级。必须能压且能解回来
    func testEmptyWorkspacePayload_twoBytes() {
        let two = Data("[]".utf8)
        guard let compressed = PyodideBridge.zlibCompress(two) else {
            return XCTFail("2 字节载荷压缩失败（目的缓冲分配不足的典型症状）")
        }
        XCTAssertGreaterThan(compressed.count, 0)
        guard let restored = PyodideBridge.zlibDecompress(compressed, decompressedSize: two.count) else {
            return XCTFail("2 字节载荷解压失败")
        }
        XCTAssertEqual(restored, two)
    }

    /// 单字节与随机二进制（不可压缩数据）不崩、不静默截断
    func testIncompressibleData_roundTrip() {
        var random = Data(count: 4096)
        random.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8.random(in: 0...255) }
        }
        guard let compressed = PyodideBridge.zlibCompress(random) else { return XCTFail("随机数据压缩失败") }
        // 不可压缩时 DEFLATE 会略微膨胀，缓冲区公式必须容得下
        XCTAssertGreaterThan(compressed.count, random.count,
                             "不可压缩数据允许膨胀（缓冲区公式须容得下）")
        guard let restored = PyodideBridge.zlibDecompress(compressed, decompressedSize: random.count) else {
            return XCTFail("随机数据解压失败")
        }
        XCTAssertEqual(restored, random)
    }

    func testCompress_emptyInput_returnsNil() {
        XCTAssertNil(PyodideBridge.zlibCompress(Data()), "空输入不产出载荷（调用方按降级处理）")
    }

    func testDecompress_garbageInput_returnsNil() {
        let garbage = Data([0xFF, 0x00, 0xAB, 0xCD, 0x01, 0x02, 0x03, 0x04])
        XCTAssertNil(PyodideBridge.zlibDecompress(garbage, decompressedSize: 1_000_000))
    }

    func testDecompress_zeroSize_returnsNil() {
        guard let compressed = PyodideBridge.zlibCompress(payload) else { return XCTFail("压缩失败") }
        XCTAssertNil(PyodideBridge.zlibDecompress(compressed, decompressedSize: 0))
    }
}
