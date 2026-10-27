package com.neuravpn.app.vpn

internal object AndroidVpnLogSanitizer {
    private val secrets = listOf(
        Regex("(?i)(?:https?|vless|hysteria2|hy2)://[^\\s\\\"<>]+"),
        Regex("(?i)\\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\\b"),
        Regex("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"),
        Regex("(?i)(?<![a-z0-9])(?:[a-z0-9-]+\\.)+[a-z]{2,63}\\b"),
        Regex("(?i)(?:[0-9a-f]{0,4}:){2,}[0-9a-f:]+(?:%[a-z0-9]+)?"),
        Regex("(?i)(?:pbk|sid|uuid|publicKey|privateKey|password|auth|token)[\\\"\\s]*[:=][\\\"\\s]*[^\\s,}]+"),
        Regex("[A-Za-z0-9_+/=-]{32,}"),
    )

    fun redact(message: String): String =
        secrets.fold(message) { text, pattern -> pattern.replace(text, "[redacted]") }
}
