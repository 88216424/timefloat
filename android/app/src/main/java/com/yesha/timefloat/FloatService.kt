package com.yesha.timefloat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import com.yesha.timefloat.net.Net
import com.yesha.timefloat.time.ServerClock
import com.yesha.timefloat.time.TimeHub
import com.yesha.timefloat.util.Fmt
import kotlin.math.abs

/**
 * 悬浮窗服务：**只显示一路时间**（北京 / 淘宝 / 京东 三选一）。
 *
 * 选哪一路是在主界面启动悬浮窗之前点好的，窗口起来之后不再提供切换，
 * 免得抢购时手滑点到别的源上。
 *
 * "时间一定是对的"是这么落地的：
 *  · 该源没有成功校时过 → 大字位显示 --:--:--.---（而不是拿本机墙钟冒充，
 *    本机墙钟实测可能快 600 多毫秒，拿来抢购就是害人）；
 *  · 每轮校时都做连续性校验，单次坏样本不会把钟面带偏（见 ServerClock.apply）；
 *  · 界面上常驻显示 ±不确定度 和 "距今多久"，并用状态点颜色区分可信度；
 *  · 三源互差超过阈值会在小字行里直接报警。
 */
class FloatService : Service() {

    private lateinit var wm: WindowManager
    private lateinit var prefs: SharedPreferences
    private var root: View? = null
    private var params: WindowManager.LayoutParams? = null
    private val handler = Handler(Looper.getMainLooper())
    private var acquired = false

    private var statusDot: View? = null
    private var tvSourceName: TextView? = null
    private var tvBigTime: TextView? = null

    private var dotDrawable: GradientDrawable? = null

    private var downRawX = 0f
    private var downRawY = 0f
    private var startX = 0
    private var startY = 0
    private var moved = false

    private var rev = -1
    private var alphaPct = 94
    private var textScale = 100
    private var locked = false
    private var showMs = true
    private var srcId = "taobao"

    private val ticker = object : Runnable {
        override fun run() {
            render()
            // 不显示毫秒时没必要 30fps 空转刷新（省电），降到 4fps 足够
            handler.postDelayed(this, if (showMs) Config.UI_TICK_MS else Config.UI_TICK_MS_SLOW)
        }
    }

    /** 渲染缓存：值没变就不碰控件，避免每帧都触发 measure/layout */
    private var lastSourceText: String? = null
    private var lastTimeText: String? = null
    private var lastTimeColor = Int.MIN_VALUE
    private var lastDotColor = Int.MIN_VALUE

    override fun onCreate() {
        super.onCreate()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        prefs = getSharedPreferences(Config.PREFS, Context.MODE_PRIVATE)
        Net.init(this)
        createChannel()
        startForegroundCompat(buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        alive = true
        startForegroundCompat(buildNotification())
        // ★ 不能在这里提前 return：那会跳过 applyPrefs/attachView/acquire/ticker，
        //   万一视图还没建好（比如上次因无悬浮窗权限 stopSelf 了），服务就会停在
        //   "通知在、没有悬浮窗、自动校时也没开"的僵尸态。下面这段初始化本身是幂等的。
        if (intent?.action == ACTION_SYNC) {
            TimeHub.instance.forceRefresh()
        }
        applyPrefs(force = true)
        if (root == null) attachView()
        if (!acquired) {
            TimeHub.instance.acquire()
            acquired = true
        }
        handler.removeCallbacks(ticker)
        handler.post(ticker)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        alive = false
        handler.removeCallbacks(ticker)
        detachView()
        if (acquired) {
            TimeHub.instance.release()
            acquired = false
        }
        super.onDestroy()
    }

    // ------------------------------------------------------------------ 视图

    private fun attachView() {
        if (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(this)) {
            stopSelf()
            return
        }
        val view = LayoutInflater.from(this).inflate(R.layout.float_clock, null)
        root = view

        statusDot = view.findViewById(R.id.statusDot)
        tvSourceName = view.findViewById(R.id.tvSourceName)
        tvBigTime = view.findViewById(R.id.tvBigTime)

        dotDrawable = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(COLOR_WARN)
        }
        statusDot?.background = dotDrawable
        // 视图是新的，渲染缓存作废
        lastSourceText = null
        lastTimeText = null
        lastTimeColor = Int.MIN_VALUE
        lastDotColor = Int.MIN_VALUE

        view.findViewById<TextView>(R.id.btnSync).setOnClickListener {
            TimeHub.instance.forceRefresh()
            vibrate(28)
        }
        view.findViewById<TextView>(R.id.btnClose).setOnClickListener { stopSelf() }

        view.setOnTouchListener { _, e -> onCardTouch(e) }

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            android.graphics.PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = prefs.getInt(Config.K_POS_X, 20)
            y = prefs.getInt(Config.K_POS_Y, 220)
        }
        params = lp

        try {
            wm.addView(view, lp)
        } catch (_: Throwable) {
            root = null
            stopSelf()
            return
        }
        applyPrefs(force = true)
    }

    private fun detachView() {
        val v = root ?: return
        try {
            wm.removeView(v)
        } catch (_: Throwable) {
        }
        root = null
        params = null
    }

    private fun onCardTouch(e: MotionEvent): Boolean {
        val lp = params ?: return false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downRawX = e.rawX
                downRawY = e.rawY
                startX = lp.x
                startY = lp.y
                moved = false
                handler.postDelayed(longPress, 700)
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                handler.removeCallbacks(longPress)
                if (locked) return true
                val dx = (e.rawX - downRawX).toInt()
                val dy = (e.rawY - downRawY).toInt()
                if (abs(dx) > 8 || abs(dy) > 8) moved = true
                if (moved) {
                    lp.x = startX + dx
                    lp.y = startY + dy
                    root?.let { wm.updateViewLayout(it, lp) }
                }
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(longPress)
                if (moved) clampAndSave(lp)
                return true
            }
        }
        return false
    }

    private val longPress = Runnable {
        if (!moved) {
            TimeHub.instance.forceRefresh()
            vibrate(28)
        }
    }

    private fun clampAndSave(lp: WindowManager.LayoutParams) {
        val v = root ?: return
        val dm = resources.displayMetrics
        val w = if (v.width > 0) v.width else v.measuredWidth
        val h = if (v.height > 0) v.height else v.measuredHeight
        lp.x = lp.x.coerceIn(-w / 3, (dm.widthPixels - w * 2 / 3).coerceAtLeast(0))
        lp.y = lp.y.coerceIn(0, (dm.heightPixels - h).coerceAtLeast(0))
        root?.let { wm.updateViewLayout(it, lp) }
        prefs.edit().putInt(Config.K_POS_X, lp.x).putInt(Config.K_POS_Y, lp.y).apply()
    }

    // ------------------------------------------------------------------ 设置热加载

    private fun applyPrefs(force: Boolean = false) {
        val cur = prefs.getInt(Config.K_REV, 0)
        if (!force && cur == rev) return
        rev = cur
        alphaPct = prefs.getInt(Config.K_ALPHA, 94)
        textScale = prefs.getInt(Config.K_TEXT_SCALE, 100)
        locked = prefs.getBoolean(Config.K_LOCK, false)
        showMs = prefs.getBoolean(Config.K_SHOW_MS, true)
        srcId = prefs.getString(Config.K_FLOAT_SRC, TimeHub.instance.selectedId) ?: "taobao"
        TimeHub.instance.selectedId = srcId

        params?.alpha = (alphaPct.coerceIn(20, 100) / 100f)
        root?.let { params?.let { lp -> wm.updateViewLayout(it, lp) } }

        val s = textScale.coerceIn(60, 200) / 100f
        // 用 dp 而不是 sp：sp 会跟着系统字体大小一起放大，
        // 用户把系统字体调大之后 12 位毫秒时间会撑出屏幕被裁掉，"毫秒就看不见了"
        tvSourceName?.setTextSize(android.util.TypedValue.COMPLEX_UNIT_DIP, 13f * s)
        applyBigTimeSize()
    }

    /**
     * 大字时间自适应：
     *  1) 基准字号按 dp 算，不吃系统字体缩放；
     *  2) 若按基准字号排下来会超出屏幕可用宽度，就等比缩小到刚好放下 ——
     *     保证"18:11:58.312"这 12 个字符永远完整显示，毫秒位不会被裁掉。
     */
    private fun applyBigTimeSize() {
        val tv = tvBigTime ?: return
        val dm = resources.displayMetrics
        val scale = textScale.coerceIn(60, 200) / 100f
        val basePx = BIG_TIME_BASE_DP * scale * dm.density

        tv.paint.textSize = basePx
        val worstWidth = tv.paint.measureText(WORST_TIME_TEXT)
        val avail = dm.widthPixels * 0.94f - dpF(52f)     // 卡片左右 padding + 余量
        val finalPx = if (worstWidth > avail && worstWidth > 0f) basePx * avail / worstWidth else basePx
        tv.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, finalPx)
    }

    private fun dpF(v: Float): Float = v * resources.displayMetrics.density

    // ------------------------------------------------------------------ 渲染

    private fun render() {
        if (root == null) return
        val hub = TimeHub.instance
        applyPrefs()
        val clock = hub.selected()

        // 下面每一处都做了"值没变就不碰控件"的判断：
        // TextView.setText/setTextColor 都会触发 requestLayout，30fps 下白白跑一遍测量布局是要命的
        val name = ServerClock.fullName(clock.id)
        if (lastSourceText != name) {
            tvSourceName?.text = name
            lastSourceText = name
        }

        val t = clock.utcMsOrNull()
        val text = when {
            t == null -> PLACEHOLDER_TIME
            showMs -> Fmt.hms(t)
            // 补足到 12 个字符宽度，避免关掉毫秒后卡片宽度跳动
            else -> Fmt.hms8(t) + "    "
        }
        if (lastTimeText != text) {
            tvBigTime?.text = text
            lastTimeText = text
        }

        val color = if (t == null) COLOR_WARN else Color.WHITE
        if (lastTimeColor != color) {
            tvBigTime?.setTextColor(color)
            lastTimeColor = color
        }

        val dot = clock.statusColor()
        if (lastDotColor != dot) {
            dotDrawable?.setColor(dot)
            lastDotColor = dot
        }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // 横竖屏切换 / 分屏变化：字号要按新屏宽重算，位置也要保证还在屏幕内
        applyPrefs(force = true)
        // ★ 必须 post 到下一帧再夹。此刻视图的 width/height 还是转屏前的旧值，
        //   直接算会把错误坐标写回 prefs，导致悬浮窗跑到屏幕外。
        root?.post { params?.let { clampAndSave(it) } }
    }

    private fun vibrate(ms: Long) {
        try {
            val v = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION") v.vibrate(ms)
            }
        } catch (_: Throwable) {
        }
    }

    // ------------------------------------------------------------------ 通知

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(Config.CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    Config.CHANNEL_ID,
                    getString(R.string.notice_channel),
                    NotificationManager.IMPORTANCE_LOW
                )
                ch.setShowBadge(false)
                ch.enableVibration(false)
                nm.createNotificationChannel(ch)
            }
        }
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val sync = PendingIntent.getService(
            this, 2, Intent(this, FloatService::class.java).setAction(ACTION_SYNC),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, Config.CHANNEL_ID)
        else
            @Suppress("DEPRECATION") Notification.Builder(this)

        builder.setSmallIcon(R.drawable.ic_stat_clock)
            .setContentTitle(getString(R.string.notice_title))
            .setContentText(getString(R.string.notice_text))
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, getString(R.string.btn_refresh), sync).build())
        return builder.build()
    }

    private fun startForegroundCompat(n: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(Config.NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(Config.NOTIF_ID, n)
        }
    }

    companion object {
        const val ACTION_SYNC = "com.yesha.timefloat.SYNC"

        /** 大字时间基准字号（dp，不吃系统字体缩放） */
        private const val BIG_TIME_BASE_DP = 44f

        /** 用来量最坏宽度：12 位毫秒时间 */
        private const val WORST_TIME_TEXT = "00:00:00.000"

        /** 没校上时的占位符（同样 12 个字符宽） */
        private const val PLACEHOLDER_TIME = "--:--:--.---"

        /** 警示黄 */
        private val COLOR_WARN = 0xFFFFC107.toInt()

        @Volatile
        private var alive = false

        fun isRunning(ctx: Context): Boolean = alive

        fun hasOverlayPermission(ctx: Context): Boolean =
            Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(ctx)

        fun start(ctx: Context) {
            val intent = Intent(ctx, FloatService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(intent)
            else ctx.startService(intent)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, FloatService::class.java))
        }
    }
}
