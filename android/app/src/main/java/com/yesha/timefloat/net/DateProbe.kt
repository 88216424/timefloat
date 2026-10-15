package com.yesha.timefloat.net

import com.yesha.timefloat.Config
import com.yesha.timefloat.util.Mono
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * 只取 HTTP `Date` 响应头的极轻量探针（不读 body）。
 *
 * 为什么值得单独做：京东已经没有可用的毫秒时间戳接口了（老接口全部下线，
 * 商品页的 serverTime 字段也时有时无），唯一稳定存在的就是标准 `Date` 头 —— 但它只有**秒**精度。
 * 单次用它当时间会得到 0~1000ms 的随机误差（这就是"一会差 700 一会差 400"的来源）。
 * 解决办法不是换接口，而是**多次采样 + 秒边界交集**（见 DateIntersector）：
 *   每次采样知道「服务器生成这个响应时，它的时钟落在 [D, D+1000) 区间内」，
 *   把很多次这样的区间求交集，就能把真实偏移量夹到几十毫秒以内。
 */
data class DateSample(
    /** 偏移量下界：服务器UTC - 本地单调毫秒 */
    val lowerBoundOffsetMs: Long,
    /** 模型误差余量（毫秒）：路径不对称带来的不确定度，取 rtt/2 + 5 */
    val marginMs: Long,
    val dateMs: Long,
    val rttMs: Long,
    val monoAtRecvMs: Long
)

object DateProbe {

    private val FMT = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("GMT")
    }

    /**
     * 发一次请求，只等响应头到达就返回（连 body 都不读，最省时间）。
     * 采样时刻取「响应头到齐」的瞬间，比读完 body 再取时间准确得多。
     */
    fun probe(
        url: String,
        connectTimeoutMs: Int = Config.DATE_PROBE_CONNECT_TIMEOUT_MS,
        readTimeoutMs: Int = Config.DATE_PROBE_READ_TIMEOUT_MS,
        headers: Map<String, String> = emptyMap()
    ): DateSample? {
        val t0 = System.nanoTime()
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = connectTimeoutMs
            readTimeout = readTimeoutMs
            instanceFollowRedirects = true
            requestMethod = "GET"
            setRequestProperty("User-Agent", Config.USER_AGENT)
            setRequestProperty("Accept-Encoding", "identity")   // 不求压缩，省一次解压
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
        }
        try {
            val code = conn.responseCode                 // 走到这里，响应头已经到齐
            val recvMono = Mono.ms()
            val rtt = (System.nanoTime() - t0) / 1_000_000
            if (code !in 200..499) return null
            val raw = conn.getHeaderField("Date") ?: return null
            val dateMs = synchronized(FMT) { FMT.parse(raw)?.time } ?: return null
            // L = 服务器生成该响应时的本地单调时刻 ≈ 收到时刻 - 单程时延
            val l = recvMono - rtt / 2
            return DateSample(
                lowerBoundOffsetMs = dateMs - l,
                marginMs = rtt / 2 + 5,
                dateMs = dateMs,
                rttMs = rtt,
                monoAtRecvMs = recvMono
            )
        } catch (_: Exception) {
            return null
        } finally {
            try {
                conn.disconnect()
            } catch (_: Throwable) {
            }
        }
    }
}
