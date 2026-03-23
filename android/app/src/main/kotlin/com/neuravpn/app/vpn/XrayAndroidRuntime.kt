package com.neuravpn.app.vpn

import android.content.Context
import com.neuravpn.app.HappycatVpnApplication
import go.Seq
import libXray.LibXray

object XrayAndroidRuntime : AndroidVpnRuntime {
    override val id: String = "xray"

    override fun bootstrap(application: HappycatVpnApplication) {
        Seq.setContext(application)
        LibXray.touch()
    }

    override fun start(
        context: Context,
        config: String,
        executablePath: String?,
        includePackages: List<String>?,
        excludePackages: List<String>?,
    ) {
        XrayVpnService.start(
            context = context,
            config = config,
            executablePath = executablePath,
            includePackages = includePackages,
            excludePackages = excludePackages,
        )
    }

    override fun stop(context: Context) {
        XrayVpnService.stop(context)
    }

    override fun isRunning(context: Context): Boolean =
        AndroidVpnRuntimeStateStore.isMarkedRunning(context)

    override fun readDebugLog(context: Context): String =
        AndroidVpnDebugLogStore.read(context)

    override fun clearDebugLog(context: Context) {
        AndroidVpnDebugLogStore.clear(context)
    }
}
