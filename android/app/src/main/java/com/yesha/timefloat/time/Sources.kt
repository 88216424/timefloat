package com.yesha.timefloat.time

import com.yesha.timefloat.Config
import com.yesha.timefloat.net.DateProbe
import com.yesha.timefloat.net.Http
import com.yesha.timefloat.net.Net
import com.yesha.timefloat.net.SntpClient
import com.yesha.timefloat.util.Mono
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

private fun hostOf(url: String) = url.removePrefix("https://").removePrefix("http://").trimEnd('/')

/** 轮换取候选地址：避免每次都卡在同一个坏服务器上 */
private class Rotator(private val list: List<String>) {
    private val cursor = AtomicInteger(0)

    fun take(n: Int): List<String> {
        if (list.isEmpty()) return emptyList()
        val start = ((cursor.getAndIncrement() % list.size) + list.size) % list.size
        return (0 until n.coerceAtMost(list.size)).map { list[(start + it) % list.size] }
    }
}

/**
 * 用 Date 头 + 秒边界交集的方式抓一组样本。
 *
 * ★ 关键：整轮有**硬预算**（budgetMs）。以前没有预算，单次请求超时 5s，
 *   网络一卡一整轮能跑 60 秒以上，把线程池占死、把调度链拖断（"不会自动校时"就是这么来的）。
 *   现在到点就用手上的样本收工。
 */
private fun probeBurst(
    urls: List<String>,
    samplesPerUrl: Int,
    gapMs: Long,
    budgetMs: Long,
    intersector: DateIntersector,
    extraHeaders: Map<String, String> = emptyMap()
): Pair<String?, Int> {
    val deadline = Mono.ms() + budgetMs
    var accepted = 0
    var goodUrl: String? = null
    var outOfTime = false

    for (url in urls) {
        var ok = 0
        for (i in 0 until samplesPerUrl) {
            if (Mono.ms() > deadline) {
                outOfTime = true
                break
            }
            try {
                val s = DateProbe.probe(url, headers = extraHeaders)
                if (s != null && s.rttMs <= Config.DATE_PROBE_MAX_RTT_MS) {
                    intersector.add(s, Mono.ms())
                    ok++
                    accepted++
                }
            } catch (_: Exception) {
            }
            try {
                Thread.sleep(gapMs)
            } catch (_: InterruptedException) {
            }
        }
        if (ok > 0 && goodUrl == null) {
            goodUrl = url
            if (intersector.estimate() != null) break
        }
        if (outOfTime) break
    }
    return goodUrl to accepted
}

// =====================================================================================
//  北京时间
//  主通道 SNTP（毫秒精度）；NTP 全线不通时（蜂窝网常封 UDP 123）自动切到
//  HTTP Date 头 + 秒边界交集，精度也能到几十毫秒，不再是以前那种 ±500ms 的粗值。
// =====================================================================================
class BeijingSource : TimeSource {
    override val id = "bj"
    override val label = "北京"

    private val rotator = Rotator(Config.SNTP_HOSTS)
    private val intersector = DateIntersector()

    @Volatile
    private var ntpDownUntilMono = 0L

    @Volatile
    private var lastModeDateOnly = false

    @Volatile
    private var lastHalfWidthMs = 30L

    /** 走 Date 兜底时，交集本身就是多次采样的结果，不需要 Sampler 再多轮 */
    override val preferredSamples: Int
        get() = if (Mono.ms() < ntpDownUntilMono) 1 else Config.SAMPLES_PER_SYNC

    override val selfAggregated: Boolean
        get() = Mono.ms() < ntpDownUntilMono

    override val extraUncertaintyMs: Long
        get() = if (lastModeDateOnly) (lastHalfWidthMs + 8).coerceAtLeast(10) else 3L

    override fun fetch(): RawSync {
        if (!Net.online()) throw IOException("手机没有网络")

        // ---------- 1) SNTP ----------
        if (Mono.ms() >= ntpDownUntilMono) {
            for (h in rotator.take(Config.SNTP_HOSTS_PER_SAMPLE)) {
                try {
                    val r = SntpClient.request(h)
                    lastModeDateOnly = false
                    return RawSync(
                        serverUtcMsAtRecv = r.serverUtcMsAtRecv,
                        monoMsAtRecv = Mono.ms(),
                        rttMs = r.rttMs,
                        strategy = "SNTP $h (stratum ${r.stratum})",
                        preciseMs = true
                    )
                } catch (_: Exception) {
                }
            }
            // 两台都不通 → 大概率是 UDP 123 被封，先冷却一阵别再白等
            ntpDownUntilMono = Mono.ms() + Config.BJ_NTP_COOLDOWN_MS
        }

        // ---------- 2) HTTP Date 头秒边界交集兜底 ----------
        // 注意：这里**不要** reset 交集器 —— 跨轮次累积才能把区间越收越紧
        // （设备重启时 DateIntersector 自己会检测单调钟倒退并清空）
        val (url, accepted) = probeBurst(
            Config.BJ_DATE_PROBE_URLS,
            Config.BJ_DATE_PROBE_SAMPLES,
            Config.JD_PROBE_GAP_MS,
            Config.BJ_BURST_BUDGET_MS,
            intersector
        )
        val est = intersector.estimate()
            ?: throw IOException("NTP 不通，HTTP Date 兜底样本不足（本轮有效 $accepted 次）")
        lastModeDateOnly = true
        lastHalfWidthMs = est.halfWidthMs.coerceAtLeast(8)
        val mono = Mono.ms()
        return RawSync(
            serverUtcMsAtRecv = mono + est.offsetMs,
            monoMsAtRecv = mono,
            rttMs = intersector.lastMinRttMs.coerceAtLeast(1),
            strategy = "HTTP Date 秒边界交集 ${hostOf(url ?: "")}（${est.samples} 样本 · ±${est.halfWidthMs}ms）",
            preciseMs = true
        )
    }
}

// =====================================================================================
//  淘宝服务器时间（mtop.common.getTimestamp，毫秒精度，响应体几十字节）
// =====================================================================================
class TaobaoSource : TimeSource {
    override val id = "taobao"
    override val label = "淘宝"
    override val preferredSamples = Config.SAMPLES_PER_SYNC
    override val extraUncertaintyMs = 5L

    override fun fetch(): RawSync {
        if (!Net.online()) throw IOException("手机没有网络")
        var lastErr: String? = null

        for (base in Config.TAOBAO_URLS) {
            val url = if (base.endsWith("_=")) base + System.currentTimeMillis() else base
            try {
                val res = Http.get(
                    url,
                    headers = mapOf("Referer" to "https://m.taobao.com/", "Accept" to "application/json")
                )
                if (res.status !in 200..299) {
                    lastErr = "HTTP ${res.status}"
                    continue
                }
                val m = Regex("\"t\"\\s*:\\s*\"?(\\d{10,13})\"?").find(res.body)
                if (m == null) {
                    lastErr = "响应无 t 字段"
                    continue
                }
                var t = m.groupValues[1].toLong()
                if (t < 1_000_000_000_000L) t *= 1000L
                if (Math.abs(t - System.currentTimeMillis()) > 86_400_000L) {
                    lastErr = "返回的时间戳不合理"
                    continue
                }
                return RawSync(
                    serverUtcMsAtRecv = t + res.rttMs / 2,
                    monoMsAtRecv = res.monoAtRecvMs,
                    rttMs = res.rttMs,
                    strategy = "mtop.common.getTimestamp",
                    preciseMs = true
                )
            } catch (e: Exception) {
                lastErr = e.message
            }
        }
        throw IOException("淘宝：${lastErr ?: "不可用"}")
    }
}

// =====================================================================================
//  京东服务器时间
//
//  为什么不是抓商品页的 serverTime 了（实测数据说话）：
//    · 2026-10-15 复测：item.m.jd.com 商品页对同一批 SKU 连续返回的都是 3KB 的页面，
//      里面既没有 presellInfo 也没有 serverTime —— 那个字段只在商品有「预约/抢购」活动时才渲染；
//    · 一旦字段缺失，程序就退到秒精度的 Date 头 → 误差在 0~1000ms 之间随机跳，
//      表现就是用户看到的"一会差 700，一会差 400"；
//    · 换成 api.m.jd.com 的 Date 头 + 秒边界交集后：rtt 26ms、交集宽度 64~80ms、
//      换算出来的偏移量与 NTP/淘宝互差 2~65ms。
//  所以这路现在就是：极小的响应头取样 + 交集夹逼，稳定且几十毫秒级。
// =====================================================================================
class JdSource : TimeSource {
    override val id = "jd"
    override val label = "京东"

    /** 内部自己做 12 次采样，所以交给 Sampler 的轮数就是 1 */
    override val preferredSamples = 1
    override val selfAggregated = true

    private val intersector = DateIntersector()

    @Volatile
    private var lastHalfWidthMs = 30L

    @Volatile
    private var goodUrl: String? = null

    override val extraUncertaintyMs: Long
        get() = (lastHalfWidthMs + 8).coerceAtLeast(10)

    override fun fetch(): RawSync {
        if (!Net.online()) throw IOException("手机没有网络")

        val urls = buildList {
            goodUrl?.let { add(it) }
            Config.JD_PROBE_URLS.forEach { if (it != goodUrl) add(it) }
        }

        val (url, accepted) = probeBurst(
            urls,
            Config.JD_PROBE_SAMPLES,
            Config.JD_PROBE_GAP_MS,
            Config.JD_BURST_BUDGET_MS,
            intersector,
            mapOf("Referer" to "https://www.jd.com/")
        )
        if (url != null) goodUrl = url

        val est = intersector.estimate()
            ?: throw IOException("京东 Date 头样本不足（本轮有效 $accepted 次）")

        lastHalfWidthMs = est.halfWidthMs.coerceAtLeast(8)
        val mono = Mono.ms()
        return RawSync(
            serverUtcMsAtRecv = mono + est.offsetMs,
            monoMsAtRecv = mono,
            rttMs = intersector.lastMinRttMs.coerceAtLeast(1),
            strategy = "Date 秒边界交集 ${hostOf(url ?: "")}（${est.samples} 样本 · ±${est.halfWidthMs}ms）",
            preciseMs = true
        )
    }
}
