package com.yesha.timefloat.time

import com.yesha.timefloat.net.DateSample

/**
 * 秒边界交集估计器 —— 把只有「秒」精度的 HTTP Date 头，夹逼成几十毫秒精度的时钟。
 *
 * 原理（一句话）：每次采样都得到一条约束
 *
 *     dateMs ≤ 本地单调L + 偏移量 < dateMs + 1000      （dateMs 是服务器时钟被截断到整秒的值）
 *
 * 其中 L = 收到响应头的时刻 - rtt/2（我们对该响应生成时刻的估计），
 * 令 v = dateMs - L，则偏移量必然落在 [v - margin, v + 1000 + margin)，
 * margin = rtt/2 + 5ms 用来覆盖「请求/响应路径不对称」这个未知量。
 *
 * 把 N 次采样的区间求交集：
 *     lo = max(v_i - margin_i)      hi = min(v_i + 1000 + margin_i)
 * 因为每次采样命中的「秒内相位」不同，交集宽度 = 1000 + 2m - 相位跨度，
 * 采样够多（相位铺满一整秒）时宽度就收敛到 2m —— 对 rtt 26ms 的 api.m.jd.com 来说约 ±25ms。
 *
 * 这就是为什么单次只能 ±500ms 的 Date 头，多点采样之后能当毫秒钟用。
 */
class DateIntersector(private val window: Int = 28) {

    private data class Constraint(val v: Long, val margin: Long)

    private val list = ArrayDeque<Constraint>()

    @Volatile
    private var lastMonoMs = 0L

    @Volatile
    var totalAccepted: Int = 0
        private set

    @Volatile
    var lastMinRttMs: Long = -1
        private set

    data class Estimate(val offsetMs: Long, val halfWidthMs: Long, val samples: Int)

    /** 加一条约束；返回当前是否能给出估计 */
    fun add(sample: DateSample, monoNowMs: Long): Boolean {
        // 单调钟倒退 = 设备重启，之前的约束全部作废
        if (lastMonoMs != 0L && monoNowMs < lastMonoMs) list.clear()
        lastMonoMs = monoNowMs
        list.addLast(Constraint(sample.lowerBoundOffsetMs, sample.marginMs))
        while (list.size > window) list.removeFirst()
        totalAccepted++
        if (lastMinRttMs < 0 || sample.rttMs < lastMinRttMs) lastMinRttMs = sample.rttMs
        return estimate() != null
    }

    fun estimate(): Estimate? {
        if (list.size < MIN_SAMPLES) return null
        var lo = Long.MIN_VALUE
        var hi = Long.MAX_VALUE
        for (c in list) {
            if (c.v - c.margin > lo) lo = c.v - c.margin
            if (c.v + 1000 + c.margin < hi) hi = c.v + 1000 + c.margin
        }
        if (hi <= lo) {
            // 约束互相矛盾：要么本机时钟被改过，要么采样期间发生了跳变 —— 丢掉重来
            list.clear()
            lastMinRttMs = -1
            return null
        }
        return Estimate(offsetMs = (lo + hi) / 2, halfWidthMs = (hi - lo) / 2, samples = list.size)
    }

    fun reset() {
        list.clear()
        lastMinRttMs = -1
    }

    val acceptedSamples: Int get() = list.size

    companion object {
        /** 少于这么多条约束就不急着给结果 */
        const val MIN_SAMPLES = 6
    }
}
