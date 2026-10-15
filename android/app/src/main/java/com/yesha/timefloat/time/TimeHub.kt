package com.yesha.timefloat.time

import com.yesha.timefloat.Config
import com.yesha.timefloat.util.Mono
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * 三路时钟的总调度：校时周期、并发控制、看门狗、界面刷新回调。
 * 全局单例，Activity 与悬浮窗 Service 共用同一份数据（两边显示永远一致）。
 *
 * 修过的坑：
 *  · 看门狗：任何一路卡在 SYNCING 超过 STUCK_MS 就判失败并重排，
 *    从机制上保证"校时中"不可能永久停留。
 *  · busy 标记带时间戳 + CAS 移除，避免旧任务误删新任务的标记。
 *  · stop() 不再把状态改成 SYNCING（那是"关了再开永远校时中"的元凶）。
 */
class TimeHub private constructor() {

    val clocks: List<ServerClock> = listOf(
        ServerClock(BeijingSource()),
        ServerClock(TaobaoSource()),
        ServerClock(JdSource())
    )

    val beijing: ServerClock get() = clocks[0]
    val taobao: ServerClock get() = clocks[1]
    val jd: ServerClock get() = clocks[2]

    /** 悬浮窗显示哪一路（在主界面启动悬浮窗之前选好） */
    @Volatile
    var selectedId: String = "taobao"

    fun selected(): ServerClock = clocks.firstOrNull { it.id == selectedId } ?: taobao

    fun clockOf(id: String): ServerClock? = clocks.firstOrNull { it.id == id }

    /** 三源交叉校验结果：用来判断"这个时间到底可不可信" */
    data class CrossCheck(val spreadMs: Long, val level: Int, val text: String) {
        val ok: Boolean get() = level == 0
    }

    private val pool: ScheduledExecutorService = Executors.newScheduledThreadPool(6) { r ->
        Thread(r, "timefloat-sync").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY + 1
        }
    }

    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    private val busy = ConcurrentHashMap<String, Long>()

    @Volatile private var running = false
    @Volatile private var refCount = 0
    @Volatile private var watchdogRunning = false

    fun acquire() {
        refCount++
        if (!running) start()
    }

    fun release() {
        refCount = (refCount - 1).coerceAtLeast(0)
        if (refCount == 0) stop()
    }

    fun addListener(l: () -> Unit) = listeners.addIfAbsent(l)

    fun removeListener(l: () -> Unit) = listeners.remove(l)

    private fun start() {
        running = true
        ensureWatchdog()
        refreshAll()
    }

    private fun stop() {
        running = false
        // 注意：这里不能动时钟状态，否则再次打开会显示成"校时中"
    }

    fun refresh(id: String? = null) {
        if (id == null) clocks.forEach { scheduleSync(it, 0) }
        else clockOf(id)?.let { scheduleSync(it, 0) }
    }

    fun refreshAll() = refresh(null)

    /** 用户点「刷新」：清掉并发标记立刻重来 */
    fun forceRefresh() {
        busy.clear()
        clocks.forEach { it.markSyncing() }
        notifyListeners()
        clocks.forEach { scheduleSync(it, 0) }
    }

    /**
     * 三源交叉校验：都校过之后互相差多少毫秒。
     * level: -1 = 可用源不足 / 0 = 一致 / 1 = 略有差异 / 2 = 差异偏大
     */
    fun crossCheck(): CrossCheck {
        val live = clocks.mapNotNull { it.utcMsOrNull() }
        if (live.size < 2) {
            return CrossCheck(-1, -1, "可用源不足，等待校时")
        }
        val spread = live.max() - live.min()
        val level = when {
            spread <= Config.CROSS_OK_MS -> 0
            spread <= Config.CROSS_WARN_MS -> 1
            else -> 2
        }
        return CrossCheck(spread, level, "三源互差 ${spread}ms")
    }

    private fun ensureWatchdog() {
        if (watchdogRunning) return
        watchdogRunning = true
        pool.scheduleWithFixedDelay(
            { watchdog() },
            Config.WATCHDOG_MS,
            Config.WATCHDOG_MS,
            TimeUnit.MILLISECONDS
        )
    }

    /**
     * 看门狗干两件事：
     *  1) **卡死处理**：某一路开始校时后超过 STUCK_MS 还没结束 → 判失败 + 重排；
     *  2) **调度自愈**：某一路超过 SELF_HEAL_MS 连"开始校时"都没有过 → 说明重新排下一轮
     *     的那条链断了（任何原因），强行补一次。
     * 第 2 条就是"不会自动校时"这类问题的兜底保险：最坏 90 秒内一定恢复。
     */
    private fun watchdog() {
        val now = Mono.ms()
        for (c in clocks) {
            // 1) 卡死
            val since = c.syncingSinceMono
            if (since > 0 && now - since > Config.STUCK_MS) {
                c.markFail("校时超时（超过 ${Config.STUCK_MS / 1000} 秒），已自动重排")
                busy.remove(c.id)
                if (running) scheduleSync(c, Config.RETRY_ON_FAIL_MS)
                continue
            }

            // 清理过期 busy 标记（任务卡死或异常退出时留下的）
            val started = busy[c.id]
            if (started != null && now - started > Config.STUCK_MS * 2) {
                busy.remove(c.id, started)
            }

            // 2) 调度自愈
            if (running && busy[c.id] == null) {
                val lastAttempt = c.lastAttemptMonoMs
                if (lastAttempt == 0L || now - lastAttempt > Config.SELF_HEAL_MS) {
                    scheduleSync(c, 0)
                }
            }
        }
    }

    private fun scheduleSync(clock: ServerClock, delayMs: Long) {
        val stamp = Mono.ms()
        if (busy.putIfAbsent(clock.id, stamp) != null) return

        pool.schedule({
            try {
                clock.markSyncing()
                notifyListeners()
                val summary = Sampler.run(clock.source)
                clock.apply(summary)
            } catch (e: Exception) {
                clock.markFail(e.message ?: e.javaClass.simpleName)
            } finally {
                busy.remove(clock.id, stamp)
                notifyListeners()
                if (running) {
                    val delay = when {
                        clock.state == ServerClock.State.OK && clock.preciseMs -> Config.RESYNC_MS_PRECISE
                        clock.state == ServerClock.State.OK -> Config.RESYNC_MS_COARSE
                        else -> Config.RETRY_ON_FAIL_MS
                    }
                    scheduleSync(clock, delay)
                }
            }
        }, delayMs, TimeUnit.MILLISECONDS)
    }

    private fun notifyListeners() {
        for (l in listeners) {
            try {
                l()
            } catch (_: Throwable) {
            }
        }
    }

    companion object {
        val instance: TimeHub by lazy { TimeHub() }
    }
}
