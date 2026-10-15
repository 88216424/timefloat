package com.yesha.timefloat.util

import java.util.Locale

/**
 * 时间格式化。全部手写整数运算：
 *  - 不用 SimpleDateFormat（有线程安全问题，而且每 33ms 调一次开销大）
 *  - 结果固定宽度，抢购时数字跳动不会左右抖
 */
object Fmt {

    const val TZ_BEIJING_OFFSET_MS = 8L * 3600_000L
    private const val DAY_MS = 86_400_000L
    private val WEEK = arrayOf("周日", "周一", "周二", "周三", "周四", "周五", "周六")

    /** UTC 毫秒 -> 北京时间 HH:mm:ss.SSS */
    fun hms(utcMs: Long): String {
        var ms = utcMs + TZ_BEIJING_OFFSET_MS
        ms = ((ms % DAY_MS) + DAY_MS) % DAY_MS
        val h = ms / 3_600_000L
        val mi = (ms % 3_600_000L) / 60_000L
        val s = (ms % 60_000L) / 1000L
        val f = ms % 1000L
        return String.format(Locale.US, "%02d:%02d:%02d.%03d", h, mi, s, f)
    }

    /** 只要到秒 */
    fun hms8(utcMs: Long): String = hms(utcMs).substring(0, 8)

    /** 北京时间 MM-dd 周X */
    fun dateCn(utcMs: Long): String {
        val days = Math.floorDiv(utcMs + TZ_BEIJING_OFFSET_MS, DAY_MS)
        val dow = ((days + 4) % 7 + 7) % 7          // 1970-01-01 是周四
        val (_, m, d) = ymd(days)
        return String.format(Locale.US, "%02d-%02d %s", m, d, WEEK[dow.toInt()])
    }

    /** 偏差显示，带正负号 */
    fun delta(ms: Long): String = if (ms >= 0) String.format(Locale.US, "+%d", ms) else ms.toString()

    /** 民用历法换算：把"1970 起的天数"还原成 年/月/日 */
    private fun ymd(daysSinceEpoch: Long): Triple<Int, Int, Int> {
        val z = daysSinceEpoch + 719468
        val era = (if (z >= 0) z else z - 146096) / 146097
        val doe = z - era * 146097
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        val y = yoe + era * 400
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = doy - (153 * mp + 2) / 5 + 1
        val m = if (mp < 10) mp + 3 else mp - 9
        return Triple((if (m <= 2) y + 1 else y).toInt(), m.toInt(), d.toInt())
    }
}
