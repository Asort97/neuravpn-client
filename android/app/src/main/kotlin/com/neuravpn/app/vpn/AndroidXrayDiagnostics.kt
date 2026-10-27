package com.neuravpn.app.vpn

import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject

/** Native log bytes stay in a pipe; only sanitized failures reach storage. */
internal class AndroidXrayDiagnostics(private val context: Context) : AutoCloseable {
    private var writeEnd: ParcelFileDescriptor? = null

    fun configure(config: String): String {
        check(writeEnd == null)
        val pipe = ParcelFileDescriptor.createPipe()
        writeEnd = pipe[1]
        Thread({
            runCatching {
                ParcelFileDescriptor.AutoCloseInputStream(pipe[0]).bufferedReader().use { reader ->
                    var previous = ""
                    var lastWritten = -1000L
                    reader.forEachLine { line ->
                        val safe = failureMessage(line) ?: return@forEachLine
                        val now = SystemClock.elapsedRealtime()
                        if (safe != previous && now - lastWritten >= 1000L) {
                            AndroidVpnDebugLogStore.append(context, "Xray", safe)
                            Log.w("NeuraXray", safe)
                            previous = safe
                            lastWritten = now
                        }
                    }
                }
            }
        }, "neuravpn-xray-errors").apply { isDaemon = true }.start()
        return JSONObject(config).apply {
            put("log", JSONObject().apply {
                // Xray reports transport failures at Info, not just Error.
                put("loglevel", "info")
                put("access", "none")
                put("dnsLog", false)
                put("error", "/proc/self/fd/${pipe[1].fd}")
            })
        }.toString()
    }

    // Call after stopping Xray so its writer closes and the reader reaches EOF.
    override fun close() {
        runCatching { writeEnd?.close() }
        writeEnd = null
    }

    companion object {
        internal fun failureMessage(line: String): String? {
            if (!listOf("failed", "error", "timeout", "rejected", "refused")
                    .any { line.contains(it, ignoreCase = true) }) return null
            // Strip native timestamps/connection IDs before deduplicating.
            val message = line.substringAfter("] ", line)
                .replace(Regex("\\[\\d+\\]\\s*"), "")
            return AndroidVpnLogSanitizer.redact(message).take(1200)
        }
    }
}
