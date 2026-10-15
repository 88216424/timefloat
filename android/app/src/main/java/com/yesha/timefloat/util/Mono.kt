package com.yesha.timefloat.util

import android.os.SystemClock

/**
 * 单调时钟。
 *
 * 为什么不直接用 System.currentTimeMillis()？
 *  墙钟会被系统校时、时区、NTP 后台线程随时改动，一跳就是几百毫秒——抢购场景直接致命。
 *  elapsedRealtime() 是"自开机以来的毫秒数（包含休眠）"，只单调递增、不受校时影响，
 *  所以我们只在"校时成功的那一瞬间"把服务器时间与它对齐，之后全靠它推进。
 */
object Mono {
    fun ms(): Long = SystemClock.elapsedRealtime()
    fun ns(): Long = SystemClock.elapsedRealtimeNanos()
}
