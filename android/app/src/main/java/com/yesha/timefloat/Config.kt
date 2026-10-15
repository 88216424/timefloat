package com.yesha.timefloat

/**
 * 全局常量。取值原则（踩过坑）：
 *  ① 单个请求必须有硬预算 —— readTimeout 是「每次 read」计时，一个几百 KB 的页面被慢慢吐数据
 *     能拖几十秒，界面就一直卡在「校时中」。
 *  ② 每个源一轮采样的总预算也要设死，超了就用已有样本收工。
 *  ③ 时间源要选「响应体极小 + 标准头」的接口，别拿 SSR 大页面当钟用。
 */
object Config {

    // ---------- 淘宝服务器时间（毫秒精度，响应体几十字节） ----------
    val TAOBAO_URLS = listOf(
        "https://acs.m.taobao.com/gw/mtop.common.getTimestamp/",
        "https://acs.m.taobao.com/gw/mtop.common.getTimestamp/?_="
    )

    // ---------- 京东服务器时间 ----------
    /**
     * 实测结论（2026-10-15 反复验证）：
     *  · api.m.jd.com 的 queryServerTime / getServerTime 早就下线；
     *  · a.jd.com/ajax/queryServerData.html 变成 HTML 首页；
     *  · 商品页里那个 presellInfo.serverTime 字段**时有时无**（有预约活动时才有，
     *    页面从 284KB 缩到 3KB 时字段直接消失）—— 拿它当主源会导致时间一会差 700 一会差 400；
     *  · 唯一稳定存在的是标准 HTTP `Date` 响应头（京东自家 jfe/nginx 都会带）。
     * 所以京东这路改成：**Date 头 + 多次采样秒边界交集**（见 DateIntersector），
     * 把只有秒精度的 Date 夹逼到几十毫秒，实测 rtt 只有 26ms、交集宽度 64~80ms。
     */
    val JD_PROBE_URLS = listOf(
        "https://api.m.jd.com/",     // Server: jfe，响应几十字节，实测 rtt 26ms
        "https://www.jd.com/"        // Server: nginx，兜底
    )
    const val JD_PROBE_SAMPLES = 12      // 每轮采样次数（相位要铺满一整秒）
    const val JD_PROBE_GAP_MS = 45L

    // ---------- 北京时间（NTP，毫秒精度） ----------
    val SNTP_HOSTS = listOf(
        "ntp.aliyun.com",
        "ntp1.aliyun.com",
        "ntp2.aliyun.com",
        "cn.pool.ntp.org"
    )
    /** 很多蜂窝网封 UDP 123，试 2 台就该换 HTTP 兜底了 */
    const val SNTP_HOSTS_PER_SAMPLE = 2
    /** NTP 全线不通后，这段时间内直接走 HTTP 兜底，不再白等 */
    const val BJ_NTP_COOLDOWN_MS = 300_000L
    /** 兜底也用 Date 头交集，比单次读 Date 准得多 */
    val BJ_DATE_PROBE_URLS = listOf("https://www.baidu.com/", "https://www.qq.com/")
    const val BJ_DATE_PROBE_SAMPLES = 6

    // ---------- Date 头探针通用参数 ----------
    /** rtt 超过这个值的样本直接丢（太大说明排队了，也不利于收紧交集） */
    const val DATE_PROBE_MAX_RTT_MS = 300L
    /** 单次探针的超时：必须短，否则网络一卡整轮取样会被拖死 */
    const val DATE_PROBE_CONNECT_TIMEOUT_MS = 3_000
    const val DATE_PROBE_READ_TIMEOUT_MS = 2_500
    /** 一整轮取样的硬预算：到点就用手上的样本收工，绝不恋战 */
    const val JD_BURST_BUDGET_MS = 4_000L
    const val BJ_BURST_BUDGET_MS = 4_500L

    // ---------- 采样参数 ----------
    const val SAMPLES_PER_SYNC = 4
    const val SAMPLE_GAP_MS = 90L
    /** 单个源一轮采样的总时间预算，超了就拿已有样本收工 */
    const val SYNC_BUDGET_MS = 12_000L
    const val MIN_RTT_WINDOW_RATIO = 0.4
    const val OUTLIER_MS = 40.0

    // ---------- 正确性保护 ----------
    const val JUMP_TOLERANCE_MS = 1_000.0
    const val JUMP_AGREE_MS = 300.0
    const val JUMP_CONFIRM_ROUNDS = 2
    const val CROSS_WARN_MS = 200L
    const val CROSS_OK_MS = 50L
    const val STALE_MS = 150_000L

    // ---------- 自动重校周期 ----------
    const val RESYNC_MS_PRECISE = 60_000L
    const val RESYNC_MS_COARSE = 90_000L
    const val RETRY_ON_FAIL_MS = 6_000L
    const val WATCHDOG_MS = 3_000L
    const val STUCK_MS = 18_000L
    /**
     * 调度自愈阈值：某一路超过这么久连"开始校时"都没有过，
     * 就认为调度链断了（不管什么原因），看门狗强行补一次。
     * 这是"不会自动校时"这类问题的兜底保险。
     */
    const val SELF_HEAL_MS = 90_000L

    // ---------- 刷新节奏 ----------
    /** 显示毫秒时：33ms ≈ 30fps，毫秒位跳动不会看出停顿 */
    const val UI_TICK_MS = 33L
    /** 不显示毫秒时没必要 30fps，降到 4fps 省电 */
    const val UI_TICK_MS_SLOW = 250L
    /** 主界面里"互差/采样细节"这类慢信息每 500ms 刷一次就够了 */
    const val UI_SLOW_EVERY_TICKS = 15

    // ---------- 网络 ----------
    const val HTTP_TIMEOUT_MS = 5_000
    const val HTTP_READ_TIMEOUT_MS = 2_500
    const val SNTP_TIMEOUT_MS = 2_000
    const val USER_AGENT =
        "Mozilla/5.0 (Linux; Android 13; SM-S9010) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/120.0.0.0 Mobile Safari/537.36"

    // ---------- 通知 ----------
    const val CHANNEL_ID = "timefloat"
    const val NOTIF_ID = 0x5A5A

    // ---------- SharedPreferences ----------
    const val PREFS = "timefloat_prefs"
    const val K_ALPHA = "alpha"
    const val K_TEXT_SCALE = "text_scale"
    const val K_LOCK = "lock"
    const val K_SHOW_MS = "show_ms"
    const val K_POS_X = "pos_x"
    const val K_POS_Y = "pos_y"
    /** 悬浮窗显示哪一路（三选一，启动前在主界面选好）：bj / taobao / jd */
    const val K_FLOAT_SRC = "float_src"
    const val K_REV = "rev"
}
