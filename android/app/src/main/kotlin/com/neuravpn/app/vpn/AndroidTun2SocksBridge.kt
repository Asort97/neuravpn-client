package com.neuravpn.app.vpn

import android.content.Context
import android.os.ParcelFileDescriptor
import java.io.File

object AndroidTun2SocksBridge {
    private const val CONFIG_FILE_NAME = "neuravpn-hev-socks5-tunnel.yaml"

    @JvmStatic
    @Suppress("FunctionName")
    private external fun TProxyStartService(configPath: String, fd: Int)

    @JvmStatic
    @Suppress("FunctionName")
    private external fun TProxyStopService()

    @JvmStatic
    @Suppress("FunctionName")
    private external fun TProxyGetStats(): LongArray

    init {
        System.loadLibrary("hev-socks5-tunnel")
    }

    fun start(
        context: Context,
        vpnInterface: ParcelFileDescriptor,
        mtu: Int,
        socksPort: Int,
        ipv4Client: String,
        ipv6Client: String?,
        logLevel: String = "warn",
    ) {
        val configFile = File(context.filesDir, CONFIG_FILE_NAME).apply {
            writeText(
                buildString {
                    appendLine("tunnel:")
                    appendLine("  mtu: $mtu")
                    appendLine("  ipv4: $ipv4Client")
                    if (!ipv6Client.isNullOrBlank()) {
                        appendLine("  ipv6: '$ipv6Client'")
                    }
                    appendLine("socks5:")
                    appendLine("  address: 127.0.0.1")
                    appendLine("  port: $socksPort")
                    appendLine("  udp: 'udp'")
                    appendLine("misc:")
                    appendLine("  log-level: $logLevel")
                    appendLine("  tcp-read-write-timeout: 300000")
                    appendLine("  udp-read-write-timeout: 60000")
                },
            )
        }
        TProxyStartService(configFile.absolutePath, vpnInterface.fd)
    }

    fun stop() {
        TProxyStopService()
    }

    /**
     * Returns [tx_bytes, rx_bytes] from hev-socks5-tunnel, or null on failure.
     * The native array is [tx_packets, tx_bytes, rx_packets, rx_bytes].
     */
    fun getStats(): LongArray? {
        return runCatching { TProxyGetStats() }.getOrNull()
    }
}
