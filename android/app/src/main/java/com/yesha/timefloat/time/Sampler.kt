package com.yesha.timefloat.time

import com.yesha.timefloat.Config
import java.io.IOException

/**
 * 采样器：多次采样 + min-RTT 过滤 + 中位数剔离群。
 *
 * 为什么要这么麻烦：服务器时间戳本身是准的，误差全来自"从服务器发出到我这里用了多久"。
 * 我们用 rtt/2 补偿，误差 ≈ 单程抖动。而网络抖动是重尾分布（大部分 20ms，偶尔 400ms），
 * 直接求平均会被那个 400ms 的样本拖歪几十毫秒。所以只信 RTT 最小的那一批
 * （它们最接近"没有排队"的理想路径），再在窗口内用中位数剔掉偶发偏差。
 *
 * ⚠ 关键约束：整轮采样有硬预算（SYNC_BUDGET_MS）。以前没有预算，
 * 网络不好时 4 次采样 × 每次 8 秒超时 = 30 多秒都停在"校时中"，
 * 现在预算一到就拿已有样本收工，最坏也不会超过十几秒。
 */
object Sampler {

    data class Summary(
        val offsetMs: Double,
        val anchorMonoMs: Long,
        val bestRttMs: Long,
        val jitterMs: Long,
        val usedSamples: Int,
        val totalSamples: Int,
        val strategy: String,
        val preciseMs: Boolean,
        /** 估计不确定度（毫秒） */
        val uncertaintyMs: Long,
        /** 这一轮实际花了多久 */
        val tookMs: Long
    )

    @Throws(IOException::class)
    fun run(source: TimeSource): Summary {
        val startedNs = System.nanoTime()
        val deadlineNs = startedNs + Config.SYNC_BUDGET_MS * 1_000_000
        val rounds = source.preferredSamples.coerceAtLeast(1)
        val raws = ArrayList<RawSync>(rounds)
        var lastErr: Exception? = null
        var timedOut = false

        for (i in 0 until rounds) {
            try {
                raws.add(source.fetch())
            } catch (e: Exception) {
                lastErr = e
            }
            if (i == rounds - 1) break
            if (System.nanoTime() > deadlineNs) {
                timedOut = true
                break
            }
            try {
                Thread.sleep(Config.SAMPLE_GAP_MS)
            } catch (_: InterruptedException) {
            }
        }

        val took = (System.nanoTime() - startedNs) / 1_000_000

        if (raws.isEmpty()) {
            throw IOException(lastErr?.message ?: (if (timedOut) "采样超时" else "采样失败"))
        }

        val coarse = !raws.all { it.preciseMs }
        val penalty = source.extraUncertaintyMs + if (coarse) 500L else 0L

        if (raws.size == 1) {
            val only = raws[0]
            // 自聚合的源（如京东/北京的 Date 交集）不要再叠 rtt/2，避免重复计算误差
            val rttTerm = if (source.selfAggregated) 0L else only.rttMs / 2
            return Summary(
                offsetMs = only.offsetMs.toDouble(),
                anchorMonoMs = only.monoMsAtRecv,
                bestRttMs = only.rttMs,
                jitterMs = 0,
                usedSamples = 1,
                totalSamples = 1,
                strategy = only.strategy + if (rounds > 1) "（单次采样）" else "",
                preciseMs = only.preciseMs,
                uncertaintyMs = rttTerm + penalty,
                tookMs = took
            )
        }

        // 第一道：min-RTT 窗口
        raws.sortBy { it.rttMs }
        val takeN = maxOf(1, Math.ceil(raws.size * Config.MIN_RTT_WINDOW_RATIO).toInt())
        val best = raws.subList(0, takeN)

        // 第二道：中位数离群剔除
        val offsets = best.map { it.offsetMs.toDouble() }.sorted()
        val median = if (offsets.size % 2 == 1) offsets[offsets.size / 2]
        else (offsets[offsets.size / 2 - 1] + offsets[offsets.size / 2]) / 2.0
        val kept = offsets.filter { Math.abs(it - median) <= Config.OUTLIER_MS }.ifEmpty { offsets }

        val bestRtt = best.first().rttMs
        val allPrecise = best.all { it.preciseMs }

        return Summary(
            offsetMs = kept.sum() / kept.size,
            anchorMonoMs = best.first().monoMsAtRecv,
            bestRttMs = bestRtt,
            jitterMs = (kept.last() - kept.first()).toLong(),
            usedSamples = kept.size,
            totalSamples = raws.size,
            strategy = best.first().strategy +
                if (timedOut) "（预算内 ${raws.size} 次采样）" else "",
            preciseMs = allPrecise,
            uncertaintyMs = bestRtt / 2 + source.extraUncertaintyMs + if (allPrecise) 0L else 500L,
            tookMs = took
        )
    }
}
