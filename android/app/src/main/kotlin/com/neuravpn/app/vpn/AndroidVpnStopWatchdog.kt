package com.neuravpn.app.vpn

import android.os.Handler
import android.os.Looper

/** Independent of the native runtime worker, which may be blocked in JNI. */
class AndroidVpnStopWatchdog(
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val timeoutMs: Long = 15_000,
) {
    private var pending: Runnable? = null

    @Synchronized
    fun arm(stillStopping: () -> Boolean, onTimeout: () -> Unit) {
        // Duplicate stop/onDestroy must not extend the original deadline.
        if (pending != null) return
        val callback = object : Runnable {
            override fun run() {
                synchronized(this@AndroidVpnStopWatchdog) {
                    if (pending !== this) return
                    pending = null
                    if (stillStopping()) onTimeout()
                }
            }
        }
        pending = callback
        handler.postDelayed(callback, timeoutMs)
    }

    @Synchronized
    fun cancel() {
        pending?.let(handler::removeCallbacks)
        pending = null
    }
}
