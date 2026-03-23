package com.neuravpn.app.vpn

import android.content.Context
import com.neuravpn.app.HappycatVpnApplication

interface AndroidVpnRuntime {
    val id: String

    fun bootstrap(application: HappycatVpnApplication) {}

    fun start(
        context: Context,
        config: String,
        executablePath: String?,
        includePackages: List<String>?,
        excludePackages: List<String>?,
    )

    fun stop(context: Context)

    fun isRunning(context: Context): Boolean

    fun readDebugLog(context: Context): String = ""

    fun clearDebugLog(context: Context) {}
}
