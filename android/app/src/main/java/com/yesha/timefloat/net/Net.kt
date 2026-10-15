package com.yesha.timefloat.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/**
 * 网络状态判断。用于给出「手机没网」这种一眼能看懂的提示，
 * 而不是让用户盯着"校时中"猜。
 */
object Net {
    @Volatile
    private var app: Context? = null

    fun init(ctx: Context) {
        if (app == null) app = ctx.applicationContext
    }

    fun online(): Boolean {
        val c = app ?: return true
        return try {
            val cm = c.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return true
            val n = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(n) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } catch (_: Throwable) {
            true
        }
    }
}
