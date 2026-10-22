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

/**
 * 换了 Date 探针主机时该做什么。
 *
 * 为什么必须有这个：交集器的数学前提是"所有约束来自同一个时钟"。
 * 京东有两台（api.m.jd.com 走 jfe / www.jd.com 走 nginx），北京兜底也有两台，
 * 不同边缘机的钟差几十毫秒很正常 —— 把两家的约束混着求交，会夹出一个
 * "区间更紧、但带系统偏差"的值，而 1000ms 的 jump guard 根本抓不到几十毫秒级偏差。
 *
 * 所以：一旦发现本轮样本来自和上一轮不同的主机，就把这一轮判作废
 * （清空交集器 + 抛异常触发 6 秒后重试），下一轮从新主机干净地重新累积。
 *
 * @return 非 null = 应该抛出的异常消息
 */
private fun checkHostSwitch(nowUrl: String?, lastUrl: String?): String? {
    if (nowUrl == null || lastUrl == null || nowUrl == lastUrl) return null
    return "Date 主机切换（${hostOf(lastUrl)} → ${hostOf(nowUrl)}），本轮作废，下一轮重新累积"
}

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
/** 一轮探针的结果：用了哪台主机、本轮真正入库多少样本、**本轮**的最小 rtt */
private data class BurstResult(val url: String?, val accepted: Int, val minRttMs: Long)

private fun probeBurst(
    urls: List<String>,
    samplesPerUrl: Int,
    gapMs: Long,
    budgetMs: Long,
    intersector: DateIntersector,
    extraHeaders: Map<String, String> = emptyMap()
): BurstResult {
    val deadline = Mono.ms() + budgetMs
    var accepted = 0
    var minRtt = -1L
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
                    // 记录**本轮**最小 rtt：界面上那个"往返 Nms"必须反映当前网络，
                    // 而不是交集器里存了十分钟的历史最小值（那会显得比实际更乐观）
                    if (minRtt < 0 || s.rttMs < minRtt) minRtt = s.rttMs
                }
            } catch (_: Exception) {
            }
            try {
                Thread.sleep(gapMs)
            } catch (_: InterruptedException) {
            }
        }
        if (ok > 0) {
            // ★ 一轮只用一台主机。以前这里是"交集器已经有 6 条以上约束才 break"，
            //   于是前几轮会继续去探第二台主机 —— 而京东/北京的两台主机在不同边缘、
            //   钟能差几十毫秒，混进同一个交集器就会夹出"更紧但带系统偏差"的值。
            if (goodUrl == null) goodUrl = url
            break
        }
        if (outOfTime) break
    }
    return BurstResult(goodUrl, accepted, minRtt)
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

    /** 上一轮实际用的探针 URL：用来检测"换了主机"，换了就要清空交集器 */
    @Volatile
    private var lastProbeUrl: String? = null

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
        val burst = probeBurst(
            Config.BJ_DATE_PROBE_URLS,
            Config.BJ_DATE_PROBE_SAMPLES,
            Config.JD_PROBE_GAP_MS,
            Config.BJ_BURST_BUDGET_MS,
            intersector,
            // 百度/腾讯首页是几百 KB：加 Range 只取首字节，Date 头照样在，流量省掉 99%
            mapOf("Range" to "bytes=0-0")
        )
        // ★ 关键：本轮**一条新样本都没拿到**时，绝不能用交集器里上一轮留下的旧约束
        //   糊弄出一个"刚校准"的结果 —— 旧约束照样能算出 estimate，
        //   界面会显示绿色的"往返 26ms · 0s前校准"，而那个偏移可能早就过时了，
        //   而且 isStale() 永远不会触发（这是"时间一定准"的最后一道兜底）。
        if (burst.accepted == 0) throw IOException("NTP 不通，本轮 HTTP Date 兜底 0 个有效样本")
        checkHostSwitch(burst.url, lastProbeUrl)?.let {
            // ★ 必须真的清空：交集器里已经混了上一台主机的约束，
            //   不清掉的话"本轮作废"只是白说，下一轮照样拿两家的约束求交
            intersector.reset()
            lastProbeUrl = burst.url
            throw IOException(it)
        }
        if (burst.url != null) lastProbeUrl = burst.url
        val est = intersector.estimate()
            ?: throw IOException("NTP 不通，HTTP Date 兜底样本不足（本轮有效 ${burst.accepted} 次）")
        lastModeDateOnly = true
        lastHalfWidthMs = est.halfWidthMs.coerceAtLeast(8)
        val mono = Mono.ms()
        return RawSync(
            serverUtcMsAtRecv = mono + est.offsetMs,
            monoMsAtRecv = mono,
            rttMs = burst.minRttMs.coerceAtLeast(1),
            strategy = "HTTP Date 秒边界交集 ${hostOf(burst.url ?: "")}（${est.samples} 样本 · ±${est.halfWidthMs}ms）",
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

    /** 上一轮实际用的探针 URL：用来检测"换了主机"，换了就要清空交集器 */
    @Volatile
    private var lastProbeUrl: String? = null

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

        val burst = probeBurst(
            urls,
            Config.JD_PROBE_SAMPLES,
            Config.JD_PROBE_GAP_MS,
            Config.JD_BURST_BUDGET_MS,
            intersector,
            mapOf("Referer" to "https://www.jd.com/")
        )
        // ★ 本轮零新样本时不许用旧约束冒充"刚校准"（同北京兜底那条注释）
        if (burst.accepted == 0) throw IOException("京东本轮 0 个有效 Date 样本")
        checkHostSwitch(burst.url, lastProbeUrl)?.let {
            // ★ 同北京兜底：换了主机（jfe → nginx）就把交集器清空，别拿两家的约束混着求交
            intersector.reset()
            lastProbeUrl = burst.url
            throw IOException(it)
        }
        if (burst.url != null) { goodUrl = burst.url; lastProbeUrl = burst.url }

        val est = intersector.estimate()
            ?: throw IOException("京东 Date 头样本不足（本轮有效 ${burst.accepted} 次）")

        lastHalfWidthMs = est.halfWidthMs.coerceAtLeast(8)
        val mono = Mono.ms()
        return RawSync(
            serverUtcMsAtRecv = mono + est.offsetMs,
            monoMsAtRecv = mono,
            rttMs = burst.minRttMs.coerceAtLeast(1),
            strategy = "Date 秒边界交集 ${hostOf(burst.url ?: "")}（${est.samples} 样本 · ±${est.halfWidthMs}ms）",
            preciseMs = true
        )
    }
}
