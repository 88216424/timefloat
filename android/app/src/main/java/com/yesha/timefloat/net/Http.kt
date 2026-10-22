package com.yesha.timefloat.net

import com.yesha.timefloat.Config
import com.yesha.timefloat.util.Mono
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * 极简 HTTP 客户端（零第三方依赖）。
 *
 * 精度要点：
 *  1) monoAtRecvMs —— 读完响应体的那一瞬间的单调时钟，用它对齐服务器时间戳，
 *     不是等解析完再取时间（解析 280KB 页面要几十毫秒，那段时间全都会变成误差）。
 *  2) getStreaming —— 边读边匹配，命中即断。京东 serverTime 在文档 9% 处，
 *     读到命中处就断开，采样点大幅提前，顺带省流量。
 *  3) **硬预算**：readTimeout 只是"每次 read"的上限，一个页面被慢慢吐数据能拖几十秒。
 *     所以流式读取额外带 budgetMs，读满预算立刻放弃——这是界面不再卡"校时中"的关键。
 */
data class HttpResult(
    val status: Int,
    val body: String,
    val monoAtRecvMs: Long,
    val rttMs: Long,
    val dateHeaderUtcMs: Long,
    val bytes: Int
)

object Http {

    private val HTTP_DATE_FMT = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("GMT")
    }

    class HttpError(message: String) : IOException(message)

    /** 普通 GET：一次性读完（有硬上限） */
    fun get(
        url: String,
        timeoutMs: Int = Config.HTTP_TIMEOUT_MS,
        readTimeoutMs: Int = Config.HTTP_READ_TIMEOUT_MS,
        headers: Map<String, String> = emptyMap(),
        /**
         * ★ 响应体硬上限。readTimeout 只是"每次 read"的上限：服务器只要每 <2.5 秒吐一点数据，
         *   readText() 就能**无限读下去**（时间无界，不只是内存），而采样预算只在轮与轮之间判，
         *   拦不住一轮内部 —— 淘宝那路被风控返回大页面/慢速响应时能把一整轮拖死。
         *   校时实际只需要几十字节（淘宝的 t 字段），256KB 已经极其宽松。
         */
        maxBytes: Int = 256 * 1024
    ): HttpResult {
        val t0 = System.nanoTime()
        val conn = open(url, timeoutMs, readTimeoutMs, headers)
        try {
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val raw = stream?.use { readCapped(it, maxBytes) } ?: ByteArray(0)
            val body = String(raw, Charsets.UTF_8)
            val monoRecv = Mono.ms()
            val rtt = (System.nanoTime() - t0) / 1_000_000
            return HttpResult(
                status = code,
                body = body,
                monoAtRecvMs = monoRecv,
                rttMs = rtt,
                dateHeaderUtcMs = parseHttpDate(conn.getHeaderField("Date")),
                bytes = raw.size
            )
        } catch (e: SocketTimeoutException) {
            throw HttpError("请求超时（${timeoutMs}ms）")
        } finally {
            conn.disconnect()
        }
    }

    /** 有上限地读完流（超限立刻放弃），返回真实字节 */
    private fun readCapped(ins: java.io.InputStream, maxBytes: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(8192)
        val chunk = ByteArray(8192)
        var total = 0
        while (true) {
            val n = ins.read(chunk)
            if (n < 0) break
            total += n
            if (total > maxBytes) throw HttpError("响应体超过 ${maxBytes / 1024}KB，已放弃")
            out.write(chunk, 0, n)
        }
        return out.toByteArray()
    }

    data class StreamingResult(
        val status: Int,
        val value: String?,
        val monoAtMatchMs: Long,
        val rttMs: Long,
        val dateHeaderUtcMs: Long,
        val bytes: Int,
        /** 是否是因为预算耗尽而放弃的（用于给出更准确的错误提示） */
        val budgetExceeded: Boolean
    )

    /**
     * 流式 GET：边读边用正则找目标，命中即停。
     * @param pattern 目标正则，第一捕获组是要的数字
     * @param budgetMs 这次请求的总时间预算，超了立刻放弃（不抛异常，返回 value=null）
     */
    fun getStreaming(
        url: String,
        pattern: Regex,
        maxBytes: Int = 64 * 1024,
        budgetMs: Int = 3_000,
        connectTimeoutMs: Int = Config.HTTP_TIMEOUT_MS,
        readTimeoutMs: Int = Config.HTTP_READ_TIMEOUT_MS,
        headers: Map<String, String> = emptyMap()
    ): StreamingResult {
        val t0 = System.nanoTime()
        val conn = open(url, connectTimeoutMs, readTimeoutMs, headers)
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                return StreamingResult(
                    status = code, value = null, monoAtMatchMs = -1L,
                    rttMs = (System.nanoTime() - t0) / 1_000_000,
                    dateHeaderUtcMs = parseHttpDate(conn.getHeaderField("Date")),
                    bytes = 0, budgetExceeded = false
                )
            }
            val input = conn.inputStream
            val acc = StringBuilder(48 * 1024)
            val buf = ByteArray(8192)
            var hit: String? = null
            var totalRead = 0
            var overBudget = false

            while (totalRead < maxBytes) {
                if ((System.nanoTime() - t0) / 1_000_000 > budgetMs) {
                    overBudget = true
                    break
                }
                val n = try {
                    input.read(buf)
                } catch (e: SocketTimeoutException) {
                    overBudget = true
                    break
                }
                if (n <= 0) break
                acc.append(String(buf, 0, n, Charsets.UTF_8))
                totalRead += n
                val m = pattern.find(acc)
                if (m != null) {
                    hit = m.groupValues[1]
                    break
                }
            }

            val monoMatch = Mono.ms()
            return StreamingResult(
                status = code,
                value = hit,
                monoAtMatchMs = if (hit == null) -1L else monoMatch,
                rttMs = (System.nanoTime() - t0) / 1_000_000,
                dateHeaderUtcMs = parseHttpDate(conn.getHeaderField("Date")),
                bytes = totalRead,
                budgetExceeded = overBudget
            )
        } catch (e: SocketTimeoutException) {
            throw HttpError("请求超时")
        } finally {
            conn.disconnect()
        }
    }

    private fun open(
        url: String,
        connectTimeoutMs: Int,
        readTimeoutMs: Int,
        headers: Map<String, String>
    ): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = connectTimeoutMs
            readTimeout = readTimeoutMs
            instanceFollowRedirects = true
            requestMethod = "GET"
            setRequestProperty("User-Agent", Config.USER_AGENT)
            setRequestProperty("Accept-Language", "zh-CN,zh;q=0.9")
            // 不手动设 Accept-Encoding：让系统自己处理 gzip
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
        }

    private fun parseHttpDate(raw: String?): Long {
        if (raw.isNullOrBlank()) return -1L
        return try {
            synchronized(HTTP_DATE_FMT) { HTTP_DATE_FMT.parse(raw)?.time } ?: -1L
        } catch (_: Exception) {
            -1L
        }
    }
}
