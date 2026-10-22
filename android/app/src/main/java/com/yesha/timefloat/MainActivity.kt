package com.yesha.timefloat

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.View
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import com.yesha.timefloat.net.Net
import com.yesha.timefloat.time.ServerClock
import com.yesha.timefloat.time.TimeHub
import com.yesha.timefloat.util.Fmt
import kotlin.math.abs

/**
 * 主界面：看三路时间、**在启动悬浮窗之前**选好悬浮窗要显示哪一路，然后启动悬浮窗。
 * 悬浮窗起来之后不再提供切换入口，避免抢购时手滑点错源。
 */
class MainActivity : Activity() {

    private lateinit var prefs: SharedPreferences
    private val handler = Handler(Looper.getMainLooper())

    private lateinit var tvSkew: TextView
    private lateinit var tvCross: TextView
    private lateinit var tvDetail: TextView
    private lateinit var tvFloatSrc: TextView
    private lateinit var tvOverlayState: TextView

    private lateinit var rowBj: View
    private lateinit var rowTaobao: View
    private lateinit var rowJd: View
    private lateinit var tvTimeBj: TextView
    private lateinit var tvTimeTaobao: TextView
    private lateinit var tvTimeJd: TextView
    private lateinit var tvDeltaBj: TextView
    private lateinit var tvDeltaTaobao: TextView
    private lateinit var tvDeltaJd: TextView

    private lateinit var tvAlpha: TextView
    private lateinit var tvScale: TextView
    private lateinit var sbAlpha: SeekBar
    private lateinit var sbScale: SeekBar
    private lateinit var swMs: Switch
    private lateinit var swLock: Switch

    private val dotDrawables = HashMap<String, GradientDrawable>()
    private var attached = false

    // ---- 渲染缓存：值没变就不碰控件（TextView 每次 setText/setTextColor 都会触发 measure/layout）----
    private var tickCount = 0
    private var lastSkewText: String? = null
    private var lastSkewColor = Int.MIN_VALUE
    private var lastFloatSrcText: String? = null
    private var lastFloatSrcColor = Int.MIN_VALUE
    private var lastHighlightId: String? = null
    private val lastDotColorById = HashMap<String, Int>()
    private val lastDeltaColorById = HashMap<String, Int>()
    private val lastTimeAlphaById = HashMap<String, Float>()

    private val ticker = object : Runnable {
        override fun run() {
            tickCount++
            renderFast()
            // 互差 / 采样细节这类慢信息，每 500ms 刷一次足够，别跟着 30fps 一起刷
            if (tickCount % Config.UI_SLOW_EVERY_TICKS == 0) renderSlow()
            handler.postDelayed(this, Config.UI_TICK_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = getSharedPreferences(Config.PREFS, Context.MODE_PRIVATE)
        Net.init(this)

        tvSkew = findViewById(R.id.tvLocalSkewMain)
        tvCross = findViewById(R.id.tvCross)
        tvDetail = findViewById(R.id.tvDetail)
        tvFloatSrc = findViewById(R.id.tvFloatSrc)
        tvOverlayState = findViewById(R.id.tvOverlayState)

        rowBj = findViewById(R.id.rowSelBj)
        rowTaobao = findViewById(R.id.rowSelTaobao)
        rowJd = findViewById(R.id.rowSelJd)
        tvTimeBj = findViewById(R.id.tvTimeBj)
        tvTimeTaobao = findViewById(R.id.tvTimeTaobao)
        tvTimeJd = findViewById(R.id.tvTimeJd)
        tvDeltaBj = findViewById(R.id.tvDeltaBj)
        tvDeltaTaobao = findViewById(R.id.tvDeltaTaobao)
        tvDeltaJd = findViewById(R.id.tvDeltaJd)

        bindDot("bj", findViewById(R.id.dotBj))
        bindDot("taobao", findViewById(R.id.dotTaobao))
        bindDot("jd", findViewById(R.id.dotJd))

        tvAlpha = findViewById(R.id.tvAlpha)
        tvScale = findViewById(R.id.tvScale)
        sbAlpha = findViewById(R.id.sbAlpha)
        sbScale = findViewById(R.id.sbScale)
        swMs = findViewById(R.id.swMs)
        swLock = findViewById(R.id.swLock)
        // 底部版本脚注：让"设备上装的到底是哪一版"一眼可见
        // （以前版本号恒为 1.0，重复抱怨时根本没法判断有没有重装）
        findViewById<TextView>(R.id.tvBuild).text = buildFooter()

        loadPrefsIntoViews()

        rowBj.setOnClickListener { pickSource("bj") }
        rowTaobao.setOnClickListener { pickSource("taobao") }
        rowJd.setOnClickListener { pickSource("jd") }

        findViewById<TextView>(R.id.btnStart).setOnClickListener { startFloat() }
        findViewById<TextView>(R.id.btnOverlay).setOnClickListener { requestOverlay() }
        findViewById<TextView>(R.id.btnStop).setOnClickListener {
            FloatService.stop(this)
            toast("悬浮窗已停止")
        }
        findViewById<TextView>(R.id.btnSyncNow).setOnClickListener {
            TimeHub.instance.forceRefresh()
            toast("正在重新校时…")
        }

        val seek = object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: SeekBar?, progress: Int, fromUser: Boolean) {
                // ★ 拖动过程中**不能**每动一格就写一次 SharedPreferences 并递增 K_REV：
                //   悬浮窗是靠 K_REV 变化热重载的，拖一次滑块会触发上百次重排。
                //   改成拖完 250ms 落一次盘。
                if (fromUser) scheduleSaveAppearance()
            }

            override fun onStartTrackingTouch(sb: SeekBar?) {}

            override fun onStopTrackingTouch(sb: SeekBar?) {
                flushSaveAppearance()
            }
        }
        sbAlpha.setOnSeekBarChangeListener(seek)
        sbScale.setOnSeekBarChangeListener(seek)
        swMs.setOnCheckedChangeListener { _, _ -> saveAppearance() }
        swLock.setOnCheckedChangeListener { _, _ -> saveAppearance() }
    }

    private val saveHandler = Handler(Looper.getMainLooper())
    private var savePending = false
    private val saveRunnable = Runnable {
        // ★ 必须复位：否则防抖跑完后标志还是 true，之后任何 flush 都会白写一次 prefs
        //   并让 K_REV +1，悬浮窗跟着白热重载一次
        savePending = false
        saveAppearance()
    }

    private fun scheduleSaveAppearance() {
        savePending = true
        saveHandler.removeCallbacks(saveRunnable)
        saveHandler.postDelayed(saveRunnable, 250)
    }

    /** 松手/退到后台时立刻落盘，避免最后一次调整丢掉 */
    private fun flushSaveAppearance() {
        saveHandler.removeCallbacks(saveRunnable)
        if (savePending) {
            savePending = false
            saveAppearance()
        }
    }

    override fun onResume() {
        super.onResume()
        refreshOverlayState()
        if (!attached) {
            TimeHub.instance.acquire()
            attached = true
        }
        if (TimeHub.instance.clocks.any { it.utcMsOrNull() == null }) {
            TimeHub.instance.refreshAll()
        }
        // 界面重建（比如转屏）后视图是新的，渲染缓存必须作废，否则会漏刷新
        invalidateRenderCache()
        renderFast()
        renderSlow()
        handler.removeCallbacks(ticker)
        handler.post(ticker)
    }

    /** 底部版本脚注：版本名 + 安装时间。让"设备上装的是哪一版"一眼可见 */
    private fun buildFooter(): String = try {
        val pi = packageManager.getPackageInfo(packageName, 0)
        val whenStr = java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.CHINA)
            .format(java.util.Date(pi.lastUpdateTime))
        getString(R.string.build_footer, pi.versionName, whenStr)
    } catch (_: Throwable) {
        ""
    }

    private fun invalidateRenderCache() {        lastSkewText = null
        lastSkewColor = Int.MIN_VALUE
        lastFloatSrcText = null
        lastFloatSrcColor = Int.MIN_VALUE
        lastHighlightId = null
        lastDotColorById.clear()
        lastDeltaColorById.clear()
        lastTimeAlphaById.clear()
    }

    override fun onPause() {
        handler.removeCallbacks(ticker)
        flushSaveAppearance()
        if (attached) {
            TimeHub.instance.release()
            attached = false
        }
        super.onPause()
    }

    // ------------------------------------------------------------------ 交互

    /** 选择悬浮窗显示哪一路 —— 只在启动悬浮窗之前有意义 */
    private fun pickSource(id: String) {
        // ★ 需求就是"启动悬浮窗之前选好，开着的时候不要切换"：
        //   抢购时误触一下就换了显示源，看到的就不是你要抢的那家时间了。
        if (FloatService.isRunning(this)) {
            toast("悬浮窗运行中，先关掉它才能换源（避免抢购时看错时间）")
            return
        }
        prefs.edit()
            .putString(Config.K_FLOAT_SRC, id)
            .putInt(Config.K_REV, prefs.getInt(Config.K_REV, 0) + 1)
            .apply()
        TimeHub.instance.selectedId = id
        renderFast()
        renderSlow()
        toast("悬浮窗将显示：${ServerClock.displayName(id)}")
    }

    private fun requestOverlay() {
        if (Build.VERSION.SDK_INT < 23) {
            toast("当前系统无需授权")
            return
        }
        if (Settings.canDrawOverlays(this)) {
            toast("悬浮窗权限已授予")
            return
        }
        startActivity(
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
        )
    }

    private fun startFloat() {
        if (!FloatService.hasOverlayPermission(this)) {
            toast("请先授予「显示在其他应用上层」权限")
            requestOverlay()
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 101)
        }
        FloatService.start(this)
        toast("悬浮窗已启动（显示：${ServerClock.displayName(TimeHub.instance.selectedId)}）")
    }

    private fun refreshOverlayState() {
        val ok = FloatService.hasOverlayPermission(this)
        tvOverlayState.text = if (ok) "悬浮窗权限：已授予" else "悬浮窗权限：未授予（点上面按钮去开）"
        tvOverlayState.setTextColor(if (ok) Color.parseColor("#FF34C759") else Color.parseColor("#FFFF453A"))
    }

    // ------------------------------------------------------------------ 渲染

    /** 每帧都要更新的：三路时间、偏差、状态点、选中高亮、本机墙钟偏差 */
    private fun renderFast() {
        val hub = TimeHub.instance
        // 直接用开关的当前状态，省掉每帧读 SharedPreferences
        val showMs = swMs.isChecked
        val bj = hub.beijing.utcMsOrNull()
        val tb = hub.taobao.utcMsOrNull()
        val jd = hub.jd.utcMsOrNull()

        setTime(tvTimeBj, "bj", bj, showMs)
        setTime(tvTimeTaobao, "taobao", tb, showMs)
        setTime(tvTimeJd, "jd", jd, showMs)

        tvDeltaBj.text = "基准"
        setDelta(tvDeltaTaobao, "taobao", tb, bj)
        setDelta(tvDeltaJd, "jd", jd, bj)

        for (c in hub.clocks) {
            val col = c.statusColor()
            if (lastDotColorById[c.id] != col) {
                dotDrawables[c.id]?.setColor(col)
                lastDotColorById[c.id] = col
            }
        }

        val selClock = hub.selected()

        // 选中行高亮：只在选择变化时重建（以前每帧都 new 三个 GradientDrawable，一秒 90 次垃圾）
        if (lastHighlightId != selClock.id) {
            lastHighlightId = selClock.id
            styleRow(rowBj, "bj", selClock.id)
            styleRow(rowTaobao, "taobao", selClock.id)
            styleRow(rowJd, "jd", selClock.id)
        }

        val srcText = "显示：" + ServerClock.displayName(selClock.id)
        if (lastFloatSrcText != srcText) {
            tvFloatSrc.text = srcText
            lastFloatSrcText = srcText
        }
        if (lastFloatSrcColor != selClock.accentColor) {
            tvFloatSrc.setTextColor(selClock.accentColor)
            lastFloatSrcColor = selClock.accentColor
        }

        // ★ 本机墙钟 vs「当前选中的那一路服务器」——不是写死北京时间
        //   fast > 0 表示本机墙钟比该服务器快
        val skewText: String
        val skewColor: Int
        if (selClock.utcMsOrNull() == null) {
            skewText = "本机墙钟：${selClock.label}服务器还没校上，暂时比不出来"
            skewColor = Color.parseColor("#FFFFC107")
        } else {
            val fast = selClock.localWallFastMs()
            skewText = if (fast >= 0)
                "本机墙钟比${selClock.label}服务器快 ${fast}ms"
            else
                "本机墙钟比${selClock.label}服务器慢 ${-fast}ms"
            skewColor = when {
                abs(fast) <= 50 -> Color.parseColor("#FF34C759")
                abs(fast) <= 200 -> Color.parseColor("#FFFFC107")
                else -> Color.parseColor("#FFFF453A")
            }
        }
        if (lastSkewText != skewText) {
            tvSkew.text = skewText
            lastSkewText = skewText
        }
        if (lastSkewColor != skewColor) {
            tvSkew.setTextColor(skewColor)
            lastSkewColor = skewColor
        }
    }

    /** 每 500ms 更新一次就够的：三源互差 + 每路采样细节 */
    private fun renderSlow() {
        val hub = TimeHub.instance

        // 三源互差 —— 判断"这个时间到底可不可信"
        val cross = hub.crossCheck()
        tvCross.text = when {
            cross.level < 0 -> cross.text                       // 可用源不足，别硬拼"略有差异"
            cross.level == 0 -> "${cross.text} · 一致（可信）"
            cross.level == 1 -> "${cross.text} · 略有差异"
            else -> "${cross.text} · 差异偏大，注意核对"
        }
        tvCross.setTextColor(
            when {
                cross.level < 0 -> Color.parseColor("#80FFFFFF")
                cross.level == 0 -> Color.parseColor("#FF34C759")
                cross.level == 1 -> Color.parseColor("#FFFFC107")
                else -> Color.parseColor("#FFFF8B84")
            }
        )

        tvDetail.text = buildBriefLines(hub)
    }

    /**
     * 三路时间下面那一块：**只保留「名称 + 往返时间 + 多久前校准」**。
     * 颜色按健康度给（绿=正常 / 黄=偏旧或上轮失败 / 红=还没校上），用颜色代替文字提示。
     */
    private fun buildBriefLines(hub: TimeHub): CharSequence {
        val sb = SpannableStringBuilder()
        for ((i, c) in hub.clocks.withIndex()) {
            if (i > 0) sb.append('\n')
            val start = sb.length
            sb.append(ServerClock.displayName(c.id))
            sb.append("  ")
            sb.append(c.briefLine())
            sb.setSpan(
                ForegroundColorSpan(
                    when (c.healthLevel()) {
                        0 -> Color.parseColor("#B3FFFFFF")
                        1 -> Color.parseColor("#FFFFC107")
                        else -> Color.parseColor("#FFFF8B84")
                    }
                ),
                start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
        }
        return sb
    }

    private fun setTime(tv: TextView, id: String, t: Long?, showMs: Boolean) {
        tv.text = when {
            t == null -> "--:--:--.---"
            showMs -> Fmt.hms(t)
            else -> Fmt.hms8(t) + "     "
        }
        val alpha = if (t == null) 0.45f else 1f
        if (lastTimeAlphaById[id] != alpha) {
            tv.alpha = alpha
            lastTimeAlphaById[id] = alpha
        }
    }

    private fun setDelta(tv: TextView, id: String, t: Long?, base: Long?) {
        val text: String
        val color: Int
        if (t == null || base == null) {
            text = "--"
            color = Color.parseColor("#FFFF8B84")
        } else {
            val d = t - base
            text = Fmt.delta(d) + "ms"
            color = when {
                abs(d) <= 30 -> Color.parseColor("#B3FFFFFF")
                abs(d) <= 200 -> Color.parseColor("#FFFFC107")
                else -> Color.parseColor("#FFFF453A")
            }
        }
        if (tv.text != text) tv.text = text
        if (lastDeltaColorById[id] != color) {
            tv.setTextColor(color)
            lastDeltaColorById[id] = color
        }
    }

    private fun bindDot(id: String, view: View) {
        val d = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(ServerClock.colorOf(id))
        }
        view.background = d
        dotDrawables[id] = d
    }

    private fun styleRow(row: View, id: String, selectedId: String) {
        if (id == selectedId) {
            val accent = ServerClock.colorOf(id)
            val bg = GradientDrawable()
            bg.cornerRadius = dp(14f)
            bg.setColor((accent and 0x00FFFFFF) or (0x2E shl 24))
            bg.setStroke(dp(1.4f).toInt().coerceAtLeast(2), (accent and 0x00FFFFFF) or (0x99 shl 24))
            row.background = bg
        } else {
            row.background = null
        }
    }

    private fun dp(v: Float): Float = v * resources.displayMetrics.density

    // ------------------------------------------------------------------ 设置（悬浮窗外观，改完即时生效）

    private fun loadPrefsIntoViews() {
        sbAlpha.progress = (prefs.getInt(Config.K_ALPHA, 94) - 20).coerceIn(0, 80)
        sbScale.progress = (prefs.getInt(Config.K_TEXT_SCALE, 100) - 60).coerceIn(0, 140)
        swMs.isChecked = prefs.getBoolean(Config.K_SHOW_MS, true)
        swLock.isChecked = prefs.getBoolean(Config.K_LOCK, false)
        TimeHub.instance.selectedId = prefs.getString(Config.K_FLOAT_SRC, "taobao") ?: "taobao"
        updateLabels()
    }

    private fun updateLabels() {
        tvAlpha.text = "不透明度：${20 + sbAlpha.progress}%"
        tvScale.text = "字号：${60 + sbScale.progress}%"
    }

    private fun saveAppearance() {
        updateLabels()
        prefs.edit()
            .putInt(Config.K_ALPHA, 20 + sbAlpha.progress)
            .putInt(Config.K_TEXT_SCALE, 60 + sbScale.progress)
            .putBoolean(Config.K_SHOW_MS, swMs.isChecked)
            .putBoolean(Config.K_LOCK, swLock.isChecked)
            .putInt(Config.K_REV, prefs.getInt(Config.K_REV, 0) + 1)
            .apply()
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
}
