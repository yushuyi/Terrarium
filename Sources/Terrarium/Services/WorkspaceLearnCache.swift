//
//  WorkspaceLearnCache.swift
//  Terrarium（fork）
//
//  二期按需注入：补漏学习缓存（二期方案 §4.5，审查二 #1）。
//
//  问题背景：补漏是一次性的——第二轮运行时预测器从同一脚本重新算出
//  同样的注入集，对补漏进来的文件毫无线索 → 重注入 → restore 删掉 →
//  FN → 再补漏重跑。对「写死路径读配置」这类最常见脚本，每次运行都
//  两轮 + 副作用两遍 + 提示刷屏，相对全量模式是系统性退化。
//
//  设计：补漏成功的文件按 code 哈希记入轻量缓存，下次自动并入注入集。
//    键：code 串 SHA256 前 16 字节 hex（-c 与 script 形态通用——script
//        源码同样内嵌在引导 code 里，内容稳定）
//    值：补漏轮补充的 Documents rel 列表
//    存储：Library/Caches/PyodideWsLearn.json（Caches 被系统回收 merely
//        回退到首跑两遍）；LRU 上限 64 条 / 文件 64KB，超限逐出最旧
//  纯存储层：读侧收编的双闸（宿主存在性 + wsIncludedImpl）在调用方
//  PyodideBridge 完成——学到手的路径不比 argv 提取的更受信任。
//

import Foundation
import CryptoKit

enum WorkspaceLearnCache {

    /// LRU 条目上限（方案 §4.5）
    nonisolated static let maxEntries = 64
    /// 缓存文件体积上限（方案 §4.5：64KB）
    nonisolated static let maxFileBytes = 64 * 1024

    struct Entry: Codable {
        let k: String
        var rels: [String]
        var at: Double
    }

    private struct Payload: Codable {
        var version: Int = 1
        var entries: [Entry] = []
    }

    // MARK: - 键

    /// code 串 SHA256 前 16 字节 hex
    nonisolated static func key(forCode code: String) -> String {
        let digest = SHA256.hash(data: Data(code.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 读 / 写

    /// 读取键对应的 rel 列表。文件缺失/损坏/键不存在 → nil（缓存是增益
    /// 而非依赖，任何读取失败都静默降级）
    nonisolated static func learnedRels(forKey key: String, cacheURL: URL? = nil) -> [String]? {
        guard let url = cacheURL ?? defaultURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let idx = payload.entries.firstIndex(where: { $0.k == key }) else { return nil }
        return payload.entries[idx].rels
    }

    /// 记账（LRU：命中即续期并合并去重；超限逐出最旧）。补漏轮重跑收敛
    /// （exit 0）才由调用方调用——两轮仍失败的负样本不记（§4.5）。
    nonisolated static func record(code: String, rels: [String], cacheURL: URL? = nil) {
        guard !rels.isEmpty, let url = cacheURL ?? defaultURL() else { return }
        let fm = FileManager.default
        var payload = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
            ?? Payload()
        let k = key(forCode: code)
        let now = Date().timeIntervalSince1970
        if let idx = payload.entries.firstIndex(where: { $0.k == k }) {
            var merged = payload.entries[idx].rels
            for r in rels where !merged.contains(r) { merged.append(r) }
            payload.entries[idx].rels = merged
            payload.entries[idx].at = now
        } else {
            payload.entries.append(Entry(k: k, rels: rels, at: now))
        }
        payload.entries.sort { $0.at > $1.at }
        if payload.entries.count > maxEntries {
            payload.entries.removeLast(payload.entries.count - maxEntries)
        }
        guard var out = try? JSONEncoder().encode(payload) else { return }
        // 文件体积逐出：超 64KB 从最旧开始删，至少保留 1 条
        while out.count > maxFileBytes && payload.entries.count > 1 {
            payload.entries.removeLast()
            guard let re = try? JSONEncoder().encode(payload) else { break }
            out = re
        }
        guard out.count <= maxFileBytes else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? out.write(to: url, options: .atomic)
    }

    /// 剪除键内失效 rel（读侧双闸失败时调用：文件被删/移出后自动失效；
    /// rels 剪空则整键删除）。
    nonisolated static func prune(key: String, rels: [String], cacheURL: URL? = nil) {
        guard !rels.isEmpty,
              let url = cacheURL ?? defaultURL(),
              let data = try? Data(contentsOf: url),
              var payload = try? JSONDecoder().decode(Payload.self, from: data),
              let idx = payload.entries.firstIndex(where: { $0.k == key }) else { return }
        payload.entries[idx].rels.removeAll { rels.contains($0) }
        if payload.entries[idx].rels.isEmpty {
            payload.entries.remove(at: idx)
        }
        guard let out = try? JSONEncoder().encode(payload) else { return }
        try? out.write(to: url, options: .atomic)
    }

    nonisolated private static func defaultURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PyodideWsLearn.json")
    }
}
