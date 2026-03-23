package com.neuravpn.app.vpn

import android.content.Context
import com.neuravpn.app.HappycatVpnApplication

object AndroidVpnRuntimeManager {
    private val runtimes: Map<String, AndroidVpnRuntime> =
        listOf(XrayAndroidRuntime).associateBy { it.id }

    fun bootstrap(application: HappycatVpnApplication) {
        runtimes.values.forEach { runtime ->
            runCatching { runtime.bootstrap(application) }
        }
    }

    fun start(
        context: Context,
        runtimeId: String?,
        config: String,
        executablePath: String?,
        includePackages: List<String>?,
        excludePackages: List<String>?,
    ) {
        resolveRuntime(runtimeId).start(
            context = context,
            config = config,
            executablePath = executablePath,
            includePackages = includePackages,
            excludePackages = excludePackages,
        )
    }

    fun stop(context: Context, runtimeId: String?) {
        val explicitRuntime = runtimeId?.let { runtimes[it] }
        if (explicitRuntime != null) {
            explicitRuntime.stop(context)
            return
        }
        runtimes.values.forEach { runtime ->
            runCatching { runtime.stop(context) }
        }
    }

    fun isRunning(context: Context): Boolean {
        if (runtimes.values.any { runtime -> runCatching { runtime.isRunning(context) }.getOrDefault(false) }) {
            return true
        }
        return AndroidVpnRuntimeStateStore.isMarkedRunning(context)
    }

    fun readDebugLog(context: Context, runtimeId: String?): String {
        val explicitRuntime = runtimeId?.let { runtimes[it] }
        if (explicitRuntime != null) {
            return runCatching { explicitRuntime.readDebugLog(context) }.getOrDefault("")
        }
        val preferredRuntimeId = AndroidVpnRuntimeStateStore.lastRuntime(context)
        val preferredRuntime = preferredRuntimeId?.let { runtimes[it] } ?: resolveRuntime(runtimeId)
        return runCatching { preferredRuntime.readDebugLog(context) }.getOrDefault("")
    }

    fun clearDebugLog(context: Context, runtimeId: String?) {
        val explicitRuntime = runtimeId?.let { runtimes[it] }
        if (explicitRuntime != null) {
            runCatching { explicitRuntime.clearDebugLog(context) }
            return
        }
        runtimes.values.forEach { runtime ->
            runCatching { runtime.clearDebugLog(context) }
        }
    }

    fun resolveRuntime(runtimeId: String?): AndroidVpnRuntime {
        val resolvedId = runtimeId?.takeIf { runtimes.containsKey(it) } ?: XrayAndroidRuntime.id
        return runtimes[resolvedId] ?: XrayAndroidRuntime
    }

    fun lastStartupError(context: Context): String? =
        AndroidVpnRuntimeStateStore.lastError(context)
}
