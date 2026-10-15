package com.yesha.timefloat.time

/**
 * 一次原始采样结果。
 *
 * 约定：serverUtcMsAtRecv 已经做了「单程延时」补偿，它表达的意思是
 *      「在本地单调时钟 monoMsAtRecv 这一刻，服务器时钟显示的 UTC 毫秒值」。
 * 所以 offset = serverUtcMsAtRecv - monoMsAtRecv 就是本地单调时钟到服务器时钟的固定偏移量。
 */
data class RawSync(
    val serverUtcMsAtRecv: Long,
    val monoMsAtRecv: Long,
    val rttMs: Long,
    /** 命中的具体接口 / 策略，用于界面展示和排障 */
    val strategy: String,
    /** 是否毫秒精度（false = 秒级兜底，如 HTTP Date 头） */
    val preciseMs: Boolean
) {
    /** 偏移量：服务器 UTC - 本地单调毫秒 */
    val offsetMs: Long get() = serverUtcMsAtRecv - monoMsAtRecv
}

interface TimeSource {
    val id: String
    val label: String

    /** 一轮校时抓几次。请求越重（比如几百 KB 的页面）就该抓越少，避免被风控 */
    val preferredSamples: Int
        get() = com.yesha.timefloat.Config.SAMPLES_PER_SYNC

    /**
     * 该源固有的系统性误差余量（毫秒），会加进不确定度显示里。
     * 例如 HTTP Date 头只有秒精度，就额外加 500ms；SSR 页面 TTFB 抖动大就加 80ms。
     */
    val extraUncertaintyMs: Long
        get() = 0L

    /**
     * 该源自己已经做了多次采样聚合（比如 Date 头的秒边界交集），
     * 那么 Sampler 就不该再给它的结果叠一个 rtt/2 —— 否则是重复计算误差。
     */
    val selfAggregated: Boolean
        get() = false

    /** 抓一次服务器时间；失败直接抛异常 */
    @Throws(Exception::class)
    fun fetch(): RawSync
}
