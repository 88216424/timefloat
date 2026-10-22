package com.yesha.timefloat.time

import com.yesha.timefloat.Config
import com.yesha.timefloat.util.Mono
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
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

    /**
     * 看门狗用**独立**的单线程池。
     * 不能和同步任务共用一个池：网络半死时 3 路同步各要十几秒、队列里还有被作废的旧任务，
     * 6 个线程被占满后看门狗自己反而被排队延迟 —— 而它正是"自动校时永不永久停止"的唯一机制。
     */
    private val watchdogPool: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "timefloat-watchdog").apply { isDaemon = true }
    }

    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    private val busy = ConcurrentHashMap<String, Long>()

    /**
     * 每一路的「调度代次」。看门狗判定某路卡死、或用户点刷新时，就把代次 +1，
     * 于是那个还在跑的旧任务**作废**：
     *   · 它迟到返回时不写结果（不会被旧数据覆盖新数据）；
     *   · 它的 finally 也不会再排下一条链（否则卡死一次就分裂成两条链，越滚越多）。
     */
    private val generation = ConcurrentHashMap<String, Int>()

    @Volatile private var running = false
    @Volatile private var refCount = 0
    private var watchdogFuture: ScheduledFuture<*>? = null

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
        // 看门狗也停掉：Activity 退到后台又没开悬浮窗时，不该每 3 秒白醒一次
        watchdogFuture?.cancel(false)
        watchdogFuture = null
        // 注意：这里不能动时钟状态，否则再次打开会显示成"校时中"
    }

    private fun genOf(id: String): Int = generation[id] ?: 0

    /** merge 是原子的：bumpGen 会被 UI 线程（点刷新）和看门狗线程同时调用 */
    private fun bumpGen(id: String) {
        generation.merge(id, 1) { a, _ -> a + 1 }
    }

    fun refresh(id: String? = null) {
        if (id == null) clocks.forEach { scheduleSync(it, 0) }
        else clockOf(id)?.let { scheduleSync(it, 0) }
    }

    fun refreshAll() = refresh(null)

    /** 用户点「刷新」：作废在跑的旧任务 + 清掉并发标记，立刻重来 */
    fun forceRefresh() {
        clocks.forEach { bumpGen(it.id) }
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
        if (watchdogFuture != null) return
        watchdogFuture = watchdogPool.scheduleWithFixedDelay(
            {
                // ★ 必须包住异常：scheduleWithFixedDelay 一旦抛出就会**永久停止**后续调度，
                //   看门狗自己死了就等于"自动校时再也不恢复"。
                try {
                    watchdog()
                } catch (_: Throwable) {
                }
            },
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
                bumpGen(c.id)          // ★ 关键：作废那个卡住的任务，别让它回来再排一条链
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
        val myGen = genOf(clock.id)

        val task = Runnable {
            // ★ 被 bumpGen 作废、但早就排在队列里的任务（延迟最长 60 秒）：立刻退场。
            //   否则它会白跑一整轮网络请求，还会 markSyncing 把状态刷成"校时中"、
            //   把卡死判定的时间基准一起推后。
            if (myGen != genOf(clock.id)) {
                busy.remove(clock.id, stamp)
                return@Runnable
            }

            // 本轮是否被"暂缓采纳"（结果和当前钟面差太多，等下一轮确认）
            var held = false
            try {
                clock.markSyncing()
                notifyListeners()
                val summary = Sampler.run(clock.source)
                // 只有代次没变（没被看门狗判死、没被用户刷新顶掉）的任务才允许写结果
                if (myGen == genOf(clock.id)) {
                    held = clock.apply(summary) == ServerClock.ApplyResult.HELD_SUSPICIOUS
                }
            } catch (e: Exception) {
                if (myGen == genOf(clock.id)) {
                    clock.markFail(e.message ?: e.javaClass.simpleName)
                }
            } finally {
                busy.remove(clock.id, stamp)
                notifyListeners()
                // 迟到的旧任务不再排下一条链 —— 否则看门狗每判一次卡死，链就多一条
                if (running && myGen == genOf(clock.id)) {
                    val delay = when {
                        // 暂缓采纳时要尽快来第二轮做确认，别等 60 秒
                        held -> Config.RETRY_ON_FAIL_MS
                        clock.state == ServerClock.State.OK && clock.preciseMs -> Config.RESYNC_MS_PRECISE
                        clock.state == ServerClock.State.OK -> Config.RESYNC_MS_COARSE
                        else -> Config.RETRY_ON_FAIL_MS
                    }
                    scheduleSync(clock, delay)
                }
            }
        }
        pool.schedule(task, delayMs, TimeUnit.MILLISECONDS)
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
