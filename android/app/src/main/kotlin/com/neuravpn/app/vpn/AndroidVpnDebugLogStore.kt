package com.neuravpn.app.vpn

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object AndroidVpnDebugLogStore {
    private const val LOG_FILE_NAME = "android_vpn_runtime.log"
    private const val MAX_LINES = 400

    private fun logFile(context: Context): File =
        File(context.filesDir, LOG_FILE_NAME)

    fun append(context: Context, tag: String, message: String) {
        runCatching {
            val file = logFile(context)
            val ts = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
            val line = "[$ts][$tag] $message"
            val lines = if (file.exists()) {
                file.readLines().takeLast(MAX_LINES - 1).toMutableList()
            } else {
                mutableListOf()
            }
            lines.add(line)
            file.writeText(lines.joinToString(separator = "\n", postfix = "\n"))
        }
    }

    fun read(context: Context): String {
        val file = logFile(context)
        if (!file.exists()) {
            return ""
        }
        return runCatching { file.readText() }.getOrDefault("")
    }

    fun clear(context: Context) {
        runCatching { logFile(context).delete() }
    }
}
