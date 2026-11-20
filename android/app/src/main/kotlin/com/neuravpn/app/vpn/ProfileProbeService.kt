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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

// Explicitly bound, private process. Never establishes a TUN or changes VPN state.
// VpnService is used only to protect this UID's probe sockets from its active VPN.
//
// One check = one Xray core holding every server of the request. Each server gets
// its own local HTTP inbound routed only to it, and the HTTPS requests run in
// parallel, so a 40-server subscription takes seconds instead of minutes.
class ProfileProbeService : VpnService(), DialerController {
    private val worker get() = executor
    private val main = Handler(Looper.getMainLooper())
    private val api = AndroidXrayApi()
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    @Volatile private var network: Network? = null
    private val connections = ConcurrentHashMap.newKeySet<HttpsURLConnection>()
    @Volatile private var cancelled = AtomicBoolean(false)
    private val bindFailed = AtomicBoolean(false)
    private var busy = false
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        when (message.what) {
            CHECK -> {
                val reply = message.replyTo ?: return@Handler true
                val id = message.arg1
                if (busy) {
                    sendDone(reply, id, "error", "BUSY")
                } else {
                    busy = true
                    val token = AtomicBoolean(false)
                    cancelled = token
                    val targets = message.data.getString("targets").orEmpty()
                    worker.execute { check(targets, id, reply, token) }
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
        val pending = connections.toList()
        if (pending.isNotEmpty()) Thread { pending.forEach { runCatching { it.disconnect() } } }.start()
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
        var doneStatus = "error"
        var doneCode = "ENGINE_ERROR"
        var coreStarted = false
        val pool = Executors.newFixedThreadPool(PARALLEL)
        try {
            val (targets, rejected) = ProfileProbeConfig.parseTargets(source)
            for (target in rejected) sendResult(reply, id, target, "error", "INVALID_CONFIG", 0)
            if (targets.isEmpty()) {
                doneStatus = "done"
                doneCode = ""
                return
            }
            network = physicalNetwork()
            val selected = network
            if (selected == null) {
                doneCode = "NO_NETWORK"
                return
            }
            if (token.get()) return
            val dns = connectivity.getLinkProperties(selected)?.dnsServers?.firstOrNull()?.hostAddress
            if (dns == null) {
                doneCode = "NO_NETWORK_DNS"
                return
            }
            bindFailed.set(false)
            LibXray.touch()
            socketProtector.activate(this, ::protectFd)
            LibXray.setDNS(this, AndroidDnsEndpoint.format(dns))

            val ports = freePorts(targets.size)
            coreStarted = true
            val batchRunning = runCatching {
                api.start(ProfileProbeConfig.build(targets, ports), filesDir.absolutePath)
                api.isRunning()
            }.getOrDefault(false)
            if (batchRunning) {
                targets.forEachIndexed { index, target ->
                    pool.execute {
                        val (status, code, elapsed) = probe(ports[index], token)
                        if (!token.get()) sendResult(reply, id, target.id, status, code, elapsed)
                    }
                }
                pool.shutdown()
                pool.awaitTermination(BATCH_LIMIT_SECONDS, TimeUnit.SECONDS)
            } else {
                // One server the core rejects must not hide the others: retry alone.
                runCatching { api.stop() }
                for (target in targets) {
                    if (token.get()) break
                    val port = freePorts(1)
                    val (status, code, elapsed) = try {
                        api.start(ProfileProbeConfig.build(listOf(target), port), filesDir.absolutePath)
                        check(api.isRunning())
                        probe(port[0], token)
                    } catch (_: Throwable) {
                        Triple("error", "ENGINE_ERROR", 0L)
                    } finally {
                        runCatching { api.stop() }
                    }
                    if (!token.get()) sendResult(reply, id, target.id, status, code, elapsed)
                }
            }
            doneStatus = "done"
            doneCode = ""
            if (physicalNetwork() != selected) {
                doneStatus = "error"
                doneCode = "NETWORK_CHANGED"
            } else if (bindFailed.get()) {
                doneStatus = "error"
                doneCode = "NETWORK_BIND_FAILED"
            }
        } catch (_: Throwable) {
            // Never forward raw core exceptions: they can contain credentials.
        } finally {
            pool.shutdownNow()
            if (coreStarted) runCatching { api.stop() }
            runCatching { LibXray.resetDNS() }
            socketProtector.deactivate(this)
            network = null
            val status = if (token.get()) "cancelled" else doneStatus
            main.post {
                busy = false
                sendDone(reply, id, status, doneCode)
            }
        }
    }

    /** Real HTTPS through one server. Only 204 from a known endpoint counts. */
    private fun probe(port: Int, token: AtomicBoolean): Triple<String, String, Long> {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port))
        var code = "HTTPS_FAILED"
        for (endpoint in ENDPOINTS) {
            if (token.get()) return Triple("cancelled", "CANCELLED", 0L)
            val begin = SystemClock.elapsedRealtime()
            var request: HttpsURLConnection? = null
            try {
                request = URL(endpoint).openConnection(proxy) as HttpsURLConnection
                connections.add(request)
                request.connectTimeout = TIMEOUT_MS
                request.readTimeout = TIMEOUT_MS
                request.instanceFollowRedirects = false
                request.useCaches = false
                request.setRequestProperty("Connection", "close")
                // Android's default trust manager and hostname verifier stay enabled.
                if (ProfileProbeConfig.accepts(request.responseCode)) {
                    return Triple("available", "HTTPS_OK", SystemClock.elapsedRealtime() - begin)
                }
                code = "HTTP_RESPONSE"
            } catch (_: SocketTimeoutException) {
                // A server too slow for one endpoint is too slow; do not double the wait.
                code = "TIMEOUT"
                break
            } catch (_: Exception) {
                code = "HTTPS_FAILED"
            } finally {
                if (request != null) {
                    connections.remove(request)
                    runCatching { request.disconnect() }
                }
            }
        }
        return Triple("unavailable", code, 0L)
    }

    /** Holds every socket open until all are allocated so no port repeats. */
    private fun freePorts(count: Int): IntArray {
        val loopback = InetAddress.getByName("127.0.0.1")
        val sockets = ArrayList<ServerSocket>(count)
        try {
            repeat(count) { sockets.add(ServerSocket(0, 1, loopback)) }
            return IntArray(count) { sockets[it].localPort }
        } finally {
            sockets.forEach { runCatching { it.close() } }
        }
    }

    private fun sendResult(reply: Messenger, id: Int, target: String, status: String, code: String, elapsed: Long) {
        runCatching {
            reply.send(Message.obtain(null, RESULT, id, 0).apply {
                data = Bundle().apply {
                    putString("id", target)
                    putString("status", status)
                    putString("code", code)
                    putLong("elapsedMs", elapsed)
                }
            })
        }
    }

    private fun sendDone(reply: Messenger, id: Int, status: String, code: String) {
        runCatching {
            reply.send(Message.obtain(null, CHECK, id, 0).apply {
                data = Bundle().apply {
                    putString("status", status)
                    putString("code", code)
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
        private val socketProtector = AndroidXraySocketProtector { callback ->
            LibXray.registerDialerController(object : DialerController {
                override fun protectFd(fd: Long) = callback(fd)
            })
        }
        const val CHECK = 1
        const val CANCEL = 2
        const val RESULT = 3
        private const val PARALLEL = 10
        private const val TIMEOUT_MS = 5000
        private const val BATCH_LIMIT_SECONDS = 170L
        private val ENDPOINTS = listOf(
            "https://www.gstatic.com/generate_204",
            "https://cp.cloudflare.com/generate_204",
        )
    }
}
