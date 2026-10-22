package com.yesha.timefloat.time

import android.graphics.Color
import com.yesha.timefloat.Config
import com.yesha.timefloat.util.Mono

/**
 * 一路时钟：把服务器时间映射到本地单调时钟上。
 *
 *     服务器时间 = 本地单调时钟 + 偏移量 + 漂移率 × 距锚点时间
 *
 * 好处：不依赖网络也能每毫秒推进；系统改墙钟、后台偷偷校时都不影响；
 * 两次校时之间顺便估晶振漂移（ppm），跑一两个小时依然准。
 *
 * ★ 正确性保护（"悬浮的时间一定是对的"是这么保证的）：
 *  1) 没有成功校时过 → 不给任何数字（界面显示 --:--:--.---），
 *     而不是退回本机墙钟 —— 本机墙钟可能快/慢半秒，拿来抢购就是害人。
 *  2) 连续两次校时之间，真实偏移量只可能有晶振漂移量级的变化。
 *     如果某轮结果和当前钟面差超过 JUMP_TOLERANCE_MS，先不采纳，
 *     等下一轮同方向确认（JUMP_CONFIRM_ROUNDS 次）才接受，避免单次坏样本把时间带偏。
 *     只有检测到单调钟倒退（设备重启）才无条件采纳。
 *  3) 界面上永远标着不确定度 ±Xms 和"距今多久"，有多可信一眼能看出来。
 */
class ServerClock(val source: TimeSource) {

    enum class State { IDLE, SYNCING, OK, FAIL }

    enum class ApplyResult { APPLIED, HELD_SUSPICIOUS }

    val id: String get() = source.id
    val label: String get() = source.label
    val accentColor: Int get() = colorOf(id)

    @Volatile var state: State = State.IDLE
        private set
    @Volatile var error: String = ""
        private set
    @Volatile var bestRttMs: Long = -1
        private set
    @Volatile var uncertaintyMs: Long = -1
        private set
    @Volatile var jitterMs: Long = 0
        private set
    @Volatile var usedSamples: Int = 0
        private set
    @Volatile var totalSamples: Int = 0
        private set
    @Volatile var strategy: String = ""
        private set
    @Volatile var preciseMs: Boolean = false
        private set
    @Volatile var syncCount: Int = 0
        private set
    @Volatile var lastTookMs: Long = 0
        private set
    @Volatile var syncingSinceMono: Long = 0
        private set

    /**
     * 最近一次「开始校时」的时刻（单调钟）。
     * 看门狗靠它判断调度链是不是断了：只要超过 SELF_HEAL_MS 都没开始过校时，
     * 就强行补一次 —— 保证"自动校时"永远不会彻底停掉。
     */
    @Volatile var lastAttemptMonoMs: Long = 0
        private set

    /**
     * 最近一次成功校对的时刻（单调钟）。
     * 由同步线程写、UI 线程读（ageMs/isStale）→ **必须 @Volatile**，
     * 否则刚校完界面可能还读到旧值，显示成"Xs前校准"偏大；32 位设备上 Long 还会撕裂读。
     */
    @Volatile
    private var lastOkMonoMs: Long = 0
    private var candidateOffset: Double = Double.NaN
    private var candidateHits = 0

    /** 手动微调（毫秒） */
    @Volatile var manualTrimMs: Long = 0

    @Volatile private var offsetMs: Double = 0.0
    @Volatile private var driftPpm: Double = 0.0
    @Volatile private var anchorMonoMs: Long = 0
    @Volatile private var synced = false

    val isSynced: Boolean get() = synced

    /** 当前服务器 UTC 毫秒；从未成功校时则返回 null（界面必须显示占位符，不能拿墙钟冒充） */
    fun utcMsOrNull(): Long? {
        if (!synced) return null
        val mono = Mono.ms()
        val off = offsetMs + driftPpm * (mono - anchorMonoMs) / 1_000_000.0
        return Math.round(mono + off) + manualTrimMs
    }

    /** 便利方法：未校时返回本地墙钟（仅用于内部判断，不要直接拿去显示） */
    fun nowUtcMs(): Long = utcMsOrNull() ?: System.currentTimeMillis()

    /**
     * 本机墙钟相对**这一路服务器时钟**的偏差（毫秒）。
     * 正数 = 本机比服务器快，负数 = 本机比服务器慢。
     *
     * 注意：一定要用"当前选中的那一路"来算。抢购时你关心的是自己和京东/淘宝服务器差多少，
     * 而不是自己和 NTP 差多少 —— 用北京时间去套所有源是错的。
     */
    fun localWallFastMs(): Long = System.currentTimeMillis() - nowUtcMs()

    fun ageMs(): Long =
        if (lastOkMonoMs == 0L) Long.MAX_VALUE else (Mono.ms() - lastOkMonoMs).coerceAtLeast(0)

    fun isStale(): Boolean = synced && ageMs() > Config.STALE_MS

    fun markSyncing() {
        state = State.SYNCING
        syncingSinceMono = Mono.ms()
        lastAttemptMonoMs = syncingSinceMono
    }

    fun apply(s: Sampler.Summary): ApplyResult {
        val mono = Mono.ms()

        // 连续性校验：单调钟倒退 = 设备重启，直接采纳；否则差太多就先不采纳
        if (synced && mono >= anchorMonoMs) {
            val diff = Math.abs(s.offsetMs - offsetMs)
            if (diff > Config.JUMP_TOLERANCE_MS) {
                if (candidateOffset.isNaN() || Math.abs(s.offsetMs - candidateOffset) > Config.JUMP_AGREE_MS) {
                    candidateOffset = s.offsetMs
                    candidateHits = 1
                } else {
                    candidateHits++
                }
                if (candidateHits < Config.JUMP_CONFIRM_ROUNDS) {
                    error = "本轮结果与当前钟面差 ${(s.offsetMs - offsetMs).toLong()}ms，已暂缓采纳（等下一轮确认）"
                    state = State.OK          // 继续用已经验证过的时间，绝不让坏样本带偏
                    strategy = s.strategy
                    return ApplyResult.HELD_SUSPICIOUS
                }
            }
        }
        candidateOffset = Double.NaN
        candidateHits = 0

        if (synced) {
            val dtMs = (mono - anchorMonoMs).toDouble()
            if (dtMs > 5_000) {
                val instantPpm = (s.offsetMs - offsetMs) / dtMs * 1_000_000.0
                driftPpm = driftPpm * 0.5 + instantPpm.coerceIn(-2000.0, 2000.0) * 0.5
            }
        }
        offsetMs = s.offsetMs
        anchorMonoMs = mono
        bestRttMs = s.bestRttMs
        uncertaintyMs = s.uncertaintyMs
        jitterMs = s.jitterMs
        usedSamples = s.usedSamples
        totalSamples = s.totalSamples
        strategy = s.strategy
        preciseMs = s.preciseMs
        lastTookMs = s.tookMs
        lastOkMonoMs = mono
        syncCount++
        error = ""
        syncingSinceMono = 0
        state = State.OK
        synced = true
        return ApplyResult.APPLIED
    }

    fun markFail(message: String) {
        error = message
        syncingSinceMono = 0
        state = if (synced) State.OK else State.FAIL
    }

    /** 状态点颜色：绿=新鲜，黄=偏旧/正在同步/上轮同步失败，红=从未成功 */
    fun statusColor(): Int = when {
        !synced -> if (state == State.SYNCING) Color.parseColor("#FFFFC107") else Color.parseColor("#FFFF453A")
        isStale() -> Color.parseColor("#FFFFC107")
        error.isNotBlank() -> Color.parseColor("#FFFFC107")
        else -> Color.parseColor("#FF34C759")
    }

    /** 悬浮窗小字：永远给出有用信息，不会只写"校时中" */
    fun metaText(): String {
        val age = ageMs()
        return when {
            !synced && state == State.SYNCING -> "首次校时中…"
            !synced && state == State.FAIL -> "校时失败：$error"
            !synced -> "等待校时"
            error.isNotBlank() -> "±${uncertaintyMs}ms · ${secText(age)}前 · 上轮同步失败，重试中"
            !preciseMs -> "±${uncertaintyMs}ms · ${secText(age)}前 · 秒精度"
            isStale() -> "±${uncertaintyMs}ms · 数据偏旧(${secText(age)}前)"
            else -> "±${uncertaintyMs}ms · ${secText(age)}前"
        }
    }

    /**
     * 主界面每路只显示这一行：**往返时间 + 多长时间前校准**。
     * （接口名、样本数、±不确定度这些技术细节不再往界面上堆，用户看不懂也没用）
     */
    fun briefLine(): String = when {
        !synced && state == State.SYNCING -> "正在校准…"
        !synced && state == State.FAIL -> "校准失败"
        !synced -> "等待校准"
        else -> "往返 ${bestRttMs}ms · ${secText(ageMs())}前校准"
    }

    /** 供界面判断这一路该用颜色（绿/黄/红），不需要额外文字 */
    fun healthLevel(): Int = when {
        !synced -> 2
        isStale() || error.isNotBlank() -> 1
        else -> 0
    }

    private fun secText(ms: Long): String = when {
        ms == Long.MAX_VALUE -> "从未"
        ms < 1000 -> "0s"
        ms < 60_000 -> "${ms / 1000}s"
        ms < 3_600_000 -> "${ms / 60_000}m${(ms % 60_000) / 1000}s"
        else -> "${ms / 3_600_000}h"
    }

    companion object {
        fun colorOf(id: String): Int = when (id) {
            "bj" -> Color.parseColor("#34C759")
            "taobao" -> Color.parseColor("#FF6A00")
            "jd" -> Color.parseColor("#E1251B")
            else -> Color.WHITE
        }

        fun displayName(id: String): String = when (id) {
            "bj" -> "北京"
            "taobao" -> "淘宝"
            "jd" -> "京东"
            else -> id
        }

        fun fullName(id: String): String = displayName(id) + "服务器时间"
    }
}
