package com.neuravpn.app.vpn

import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.*
import libXray.DialerController
import libXray.LibXray
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

// Explicitly bound, private process. Never establishes a TUN or changes VPN state.
// VpnService is used only to protect this UID's probe sockets from its active VPN.
class ProfileProbeService : VpnService(), DialerController {
    private val worker get() = executor
    private val main = Handler(Looper.getMainLooper())
    private val api = AndroidXrayApi()
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    @Volatile private var network: Network? = null
    @Volatile private var connection: HttpsURLConnection? = null
    @Volatile private var cancelled = AtomicBoolean(false)
    private val bindFailed = AtomicBoolean(false)
    private var busy = false
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        when (message.what) {
            CHECK -> {
                val reply = message.replyTo ?: return@Handler true
                val id = message.arg1
                if (busy) {
                    send(reply, id, "error", "BUSY", 0)
                } else {
                    busy = true
                    val token = AtomicBoolean(false)
                    cancelled = token
                    val config = message.data.getString("config").orEmpty()
                    worker.execute { check(config, id, reply, token) }
                }
            }
            CANCEL -> cancel()
        }
        true
    })

    override fun onBind(intent: Intent) = messenger.binder

    private fun cancel() {
        cancelled.set(true)
        // disconnect() can wait on a socket lock; never do it on the main thread.
        val pending = connection
        if (pending != null) Thread { runCatching { pending.disconnect() } }.start()
    }

    private fun physicalNetwork(): Network? {
        val candidates = connectivity.allNetworks.filter {
            val caps = connectivity.getNetworkCapabilities(it)
            caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) == true &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }
        return candidates.firstOrNull { it == connectivity.activeNetwork }
            ?: candidates.maxByOrNull {
                val caps = connectivity.getNetworkCapabilities(it) ?: return@maxByOrNull -1
                (if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 100 else 0) +
                    (if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) 10 else 0)
            }
    }

    override fun protectFd(fd: Long): Boolean {
      return try {
        val selected = checkNotNull(network)
        val protected = protect(fd.toInt())
        val hasVpn = connectivity.allNetworks.any {
            connectivity.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
        // Fail closed if another VPN owns the UID's route. Never test through it.
        check(protected || !hasVpn)
        ParcelFileDescriptor.fromFd(fd.toInt()).use { selected.bindSocket(it.fileDescriptor) }
        true
    } catch (_: Throwable) {
        bindFailed.set(true)
        false
      }
    }

    private fun check(source: String, id: Int, reply: Messenger, token: AtomicBoolean) {
        var status = "error"
        var code = "ENGINE_ERROR"
        var elapsed = 0L
        var startAttempted = false
        try {
            network = physicalNetwork()
            val selected = network
            if (selected == null) {
                code = "NO_NETWORK"
                return
            }
            if (token.get()) return
            val port = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
            val config = ProfileProbeConfig.build(source, port)
            bindFailed.set(false)
            LibXray.touch()
            LibXray.registerDialerController(this)
            val dns = connectivity.getLinkProperties(selected)?.dnsServers?.firstOrNull()?.hostAddress
            if (dns == null) {
                code = "NO_NETWORK_DNS"
                return
            }
            LibXray.setDNS(this, AndroidDnsEndpoint.format(dns))
            startAttempted = true
            api.start(config, filesDir.absolutePath)
            check(api.isRunning())
            val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port))
            status = "unavailable"
            code = "HTTPS_FAILED"
            for (endpoint in ENDPOINTS) {
                if (token.get()) break
                val begin = SystemClock.elapsedRealtime()
                try {
                    val request = URL(endpoint).openConnection(proxy) as HttpsURLConnection
                    connection = request
                    request.connectTimeout = 3500
                    request.readTimeout = 3500
                    request.instanceFollowRedirects = false
                    request.useCaches = false
                    request.setRequestProperty("Connection", "close")
                    // Android's default trust manager and hostname verifier stay enabled.
                    if (ProfileProbeConfig.accepts(request.responseCode)) {
                        elapsed = SystemClock.elapsedRealtime() - begin
                        status = "available"
                        code = "HTTPS_OK"
                        break
                    }
                    code = "HTTP_RESPONSE"
                } catch (_: SocketTimeoutException) {
                    code = "TIMEOUT"
                } catch (_: Exception) {
                    code = "HTTPS_FAILED"
                } finally {
                    runCatching { connection?.disconnect() }
                    connection = null
                }
            }
            if (physicalNetwork() != selected) {
                status = "error"
                code = "NETWORK_CHANGED"
            } else if (bindFailed.get()) {
                status = "error"
                code = "NETWORK_BIND_FAILED"
            }
        } catch (_: Throwable) {
            // Never forward raw core exceptions: they can contain credentials.
        } finally {
            if (startAttempted) runCatching { api.stop() }
            runCatching { LibXray.resetDNS() }
            network = null
            main.post {
                busy = false
                send(reply, id, if (token.get()) "cancelled" else status, code, elapsed)
            }
        }
    }

    private fun send(reply: Messenger, id: Int, status: String, code: String, elapsed: Long) {
        runCatching {
            reply.send(Message.obtain(null, CHECK, id, 0).apply {
                data = Bundle().apply {
                    putString("status", status)
                    putString("code", code)
                    putLong("elapsedMs", elapsed)
                }
            })
        }
    }

    override fun onDestroy() {
        cancel()
        super.onDestroy()
    }

    companion object {
        // LibXray is process-global, including across service recreation.
        private val executor = Executors.newSingleThreadExecutor()
        const val CHECK = 1
        const val CANCEL = 2
        private val ENDPOINTS = listOf(
            "https://www.gstatic.com/generate_204",
            "https://cp.cloudflare.com/generate_204",
        )
    }
}
