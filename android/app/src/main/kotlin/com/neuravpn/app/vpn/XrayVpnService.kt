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
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.os.Build
import android.os.Process
import android.util.Base64
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

class XrayVpnService : VpnService(), DialerController {
    private val executor = Executors.newSingleThreadExecutor()
    @Volatile
    private var xrayCoreStarted = false
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var includePackages: List<String> = emptyList()
    private var excludePackages: List<String> = emptyList()
    private val connectivity by lazy {
        getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var statsScheduler: ScheduledExecutorService? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        debugLog("service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                if (!stopInProgress.compareAndSet(false, true)) {
                    debugLog("ACTION_STOP ignored: stop already in progress")
                    Log.i(TAG, "ACTION_STOP ignored: stop already in progress")
                    return START_NOT_STICKY
                }
                executor.execute {
                    try {
                        debugLog("ACTION_STOP received")
                        Log.i(TAG, "ACTION_STOP received")
                        stopRuntime("stopped by request")
                        debugLog("ACTION_STOP completed")
                        Log.i(TAG, "ACTION_STOP completed")
                    } finally {
                        stopInProgress.set(false)
                    }
                }
                return START_NOT_STICKY
            }
        }

        // If a stop is in progress on the executor, signal it to skip
        // Process.killProcess() so that our start-task (queued right after)
        // can still execute in the same process.
        if (stopInProgress.get()) {
            skipProcessKill.set(true)
            debugLog("start received while stop in progress – will skip process kill")
        }

        val config = intent?.getStringExtra(EXTRA_CONFIG)
        val executablePath = intent?.getStringExtra(EXTRA_EXECUTABLE_PATH)
        includePackages = intent?.getStringArrayListExtra(EXTRA_INCLUDE_PACKAGES) ?: emptyList()
        excludePackages = intent?.getStringArrayListExtra(EXTRA_EXCLUDE_PACKAGES) ?: emptyList()
        if (config.isNullOrBlank()) {
            failStartup("Missing Xray config payload")
            return START_NOT_STICKY
        }

        debugLog(
            "start requested include=${includePackages.size} exclude=${excludePackages.size} " +
                "exec=${!executablePath.isNullOrBlank()}"
        )

        startForeground(NOTIFICATION_ID, buildNotification("Starting Android Xray runtime"))
        executor.execute {
            val executableFile = executablePath?.let(::File)
            if (executableFile == null || !executableFile.exists()) {
                failStartup("Android Xray binary is not bundled or not found: path=$executablePath")
                return@execute
            }

            val datDir = executableFile.parentFile?.absolutePath
            if (datDir.isNullOrBlank()) {
                failStartup("Android Xray dat dir is missing")
                return@execute
            }
            debugLog("xray executable=${executableFile.absolutePath}")
            debugLog("xray datDir=$datDir")

            // Log datDir contents so we can verify geoip.dat / geosite.dat are present
            val datDirFiles = runCatching {
                File(datDir).listFiles()?.joinToString { "${it.name}(${it.length()})" } ?: "<empty>"
            }.getOrDefault("<error listing>")
            debugLog("datDir contents: $datDirFiles")

            // Log config length and first 800 chars for debugging
            debugLog("config length=${config.length}")
            debugLog("config preview=${config.take(800)}")

            // --- Phase 1: Bootstrap libXray and start Xray core BEFORE TUN ---
            // Starting Xray first avoids a DNS loop: if we establish TUN first,
            // all DNS queries route into the tunnel but there is no proxy yet.
            try {
                LibXray.touch()
                LibXray.registerDialerController(this)
                LibXray.initDns(this, "1.1.1.1:53")
                val version = decodeCallResponse(LibXray.xrayVersion())
                val versionText = version?.optString("data").orEmpty()
                debugLog("libXray bootstrap ok version=$versionText")
                Log.i(TAG, "libXray loaded: $versionText")
            } catch (t: Throwable) {
                failStartup("libXray bootstrap failed: ${t.message}")
                return@execute
            }

            val startResponse = runCatching {
                val request = LibXray.newXrayRunFromJSONRequest(datDir, "", config)
                debugLog("calling runXrayFromJSON...")
                val raw = LibXray.runXrayFromJSON(request)
                debugLog("runXrayFromJSON returned ${raw?.length ?: 0} chars")
                decodeCallResponse(raw)
            }.getOrElse { t ->
                failStartup("runXrayFromJSON exception: ${t.javaClass.simpleName}: ${t.message}")
                return@execute
            }
            debugLog("runXrayFromJSON response: ${startResponse?.toString()?.take(500)}")
            if (startResponse?.optBoolean("success") != true || !LibXray.getXrayState()) {
                val error = startResponse?.optString("error")
                failStartup(
                    if (!error.isNullOrBlank()) {
                        "libXray failed to start: $error"
                    } else {
                        "libXray failed to start Android Xray core (state=${LibXray.getXrayState()})"
                    },
                )
                return@execute
            }
            xrayCoreStarted = true
            debugLog("libXray core started, xrayState=${LibXray.getXrayState()}")
            Log.i(TAG, "Android Xray core started via libXray")

            // --- Phase 2: Establish TUN now that Xray SOCKS5 is listening ---
            val tun = runCatching { establishTun() }.getOrElse { error ->
                stopXrayCore()
                failStartup("Failed to establish Android VPN tunnel: ${error.message}")
                return@execute
            }
            debugLog("tun established fd=${tun.fd}")

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
                failStartup("Failed to start tun2socks bridge: ${t.message}")
                return@execute
            }

            runningState.set(true)
            AndroidVpnRuntimeStateStore.markRunning(applicationContext, XrayAndroidRuntime.id)
            saveLastConfig(applicationContext, config, executablePath, includePackages, excludePackages)
            startStatsWriter()
            updateNotification("Connected")
            debugLog("android xray vpn connected")
            Log.i(TAG, "Android Xray VPN connected")
        }
        return START_STICKY
    }

    override fun onDestroy() {
        debugLog("service destroyed")
        stopRuntime(null, requestStopSelf = false)
        stopInProgress.set(false)
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onRevoke() {
        debugLog("vpn permission revoked")
        stopRuntime("VPN permission revoked")
        super.onRevoke()
    }

    private fun failStartup(message: String) {
        debugLog("startup failure: $message")
        Log.e(TAG, message)
        AndroidVpnRuntimeStateStore.markStopped(applicationContext, XrayAndroidRuntime.id, message)
        runningState.set(false)
        updateNotification(message)
        stopSelf()
    }

    private fun stopRuntime(error: String?, requestStopSelf: Boolean = true) {
        val shouldTerminate = requestStopSelf && !skipProcessKill.getAndSet(false)
        debugLog(
            "stop runtime requestStopSelf=$requestStopSelf shouldTerminate=$shouldTerminate " +
                "error=${error ?: "-"}"
        )
        runningState.set(false)
        stopStatsWriter()
        AndroidVpnRuntimeStateStore.markStopped(applicationContext, XrayAndroidRuntime.id, error)
        if (shouldTerminate) {
            stopSelf()
        }
        stopUnderlyingNetworkMonitor()
        stopTun2Socks()
        stopXrayCore()
        closeTun()
        if (shouldTerminate) {
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
            debugLog("killing isolated xray process")
            Log.i(TAG, "Killing isolated Xray VPN process")
            Process.killProcess(Process.myPid())
        } else {
            debugLog("skip process kill – restart pending")
        }
    }

    private fun stopXrayCore() {
        if (!xrayCoreStarted) return
        debugLog("stopping libXray core")
        runCatching { LibXray.stopXray() }
        runCatching { LibXray.resetDns() }
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
        statsScheduler = Executors.newSingleThreadScheduledExecutor().also { sched ->
            sched.scheduleAtFixedRate({
                runCatching {
                    val raw = AndroidTun2SocksBridge.getStats()
                    if (raw != null && raw.size >= 4) {
                        // native array: [tx_packets, tx_bytes, rx_packets, rx_bytes]
                        val tx = raw[1]
                        val rx = raw[3]
                        val json = JSONObject().apply {
                            put("tx", tx)
                            put("rx", rx)
                        }
                        File(ctx.filesDir, STATS_FILE_NAME).writeText(json.toString())
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
        return ok
    }

    private fun decodeCallResponse(encoded: String?): JSONObject? {
        if (encoded.isNullOrBlank()) return null
        return runCatching {
            val decoded = Base64.decode(encoded, Base64.DEFAULT)
            JSONObject(String(decoded, Charsets.UTF_8))
        }.getOrNull()
    }

    private fun establishTun(): ParcelFileDescriptor {
        val builder = Builder()
            .setSession("neuravpn")
            .setMtu(TUN_MTU)

        builder.addAddress(TUN_IPV4_CLIENT, TUN_IPV4_PREFIX)
        builder.addRoute("0.0.0.0", 0)
        builder.addDnsServer("1.1.1.1")
        builder.addDnsServer("8.8.8.8")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.addAddress(TUN_IPV6_CLIENT, TUN_IPV6_PREFIX)
            builder.addRoute("::", 0)
        }

        applyPackageRules(builder)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || defaultNetworkCallback != null) {
            return
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                setUnderlyingNetworks(arrayOf(network))
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                setUnderlyingNetworks(arrayOf(network))
            }

            override fun onLost(network: Network) {
                setUnderlyingNetworks(null)
            }
        }
        runCatching {
            connectivity.requestNetwork(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
                    .build(),
                callback,
            )
            defaultNetworkCallback = callback
        }.onFailure {
            Log.w(TAG, "Failed to register underlying network callback", it)
        }
    }

    private fun stopUnderlyingNetworkMonitor() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return
        }
        val callback = defaultNetworkCallback ?: return
        runCatching {
            connectivity.unregisterNetworkCallback(callback)
        }.onFailure {
            Log.w(TAG, "Failed to unregister underlying network callback", it)
        }
        defaultNetworkCallback = null
        runCatching { setUnderlyingNetworks(null) }
    }

    companion object {
        private const val TAG = "XrayVpnService"
        private const val CHANNEL_ID = "neuravpn_vpn"
        private const val NOTIFICATION_ID = 38
        private const val LOCAL_SOCKS_PORT = 10808
        private const val TUN_MTU = 1280
        private const val TUN_IPV4_CLIENT = "172.19.0.1"
        private const val TUN_IPV4_PREFIX = 30
        private const val TUN_IPV6_CLIENT = "fdfe:dcba:9876::1"
        private const val TUN_IPV6_PREFIX = 126
        const val ACTION_STOP = "com.neuravpn.app.vpn.ACTION_STOP_XRAY"
        const val EXTRA_CONFIG = "com.neuravpn.app.vpn.EXTRA_CONFIG"
        const val EXTRA_EXECUTABLE_PATH = "com.neuravpn.app.vpn.EXTRA_EXECUTABLE_PATH"
        const val EXTRA_INCLUDE_PACKAGES = "com.neuravpn.app.vpn.EXTRA_INCLUDE_PACKAGES"
        const val EXTRA_EXCLUDE_PACKAGES = "com.neuravpn.app.vpn.EXTRA_EXCLUDE_PACKAGES"
        private const val LAST_CONFIG_FILE = "neuravpn_last_config.json"

        fun saveLastConfig(
            context: Context,
            config: String,
            executablePath: String?,
            includePackages: List<String>?,
            excludePackages: List<String>?,
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
                File(context.filesDir, LAST_CONFIG_FILE).writeText(json.toString())
            }
        }

        private val runningState = AtomicBoolean(false)
        private val stopInProgress = AtomicBoolean(false)
        /**
         * Set to true when a START intent arrives while a STOP is still in
         * progress on the executor.  When the executor's stop-task sees this
         * flag it skips [Process.killProcess] so the queued start-task can
         * run afterwards on the same process.
         */
        private val skipProcessKill = AtomicBoolean(false)

        fun isRunning(): Boolean = runningState.get() || stopInProgress.get()

        fun start(
            context: Context,
            config: String,
            executablePath: String?,
            includePackages: List<String>?,
            excludePackages: List<String>?,
        ) {
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
            }
            // Do NOT pre-mark running here. The service process will set
            // running=true only after Xray core + TUN are fully operational.
            // Pre-marking caused the Flutter side to believe the service was
            // up even when it crashed during startup.
            ContextCompat.startForegroundService(context, intent)
        }

        private const val STATS_FILE_NAME = "neuravpn_traffic_stats.json"

        fun readTrafficStats(context: Context): LongArray? {
            return runCatching {
                val file = File(context.filesDir, STATS_FILE_NAME)
                if (!file.exists()) return null
                val json = JSONObject(file.readText())
                longArrayOf(json.getLong("tx"), json.getLong("rx"))
            }.getOrNull()
        }

        fun stop(context: Context) {
            AndroidVpnRuntimeStateStore.markStopped(context, XrayAndroidRuntime.id)
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
    }

    private fun debugLog(message: String) {
        AndroidVpnDebugLogStore.append(applicationContext, TAG, message)
    }
}
