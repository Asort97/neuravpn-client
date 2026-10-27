package com.neuravpn.app.vpn

import android.content.Context
import android.os.Process
import android.system.Os
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile

enum class AndroidVpnPhase(val wireName: String) {
    STARTING("starting"), RUNNING("running"), STOPPING("stopping"),
    STOPPED("stopped"), ERROR("error");

    companion object {
        fun fromWireName(value: String?): AndroidVpnPhase =
            entries.firstOrNull { it.wireName == value } ?: STOPPED
    }
}

data class AndroidVpnRuntimeSnapshot(
    val phase: AndroidVpnPhase = AndroidVpnPhase.STOPPED,
    val runtimeId: String? = null,
    val sessionId: String? = null,
    val updatedAt: Long = 0L,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val routingMode: String? = null,
    val ownerPid: Int? = null,
) {
    val isRunning: Boolean get() = phase == AndroidVpnPhase.RUNNING
    val isActive: Boolean get() = phase == AndroidVpnPhase.STARTING ||
        phase == AndroidVpnPhase.RUNNING || phase == AndroidVpnPhase.STOPPING

    fun toMap(tx: Long? = null, rx: Long? = null): Map<String, Any?> = mapOf(
        "state" to phase.wireName,
        "sessionId" to sessionId,
        "runtime" to runtimeId,
        "updatedAt" to updatedAt,
        "errorCode" to errorCode,
        "errorMessage" to errorMessage,
        "routingMode" to routingMode,
        "tx" to tx,
        "rx" to rx,
    )
}

/** Cross-process runtime state stored with an atomic replace. */
object AndroidVpnRuntimeStateStore {
    private const val FILE_NAME = "neuravpn_runtime_state.json"

    private fun stateFile(context: Context): File = File(context.filesDir, FILE_NAME)

    fun read(context: Context): AndroidVpnRuntimeSnapshot {
        val file = stateFile(context)
        if (!file.exists()) return AndroidVpnRuntimeSnapshot()
        return runCatching {
            val state = JSONObject(file.readText(Charsets.UTF_8))
            val phase = if (state.has("state")) {
                AndroidVpnPhase.fromWireName(state.optString("state"))
            } else if (state.optBoolean("running", false)) {
                AndroidVpnPhase.RUNNING
            } else {
                AndroidVpnPhase.STOPPED
            }
            AndroidVpnRuntimeSnapshot(
                phase = phase,
                runtimeId = state.optionalString("runtime"),
                sessionId = state.optionalString("session_id"),
                updatedAt = state.optLong("updated_at", file.lastModified()),
                errorCode = state.optionalString("error_code"),
                errorMessage = state.optionalString("error_message")
                    ?: state.optionalString("last_error"),
                routingMode = state.optionalString("routing_mode"),
                ownerPid = state.optInt("owner_pid").takeIf { it > 0 },
            ).let { snapshot ->
                val processGone = snapshot.ownerPid?.let { pid ->
                    runCatching { Os.kill(pid, 0) }.isFailure
                } ?: (System.currentTimeMillis() - snapshot.updatedAt > 30_000)
                if (snapshot.isActive && processGone) {
                    snapshot.copy(
                        phase = AndroidVpnPhase.ERROR,
                        errorCode = "VPN_PROCESS_EXITED",
                        errorMessage = "Android stopped the VPN service. Connect again.",
                    )
                } else snapshot
            }
        }.getOrDefault(AndroidVpnRuntimeSnapshot())
    }

    fun markStarting(context: Context, runtimeId: String, sessionId: String, routingMode: String?,
        ownerPid: Int? = null) =
        write(context, AndroidVpnRuntimeSnapshot(AndroidVpnPhase.STARTING, runtimeId, sessionId,
            System.currentTimeMillis(), routingMode = routingMode, ownerPid = ownerPid))

    fun markRunning(context: Context, runtimeId: String, sessionId: String, routingMode: String?) =
        write(context, AndroidVpnRuntimeSnapshot(AndroidVpnPhase.RUNNING, runtimeId, sessionId,
            System.currentTimeMillis(), routingMode = routingMode, ownerPid = Process.myPid()))

    fun markStopping(context: Context, runtimeId: String? = null) = update(context) { current ->
        current.copy(
            phase = AndroidVpnPhase.STOPPING,
            runtimeId = runtimeId ?: current.runtimeId,
            updatedAt = System.currentTimeMillis(),
            errorCode = null,
            errorMessage = null,
        )
    }

    fun markStopped(context: Context, runtimeId: String? = null, preserveError: Boolean = false,
        sessionId: String? = null) = update(context) { current ->
        if ((sessionId != null && current.sessionId != sessionId) ||
            (preserveError && current.phase == AndroidVpnPhase.ERROR)) current
        else current.copy(
            phase = AndroidVpnPhase.STOPPED,
            runtimeId = runtimeId ?: current.runtimeId,
            updatedAt = System.currentTimeMillis(),
            errorCode = null,
            errorMessage = null,
        )
    }

    fun requestStart(context: Context, runtimeId: String, sessionId: String, routingMode: String?): Boolean {
        var accepted = false
        update(context) { current ->
            if (current.isActive) current else {
                accepted = true
                AndroidVpnRuntimeSnapshot(AndroidVpnPhase.STARTING, runtimeId, sessionId,
                    System.currentTimeMillis(), routingMode = routingMode)
            }
        }
        return accepted
    }

    fun markError(
        context: Context,
        runtimeId: String,
        sessionId: String?,
        errorCode: String,
        errorMessage: String,
        routingMode: String? = null,
    ) = write(context, AndroidVpnRuntimeSnapshot(
        AndroidVpnPhase.ERROR,
        runtimeId,
        sessionId,
        System.currentTimeMillis(),
        errorCode,
        errorMessage,
        routingMode,
    ))

    fun isMarkedRunning(context: Context): Boolean = read(context).isRunning
    fun lastRuntime(context: Context): String? = read(context).runtimeId
    fun lastError(context: Context): String? = read(context).errorMessage

    private fun write(context: Context, snapshot: AndroidVpnRuntimeSnapshot) = update(context) { snapshot }

    @Synchronized
    private fun update(context: Context, transform: (AndroidVpnRuntimeSnapshot) -> AndroidVpnRuntimeSnapshot) {
        val target = stateFile(context)
        // The Activity and VPN service write from different processes.
        RandomAccessFile(File(target.parentFile, "$FILE_NAME.lock"), "rw").use { lockFile ->
            lockFile.channel.lock().use {
                val snapshot = transform(read(context))
                val state = JSONObject().apply {
                    put("state", snapshot.phase.wireName)
                    snapshot.runtimeId?.let { put("runtime", it) }
                    snapshot.sessionId?.let { put("session_id", it) }
                    put("updated_at", snapshot.updatedAt)
                    snapshot.errorCode?.let { put("error_code", it) }
                    snapshot.errorMessage?.let { put("error_message", it) }
                    snapshot.routingMode?.let { put("routing_mode", it) }
                    snapshot.ownerPid?.let { put("owner_pid", it) }
                }
                val temp = File.createTempFile("vpn-state-", ".tmp", target.parentFile)
                try {
                    FileOutputStream(temp).use { output ->
                        output.write(state.toString().toByteArray(Charsets.UTF_8))
                        output.fd.sync()
                    }
                    Os.rename(temp.path, target.path)
                } finally {
                    temp.delete()
                }
            }
        }
    }

    private fun JSONObject.optionalString(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).takeIf { it.isNotBlank() }
    }
}
