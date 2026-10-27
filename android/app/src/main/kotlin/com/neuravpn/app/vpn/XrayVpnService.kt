package com.neuravpn.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.LinkProperties
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.system.Os
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.neuravpn.app.MainActivity
import com.neuravpn.app.R
import libXray.DialerController
import libXray.LibXray
import java.io.File
import org.json.JSONObject
import java.util.ArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.UUID

class XrayVpnService : VpnService(), DialerController {
    private val executor get() = runtimeExecutor
    @Volatile
    private var xrayCoreStarted = false
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var includePackages: List<String> = emptyList()
    private var excludePackages: List<String> = emptyList()
    private val connectivity by lazy {
        getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile
    private var currentUnderlyingNetwork: Network? = null
    private var systemDnsEndpoint: String? = null
    private var statsScheduler: ScheduledExecutorService? = null
    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile
    private var activeSessionId: String? = null
    private var activeRoutingMode: String? = null
    private val startInProgress = AtomicBoolean(false)
    private val destroyed = AtomicBoolean(false)
    private var lastStartId = 0
    private val stopWatchdog = AndroidVpnStopWatchdog()
    private var diagnostics: AndroidXrayDiagnostics? = null
    private val xrayApi = AndroidXrayApi()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        debugLog("service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        when (intent?.action) {
            ACTION_REFRESH_NETWORK -> {
                debugLog("ACTION_REFRESH_NETWORK received")
                executor.execute { refreshUnderlyingNetwork() }
                return START_STICKY
            }
            ACTION_STOP -> {
                if (activeSessionId == null) {
                    activeSessionId = AndroidVpnRuntimeStateStore.read(applicationContext).sessionId
                }
                if (!stopInProgress.compareAndSet(false, true)) {
                    debugLog("ACTION_STOP ignored: stop already in progress")
                    Log.i(TAG, "ACTION_STOP ignored: stop already in progress")
                    return START_NOT_STICKY
                }
                armEmergencyStop()
                executor.execute {
                    try {
                        debugLog("ACTION_STOP received")
                        Log.i(TAG, "ACTION_STOP received")
                        stopRuntime()
                        debugLog("ACTION_STOP completed")
                        Log.i(TAG, "ACTION_STOP completed")
                    } finally {
                        stopInProgress.set(false)
                    }
                }
                return START_NOT_STICKY
            }
        }

        // Always-on and START_STICKY restarts do not carry the Flutter payload.
        val saved = if (intent == null || intent.action == SERVICE_INTERFACE) {
            AndroidVpnConfigStore.read(applicationContext)
        } else null
        val config = intent?.getStringExtra(EXTRA_CONFIG) ?: saved?.optString("config")
        val executablePath = intent?.getStringExtra(EXTRA_EXECUTABLE_PATH)
            ?: saved?.optString("executablePath")
        val sessionId = intent?.getStringExtra(EXTRA_SESSION_ID) ?: UUID.randomUUID().toString()
        val routingMode = intent?.getStringExtra(EXTRA_ROUTING_MODE) ?: saved?.optString("routingMode")
        if (stopInProgress.get() || destroyed.get()) return START_NOT_STICKY
        if (runningState.get() && runtimeOwner === this) {
            AndroidVpnRuntimeStateStore.markRunning(
                applicationContext,
                XrayAndroidRuntime.id,
                activeSessionId ?: sessionId,
                activeRoutingMode,
            )
            debugLog("start ignored: VPN is already running")
            return START_STICKY
        }
        if (!startInProgress.compareAndSet(false, true)) {
            debugLog("start ignored: startup is already in progress")
            return START_STICKY
        }
        activeSessionId = sessionId
        activeRoutingMode = routingMode
        includePackages = intent?.getStringArrayListExtra(EXTRA_INCLUDE_PACKAGES)
            ?: saved?.stringList("includePackages") ?: emptyList()
        excludePackages = intent?.getStringArrayListExtra(EXTRA_EXCLUDE_PACKAGES)
            ?: saved?.stringList("excludePackages") ?: emptyList()
        if (config.isNullOrBlank()) {
            failStartup("INVALID_CONFIG", "Missing Xray config payload")
            return START_NOT_STICKY
        }

        AndroidVpnRuntimeStateStore.markStarting(
            applicationContext,
            XrayAndroidRuntime.id,
            sessionId,
            routingMode,
            ownerPid = Process.myPid(),
        )

        debugLog(
            "start requested include=${includePackages.size} exclude=${excludePackages.size} " +
                "exec=${!executablePath.isNullOrBlank()}"
        )

        try {
            startForeground(NOTIFICATION_ID, buildNotification("Starting Android Xray runtime"))
        } catch (_: Exception) {
            failStartup("FOREGROUND_SERVICE_FAILED", "Android could not start the VPN notification.")
            return START_NOT_STICKY
        }
        executor.execute {
            if (startupCancelled()) return@execute
            try {
            runtimeOwner?.takeIf { it !== this }?.stopRuntime(preserveError = true)
            runtimeOwner = this
            val runtimeFile = executablePath?.let(::File)
            if (runtimeFile == null || !runtimeFile.exists()) {
                failStartup("XRAY_DATA_MISSING", "Android Xray data directory is unavailable")
                return@execute
            }

            val datDir = if (runtimeFile.isDirectory) {
                runtimeFile.absolutePath
            } else {
                runtimeFile.parentFile?.absolutePath
            }
            if (datDir.isNullOrBlank()) {
                failStartup("XRAY_DATA_MISSING", "Android Xray data directory is missing")
                return@execute
            }
            val geoDataReady = File(datDir, "geoip.dat").exists() && File(datDir, "geosite.dat").exists()
            if (!geoDataReady) {
                failStartup("XRAY_DATA_MISSING", "Android Xray geo data is incomplete")
                return@execute
            }
            debugLog("runtime data ready; configBytes=${config.toByteArray().size}")

            // --- Phase 1: Bootstrap libXray and start Xray core BEFORE TUN ---
            // Starting Xray first avoids a DNS loop: if we establish TUN first,
            // all DNS queries route into the tunnel but there is no proxy yet.
            try {
                LibXray.touch()
                LibXray.registerDialerController(this)
                currentUnderlyingNetwork = selectBestUnderlyingNetwork()
                updateSystemDns()
                val versionText = xrayApi.version()
                debugLog("libXray bootstrap ok version=$versionText")
                Log.i(TAG, "libXray loaded: $versionText")
            } catch (t: Throwable) {
                failStartup("XRAY_BOOTSTRAP_FAILED", "libXray bootstrap failed: ${t.message}")
                return@execute
            }

            runCatching {
                val runtimeConfig = AndroidXrayDiagnostics(applicationContext).let {
                    diagnostics = it
                    it.configure(config)
                }
                debugLog("calling runXrayFromJson...")
                xrayApi.start(runtimeConfig, datDir)
                xrayCoreStarted = true
            }.getOrElse { t ->
                failStartup("XRAY_CONFIG_REJECTED", "Xray rejected the generated configuration: ${t.message}")
                return@execute
            }
            if (!xrayApi.isRunning()) {
                failStartup(
                    "XRAY_START_FAILED",
                    "libXray did not enter the running state",
                )
                return@execute
            }
            if (startupCancelled()) return@execute
            debugLog("libXray core started, xrayState=true")
            Log.i(TAG, "Android Xray core started via libXray")

            // --- Phase 2: Establish TUN now that Xray SOCKS5 is listening ---
            val tun = runCatching { establishTun() }.getOrElse { error ->
                stopXrayCore()
                failStartup("TUN_ESTABLISH_FAILED", "Failed to establish Android VPN tunnel: ${error.message}")
                return@execute
            }
            debugLog("tun established fd=${tun.fd}")
            if (startupCancelled()) return@execute

            // --- Phase 3: Bridge TUN ↔ SOCKS5 ---
            try {
                AndroidTun2SocksBridge.start(
                    context = applicationContext,
                    vpnInterface = tun,
                    mtu = TUN_MTU,
                    socksPort = LOCAL_SOCKS_PORT,
                    ipv4Client = TUN_IPV4_CLIENT,
                    ipv6Client = TUN_IPV6_CLIENT,
                )
                debugLog("tun2socks started socks=127.0.0.1:$LOCAL_SOCKS_PORT")
            } catch (t: Throwable) {
                stopXrayCore()
                closeTun()
                failStartup("TUN2SOCKS_START_FAILED", "Failed to start tun2socks bridge: ${t.message}")
                return@execute
            }

            if (startupCancelled()) return@execute
            runningState.set(true)
            startInProgress.set(false)
            AndroidVpnRuntimeStateStore.markRunning(
                applicationContext,
                XrayAndroidRuntime.id,
                sessionId,
                routingMode,
            )
            saveLastConfig(
                applicationContext,
                config,
                executablePath,
                includePackages,
                excludePackages,
                routingMode,
            )
            acquireWakeLock()
            startStatsWriter()
            updateNotification("Connected")
            } catch (_: Throwable) {
                failStartup("VPN_START_FAILED", "Android could not finish starting the VPN. Connect again.")
                return@execute
            }
            debugLog("android xray vpn connected")
            Log.i(TAG, "Android Xray VPN connected")
        }
        return START_STICKY
    }

    override fun onDestroy() {
        debugLog("service destroyed")
        destroyed.set(true)
        armEmergencyStop()
        // Native start/stop must run on the same worker, including destruction.
        executor.execute {
            stopRuntime(requestStopSelf = false, preserveError = true)
            stopInProgress.set(false)
        }
        super.onDestroy()
    }

    override fun onRevoke() {
        debugLog("vpn permission revoked")
        stopInProgress.set(true)
        armEmergencyStop()
        executor.execute {
            stopRuntime(
                errorCode = "VPN_PERMISSION_REVOKED",
                errorMessage = "VPN permission was revoked by Android",
            )
        }
        super.onRevoke()
    }

    private fun failStartup(code: String, message: String) {
        val safeMessage = AndroidVpnLogSanitizer.redact(message)
        debugLog("startup failure [$code]: $safeMessage")
        Log.e(TAG, "startup failure: $code")
        AndroidVpnRuntimeStateStore.markError(
            applicationContext,
            XrayAndroidRuntime.id,
            activeSessionId,
            code,
            safeMessage,
            activeRoutingMode,
        )
        runningState.set(false)
        startInProgress.set(false)
        updateNotification(safeMessage)
        stopSelfResult(lastStartId)
    }

    private fun startupCancelled(): Boolean = destroyed.get() || stopInProgress.get()

    private fun armEmergencyStop() {
        val sessionId = activeSessionId ?: return
        stopWatchdog.arm(
            stillStopping = {
                runtimeOwner === this && activeSessionId == sessionId &&
                    (destroyed.get() || stopInProgress.get())
            },
            onTimeout = {
                runCatching {
                    AndroidVpnRuntimeStateStore.markError(
                        applicationContext, XrayAndroidRuntime.id, sessionId,
                        "VPN_STOP_TIMEOUT", "VPN runtime did not stop. Connect again.",
                        activeRoutingMode,
                    )
                    debugLog("emergency stop: native runtime exceeded the stop deadline")
                }
                // This service runs in :xray_vpn, never in the Flutter process.
                // Only a stuck native stop reaches this fallback.
                Process.killProcess(Process.myPid())
            },
        )
    }

    private fun stopRuntime(
        errorCode: String? = null,
        errorMessage: String? = null,
        requestStopSelf: Boolean = true,
        preserveError: Boolean = false,
    ) {
        debugLog(
            "stop runtime requestStopSelf=$requestStopSelf " +
                "errorCode=${errorCode ?: "-"}"
        )
        startInProgress.set(false)
        // onDestroy may arrive after a new Service instance owns the native core.
        // A second cleanup from the old instance must not stop that session.
        if (runtimeOwner === this) {
            releaseWakeLock()
            stopStatsWriter()
            stopUnderlyingNetworkMonitor()
            stopTun2Socks()
            stopXrayCore()
            closeTun()
            runningState.set(false)
            runtimeOwner = null
        }
        if (activeSessionId != null && errorCode != null && errorMessage != null) {
            AndroidVpnRuntimeStateStore.markError(
                applicationContext,
                XrayAndroidRuntime.id,
                activeSessionId,
                errorCode,
                errorMessage,
                activeRoutingMode,
            )
        } else if (activeSessionId != null) {
            AndroidVpnRuntimeStateStore.markStopped(
                applicationContext, XrayAndroidRuntime.id, preserveError = preserveError,
                sessionId = activeSessionId,
            )
        }
        if (requestStopSelf) {
            stopSelfResult(lastStartId)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            runCatching {
                val notificationManager =
                    getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                notificationManager.cancel(NOTIFICATION_ID)
            }
        }
        stopWatchdog.cancel()
        activeSessionId = null
        activeRoutingMode = null
    }

    private fun stopXrayCore() {
        if (xrayCoreStarted) {
            debugLog("stopping libXray core")
            runCatching { xrayApi.stop() }
        }
        runCatching { LibXray.resetDNS() }
        diagnostics?.close()
        diagnostics = null
        systemDnsEndpoint = null
        xrayCoreStarted = false
    }

    private fun stopTun2Socks() {
        debugLog("stopping tun2socks")
        runCatching { AndroidTun2SocksBridge.stop() }
    }

    private fun closeTun() {
        runCatching { tunDescriptor?.close() }
        debugLog("closing tun fd")
        tunDescriptor = null
    }

    private fun startStatsWriter() {
        stopStatsWriter()
        val ctx = applicationContext
        val sessionId = activeSessionId ?: return
        statsScheduler = Executors.newSingleThreadScheduledExecutor().also { sched ->
            sched.scheduleAtFixedRate({
                runCatching {
                    val raw = AndroidTun2SocksBridge.getStats()
                    if (raw != null && raw.size >= 4) {
                        // native array: [tx_packets, tx_bytes, rx_packets, rx_bytes]
                        val tx = raw[1]
                        val rx = raw[3]
                        val json = JSONObject().apply {
                            put("sessionId", sessionId)
                            put("tx", tx)
                            put("rx", rx)
                        }
                        val target = File(ctx.filesDir, STATS_FILE_NAME)
                        val temp = File.createTempFile("vpn-stats-", ".tmp", ctx.filesDir)
                        try {
                            temp.writeText(json.toString(), Charsets.UTF_8)
                            Os.rename(temp.path, target.path)
                        } finally {
                            temp.delete()
                        }
                    }
                }
            }, 500, 500, TimeUnit.MILLISECONDS)
        }
    }

    private fun stopStatsWriter() {
        statsScheduler?.shutdownNow()
        statsScheduler = null
    }

    private fun updateNotification(text: String) {
        runCatching {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            notificationManager.notify(NOTIFICATION_ID, buildNotification(text))
        }
    }

    private fun buildNotification(text: String): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("neuravpn")
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "neuravpn VPN",
            android.app.NotificationManager.IMPORTANCE_LOW,
        )
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        manager.createNotificationChannel(channel)
    }

    override fun protectFd(fd: Long): Boolean {
        val ok = protect(fd.toInt())
        if (!ok) {
            debugLog("protectFd failed fd=$fd")
        }
        if (!ok) return false
        val network = currentUnderlyingNetwork ?: return true
        return runCatching {
            ParcelFileDescriptor.fromFd(fd.toInt()).use { duplicate ->
                network.bindSocket(duplicate.fileDescriptor)
            }
            true
        }.getOrElse { error ->
            debugLog("socket network binding failed: ${error.javaClass.simpleName}: ${error.message}")
            false
        }
    }

    private fun establishTun(): ParcelFileDescriptor {
        val builder = Builder()
            .setSession("neuravpn")
            .setMtu(TUN_MTU)

        builder.addAddress(TUN_IPV4_CLIENT, TUN_IPV4_PREFIX)
        builder.addRoute("0.0.0.0", 0)
        // Apps send DNS to this virtual peer. tun2socks forwards port 53 to
        // Xray's DNS outbound. Public resolution uses DoH; smart-routing
        // exceptions and server bootstrap may use the physical network's DNS.
        builder.addDnsServer(TUN_DNS_IPV4)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.addAddress(TUN_IPV6_CLIENT, TUN_IPV6_PREFIX)
            builder.addRoute("::", 0)
        }

        applyPackageRules(builder)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        selectBestUnderlyingNetwork()?.let { network ->
            currentUnderlyingNetwork = network
            builder.setUnderlyingNetworks(arrayOf(network))
        }

        closeTun()
        return checkNotNull(builder.establish()) { "VpnService.Builder.establish() returned null" }
            .also {
                tunDescriptor = it
                startUnderlyingNetworkMonitor()
            }
    }

    private fun applyPackageRules(builder: Builder) {
        includePackages.forEach { pkg ->
            runCatching { builder.addAllowedApplication(pkg) }
                .onFailure { Log.w(TAG, "Failed to allow package $pkg", it) }
        }

        if (includePackages.isEmpty()) {
            excludePackages.forEach { pkg ->
                runCatching { builder.addDisallowedApplication(pkg) }
                    .onFailure { Log.w(TAG, "Failed to disallow package $pkg", it) }
            }
            if (!excludePackages.contains(packageName)) {
                runCatching { builder.addDisallowedApplication(packageName) }
                    .onFailure { Log.w(TAG, "Unable to exclude self from VPN", it) }
            }
        }
    }

    private fun startUnderlyingNetworkMonitor() {
        if (defaultNetworkCallback != null) {
            return
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            private fun refresh() {
                if (!executor.isShutdown) {
                    runCatching { executor.execute { refreshPreferredUnderlyingNetwork() } }
                }
            }
            override fun onAvailable(network: Network) {
                refresh()
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                if (networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) {
                    refresh()
                }
            }

            override fun onLost(network: Network) {
                refresh()
            }

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = refresh()
        }
        runCatching {
            connectivity.registerNetworkCallback(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .build(),
                callback,
            )
            defaultNetworkCallback = callback
        }.onFailure {
            Log.w(TAG, "Failed to register underlying network callback", it)
        }
    }

    private fun stopUnderlyingNetworkMonitor() {
        val callback = defaultNetworkCallback ?: return
        runCatching {
            connectivity.unregisterNetworkCallback(callback)
        }.onFailure {
            Log.w(TAG, "Failed to unregister underlying network callback", it)
        }
        defaultNetworkCallback = null
        currentUnderlyingNetwork = null
        runCatching { setUnderlyingNetworks(null) }
    }

    private fun refreshPreferredUnderlyingNetwork() {
        if (startupCancelled() || tunDescriptor == null) return
        val preferred = selectBestUnderlyingNetwork()
        if (preferred != currentUnderlyingNetwork) {
            currentUnderlyingNetwork = preferred
            runCatching { setUnderlyingNetworks(preferred?.let { arrayOf(it) } ?: emptyArray()) }
        }
        if (preferred != null && xrayCoreStarted) {
            runCatching { updateSystemDns() }
        }
    }

    private fun selectBestUnderlyingNetwork(): Network? {
        val active = connectivity.activeNetwork
        if (active != null) {
            val caps = connectivity.getNetworkCapabilities(active)
            if (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) return active
        }
        return connectivity.allNetworks
            .mapNotNull { network ->
                val caps = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
                if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                    !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                ) return@mapNotNull null
                network to networkPreferenceScore(caps)
            }
            .maxByOrNull { it.second }
            ?.first
    }

    private fun networkPreferenceScore(caps: NetworkCapabilities): Int {
        var score = 0
        if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) score += 100
        if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) score += 20
        score += when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 30
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 20
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 10
            else -> 0
        }
        return score
    }

    private fun resolveSystemDnsServer(): String {
        val network = selectBestUnderlyingNetwork()
        val dns = network?.let { connectivity.getLinkProperties(it) }?.dnsServers?.firstOrNull()
        return AndroidDnsEndpoint.format(dns?.hostAddress ?: "1.1.1.1")
    }

    private fun updateSystemDns() {
        val endpoint = resolveSystemDnsServer()
        if (endpoint == systemDnsEndpoint) return
        LibXray.setDNS(this, endpoint)
        systemDnsEndpoint = endpoint
    }

    private fun refreshUnderlyingNetwork() {
        startUnderlyingNetworkMonitor()
        refreshPreferredUnderlyingNetwork()
    }

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "neuravpn:vpn").apply {
            setReferenceCounted(false)
            acquire()
        }
        debugLog("WakeLock acquired")
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
            debugLog("WakeLock released")
        }
        wakeLock = null
    }

    companion object {
        // One queue across Service recreation: libXray is process-global.
        private val runtimeExecutor = Executors.newSingleThreadExecutor()
        @Volatile
        private var runtimeOwner: XrayVpnService? = null
        private const val TAG = "XrayVpnService"
        private const val CHANNEL_ID = "neuravpn_vpn"
        private const val NOTIFICATION_ID = 38
        private const val LOCAL_SOCKS_PORT = 10808
        private const val TUN_MTU = 1280
        private const val TUN_IPV4_CLIENT = "172.19.0.1"
        private const val TUN_DNS_IPV4 = "172.19.0.2"
        private const val TUN_IPV4_PREFIX = 30
        private const val TUN_IPV6_CLIENT = "fdfe:dcba:9876::1"
        private const val TUN_IPV6_PREFIX = 126
        const val ACTION_STOP = "com.neuravpn.app.vpn.ACTION_STOP_XRAY"
        const val ACTION_REFRESH_NETWORK = "com.neuravpn.app.vpn.ACTION_REFRESH_NETWORK"
        const val EXTRA_CONFIG = "com.neuravpn.app.vpn.EXTRA_CONFIG"
        const val EXTRA_EXECUTABLE_PATH = "com.neuravpn.app.vpn.EXTRA_EXECUTABLE_PATH"
        const val EXTRA_INCLUDE_PACKAGES = "com.neuravpn.app.vpn.EXTRA_INCLUDE_PACKAGES"
        const val EXTRA_EXCLUDE_PACKAGES = "com.neuravpn.app.vpn.EXTRA_EXCLUDE_PACKAGES"
        const val EXTRA_SESSION_ID = "com.neuravpn.app.vpn.EXTRA_SESSION_ID"
        const val EXTRA_ROUTING_MODE = "com.neuravpn.app.vpn.EXTRA_ROUTING_MODE"

        fun saveLastConfig(
            context: Context,
            config: String,
            executablePath: String?,
            includePackages: List<String>?,
            excludePackages: List<String>?,
            routingMode: String?,
        ) {
            runCatching {
                val json = JSONObject()
                json.put("config", config)
                if (!executablePath.isNullOrBlank()) json.put("executablePath", executablePath)
                if (!includePackages.isNullOrEmpty()) {
                    json.put("includePackages", org.json.JSONArray(includePackages))
                }
                if (!excludePackages.isNullOrEmpty()) {
                    json.put("excludePackages", org.json.JSONArray(excludePackages))
                }
                if (!routingMode.isNullOrBlank()) json.put("routingMode", routingMode)
                AndroidVpnConfigStore.save(context, json)
            }
        }

        private val runningState = AtomicBoolean(false)
        private val stopInProgress = AtomicBoolean(false)
        fun isRunning(): Boolean = runningState.get() || stopInProgress.get()

        fun start(
            context: Context,
            config: String,
            executablePath: String?,
            includePackages: List<String>?,
            excludePackages: List<String>?,
            routingMode: String?,
        ) {
            val sessionId = UUID.randomUUID().toString()
            if (!AndroidVpnRuntimeStateStore.requestStart(
                context,
                XrayAndroidRuntime.id,
                sessionId,
                routingMode,
            )) return
            val intent = Intent(context, XrayVpnService::class.java).apply {
                putExtra(EXTRA_CONFIG, config)
                if (!executablePath.isNullOrBlank()) {
                    putExtra(EXTRA_EXECUTABLE_PATH, executablePath)
                }
                if (!includePackages.isNullOrEmpty()) {
                    putStringArrayListExtra(EXTRA_INCLUDE_PACKAGES, ArrayList(includePackages))
                }
                if (!excludePackages.isNullOrEmpty()) {
                    putStringArrayListExtra(EXTRA_EXCLUDE_PACKAGES, ArrayList(excludePackages))
                }
                putExtra(EXTRA_SESSION_ID, sessionId)
                if (!routingMode.isNullOrBlank()) putExtra(EXTRA_ROUTING_MODE, routingMode)
            }
            // Do NOT pre-mark running here. The service process will set
            // running=true only after Xray core + TUN are fully operational.
            // Pre-marking caused the Flutter side to believe the service was
            // up even when it crashed during startup.
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (error: Exception) {
                AndroidVpnRuntimeStateStore.markError(context, XrayAndroidRuntime.id, sessionId,
                    "START_VPN_FAILED", "Android could not start the VPN service.", routingMode)
                throw error
            }
        }

        private const val STATS_FILE_NAME = "neuravpn_traffic_stats.json"

        fun readTrafficStats(context: Context): LongArray? {
            return runCatching {
                val state = AndroidVpnRuntimeStateStore.read(context)
                if (!state.isRunning) return null
                val file = File(context.filesDir, STATS_FILE_NAME)
                if (!file.exists()) return null
                val json = JSONObject(file.readText())
                if (json.optString("sessionId") != state.sessionId) return null
                longArrayOf(json.getLong("tx"), json.getLong("rx"))
            }.getOrNull()
        }

        fun stop(context: Context) {
            AndroidVpnRuntimeStateStore.markStopping(context, XrayAndroidRuntime.id)
            val stopIntent = Intent(context, XrayVpnService::class.java).apply {
                action = ACTION_STOP
            }
            val dispatched = runCatching { context.startService(stopIntent) }.getOrNull() != null
            if (!dispatched) {
                Log.w(TAG, "Failed to dispatch ACTION_STOP, trying stopService fallback")
                AndroidVpnDebugLogStore.append(context, TAG, "failed to dispatch ACTION_STOP, using stopService")
                runCatching { context.stopService(Intent(context, XrayVpnService::class.java)) }
            }
        }

        fun refreshNetwork(context: Context) {
            if (!AndroidVpnRuntimeStateStore.isMarkedRunning(context)) return
            val intent = Intent(context, XrayVpnService::class.java).apply {
                action = ACTION_REFRESH_NETWORK
            }
            runCatching { context.startService(intent) }
        }
    }

    private fun debugLog(message: String) {
        AndroidVpnDebugLogStore.append(applicationContext, TAG, message)
    }

    private fun JSONObject.stringList(key: String): List<String> = optJSONArray(key)?.let { array ->
        (0 until array.length()).map { array.getString(it) }
    } ?: emptyList()
}
