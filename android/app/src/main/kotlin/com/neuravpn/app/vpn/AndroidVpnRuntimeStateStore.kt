package com.neuravpn.app.vpn

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * Cross-process safe state store backed by a JSON file in [Context.getFilesDir].
 *
 * The VPN service runs in the `:xray_vpn` process while Flutter lives in the
 * main process.  SharedPreferences is NOT multi-process safe on Android, so we
 * use a plain file instead.  Reads/writes are short and sequential, which keeps
 * the risk of partial-read races negligible on ext4/f2fs with ≤4 KB payloads.
 */
object AndroidVpnRuntimeStateStore {
    private const val FILE_NAME = "neuravpn_runtime_state.json"
    private const val KEY_RUNNING = "running"
    private const val KEY_RUNTIME = "runtime"
    private const val KEY_LAST_ERROR = "last_error"

    private fun stateFile(context: Context): File =
        File(context.filesDir, FILE_NAME)

    private fun readState(context: Context): JSONObject {
        val file = stateFile(context)
        if (!file.exists()) return JSONObject()
        return runCatching { JSONObject(file.readText()) }.getOrDefault(JSONObject())
    }

    private fun writeState(context: Context, state: JSONObject) {
        runCatching { stateFile(context).writeText(state.toString()) }
    }

    fun markRunning(context: Context, runtimeId: String) {
        val state = readState(context)
        state.put(KEY_RUNNING, true)
        state.put(KEY_RUNTIME, runtimeId)
        state.remove(KEY_LAST_ERROR)
        writeState(context, state)
    }

    fun markStopped(context: Context, runtimeId: String? = null, error: String? = null) {
        val state = readState(context)
        state.put(KEY_RUNNING, false)
        if (runtimeId != null) state.put(KEY_RUNTIME, runtimeId)
        if (error != null) state.put(KEY_LAST_ERROR, error) else state.remove(KEY_LAST_ERROR)
        writeState(context, state)
    }

    fun isMarkedRunning(context: Context): Boolean =
        readState(context).optBoolean(KEY_RUNNING, false)

    fun lastRuntime(context: Context): String? =
        readState(context).optString(KEY_RUNTIME, null)

    fun lastError(context: Context): String? {
        val state = readState(context)
        return if (state.has(KEY_LAST_ERROR)) state.optString(KEY_LAST_ERROR) else null
    }
}
