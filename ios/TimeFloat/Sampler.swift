import Foundation

struct SyncSummary {
    let offsetMs: Double
    let anchorMonoMs: Int64
    let bestRttMs: Int64
    let jitterMs: Int64
    let usedSamples: Int
    let totalSamples: Int
    let strategy: String
    let preciseMs: Bool
    let uncertaintyMs: Int64
    let tookMs: Int64
}

/// 多次采样 + min-RTT 过滤 + 中位数剔离群，整轮带硬预算。
/// 网络抖动是重尾分布，平均会被偶发的大 RTT 样本拖歪几十毫秒；
/// 只信 RTT 最小的那一批（≈没有排队的理想路径）才是抢购该有的精度。
enum Sampler {
    static func run(_ source: TimeSource) async throws -> SyncSummary {
        let start = monoMs()
        let deadline = start + Cfg.syncBudgetMs
        let rounds = max(1, source.preferredSamples)
        var raws: [RawSync] = []
        var lastError: Error?
        var timedOut = false

        for i in 0..<rounds {
            do {
                raws.append(try await source.fetch())
            } catch {
                lastError = error
            }
            if i == rounds - 1 { break }
            if monoMs() > deadline { timedOut = true; break }
            try? await Task.sleep(nanoseconds: Cfg.sampleGapMs * 1_000_000)
        }

        let took = monoMs() - start

        guard !raws.isEmpty else {
            throw lastError ?? NSError(domain: "TimeFloat", code: 30,
                                       userInfo: [NSLocalizedDescriptionKey: timedOut ? "采样超时" : "采样失败"])
        }

        let allPrecise = raws.allSatisfy { $0.preciseMs }
        let penalty = source.extraUncertaintyMs + (allPrecise ? 0 : 500)

        if raws.count == 1 {
            let only = raws[0]
            // 自聚合的源（Date 秒边界交集）已经吃掉了 rtt 的影响，不要再叠 rtt/2
            let rttTerm: Int64 = source.selfAggregated ? 0 : only.rttMs / 2
            return SyncSummary(offsetMs: Double(only.offsetMs),
                               anchorMonoMs: only.monoMsAtRecv,
                               bestRttMs: only.rttMs,
                               jitterMs: 0,
                               usedSamples: 1,
                               totalSamples: 1,
                               strategy: only.strategy + (rounds > 1 ? "（单次采样）" : ""),
                               preciseMs: only.preciseMs,
                               uncertaintyMs: rttTerm + penalty,
                               tookMs: took)
        }

        raws.sort { $0.rttMs < $1.rttMs }
        let takeN = max(1, Int(ceil(Double(raws.count) * Cfg.minRttWindowRatio)))
        let best = Array(raws.prefix(takeN))

        let offsets = best.map { Double($0.offsetMs) }.sorted()
        let median: Double = offsets.count % 2 == 1
            ? offsets[offsets.count / 2]
            : (offsets[offsets.count / 2 - 1] + offsets[offsets.count / 2]) / 2
        var kept = offsets.filter { abs($0 - median) <= Cfg.outlierMs }
        if kept.isEmpty { kept = offsets }

        let allBestPrecise = best.allSatisfy { $0.preciseMs }

        return SyncSummary(offsetMs: kept.reduce(0, +) / Double(kept.count),
                           anchorMonoMs: best[0].monoMsAtRecv,
                           bestRttMs: best[0].rttMs,
                           jitterMs: Int64(kept.last! - kept.first!),
                           usedSamples: kept.count,
                           totalSamples: raws.count,
                           strategy: best[0].strategy + (timedOut ? "（预算内 \(raws.count) 次采样）" : ""),
                           preciseMs: allBestPrecise,
                           uncertaintyMs: best[0].rttMs / 2 + source.extraUncertaintyMs + (allBestPrecise ? 0 : 500),
                           tookMs: took)
    }
}
