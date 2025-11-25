package com.example.happycat_vpnclient.vpn

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.IpPrefix
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.TaskStackBuilder
import androidx.core.content.ContextCompat
import com.example.happycat_vpnclient.HappycatVpnApplication
import com.example.happycat_vpnclient.MainActivity
import libbox.BoxService
import libbox.InterfaceUpdateListener
import libbox.Libbox
import libbox.LocalDNSTransport
import libbox.NetworkInterfaceIterator
import libbox.PlatformInterface
import libbox.RoutePrefix
import libbox.StringIterator
import libbox.TunOptions
import libbox.WIFIState
import java.io.IOException
import java.net.InetAddress
import java.net.NetworkInterface
import java.security.KeyStore
import java.util.ArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground VPN service that drives the sing-box Libbox runtime on Android.
 */
class LibboxVpnService : VpnService(), PlatformInterface {

    private val executor = Executors.newSingleThreadExecutor()
    private var libboxService: BoxService? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var interfaceListener: InterfaceUpdateListener? = null
    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var manualIncludePackages: List<String> = emptyList()
    private var manualExcludePackages: List<String> = emptyList()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }

        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrBlank()) {
            Log.w(TAG, "Missing config payload – ignoring start request")
            return START_NOT_STICKY
        }

        manualIncludePackages = intent.getStringArrayListExtra(EXTRA_INCLUDE_PACKAGES) ?: emptyList()
        manualExcludePackages = intent.getStringArrayListExtra(EXTRA_EXCLUDE_PACKAGES) ?: emptyList()

        startForeground(NOTIFICATION_ID, buildNotification(getStatusLabel()))
        executor.execute { startLibbox(config) }
        return START_STICKY
    }

    override fun onDestroy() {
        executor.execute { stopLibbox() }
        executor.shutdownNow()
        runningState.set(false)
        super.onDestroy()
    }

    private fun startLibbox(config: String) {
        try {
            stopLibbox()
            val service = Libbox.newService(config, this)
            service.start()
            libboxService = service
            runningState.set(true)
            updateNotification(getStringLabel("Connected"))
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to start Libbox", t)
            runningState.set(false)
            updateNotification(getStringLabel("Error: ${t.message}"))
            stopSelf()
        }
    }

    private fun stopLibbox() {
        try {
            tunDescriptor?.close()
        } catch (_: IOException) {
        }
        tunDescriptor = null
        libboxService?.runCatching { close() }
        libboxService = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        runningState.set(false)
        stopSelf()
    }

    // region PlatformInterface implementation

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = false

    override fun autoDetectInterfaceControl(fd: Int) {
        // No-op because usePlatformAutoDetectInterfaceControl returns false.
    }

    override fun openTun(options: TunOptions): Int {
        val pendingIntent = VpnService.prepare(this)
        check(pendingIntent == null) { "VPN permission not granted" }

        val builder = Builder()
            .setSession(getStringLabel("Happycat VPN"))
            .setMtu(options.mtu)

        var hasIpv4Address = false
        val ipv4 = options.inet4Address
        while (ipv4.hasNext()) {
            val address = ipv4.next()
            builder.addAddress(address.address(), address.prefix())
            hasIpv4Address = true
        }

        var hasIpv6Address = false
        val ipv6 = options.inet6Address
        while (ipv6.hasNext()) {
            val address = ipv6.next()
            builder.addAddress(address.address(), address.prefix())
            hasIpv6Address = true
        }

        applyDnsServers(builder, options)

        applyRoutes(builder, options, hasIpv4Address, hasIpv6Address)
        applyPackageRules(builder, options)
        applySystemProxy(builder, options)

        val pfd = builder.establish() ?: error("Failed to establish VpnService")
        tunDescriptor = pfd
        return pfd.fd
    }

    override fun writeLog(message: String) {
        Log.d(TAG, message)
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): Int {
        throw UnsupportedOperationException("findConnectionOwner is not implemented yet")
    }

    override fun packageNameByUid(uid: Int): String {
        val packages = packageManager.getPackagesForUid(uid)
        if (packages.isNullOrEmpty()) error("Package not found for uid=$uid")
        return packages.first()
    }

    override fun uidByPackageName(packageName: String): Int {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageUid(packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageUid(packageName, 0)
            }
        } catch (notFound: PackageManager.NameNotFoundException) {
            error("Package $packageName not installed")
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        interfaceListener = listener
        val connectivity = HappycatVpnApplication.connectivity
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                notifyDefaultInterface(listener, connectivity, network)
            }

            override fun onLost(network: Network) {
                notifyDefaultInterface(listener, connectivity, null)
            }

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                notifyDefaultInterface(listener, connectivity, network)
            }

            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                notifyDefaultInterface(listener, connectivity, network)
            }
        }
        defaultNetworkCallback = callback
        try {
            connectivity.registerDefaultNetworkCallback(callback)
            notifyDefaultInterface(listener, connectivity, connectivity.activeNetwork)
        } catch (t: Throwable) {
            Log.w(TAG, "Unable to monitor default network", t)
            listener.updateDefaultInterface("", -1, false, false)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        if (interfaceListener !== listener) return
        interfaceListener = null
        defaultNetworkCallback?.let {
            try {
                HappycatVpnApplication.connectivity.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        defaultNetworkCallback = null
    }

    private fun notifyDefaultInterface(
        listener: InterfaceUpdateListener,
        connectivity: ConnectivityManager,
        network: Network?,
    ) {
        val linkProperties = network?.let { connectivity.getLinkProperties(it) }
        val interfaceName = linkProperties?.interfaceName.orEmpty()
        val interfaceIndex = interfaceName.takeIf { it.isNotEmpty() }?.let {
            runCatching { NetworkInterface.getByName(it)?.index }.getOrNull()
        } ?: -1
        val capabilities = network?.let { connectivity.getNetworkCapabilities(it) }
        val isUp = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        val isMetered = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true
        listener.updateDefaultInterface(interfaceName, interfaceIndex, isUp, isMetered)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val enumeration = NetworkInterface.getNetworkInterfaces() ?: return EmptyNetworkIterator
        val interfaces = java.util.Collections.list(enumeration).mapNotNull { iface ->
            runCatching {
                libbox.NetworkInterface().also {
                    it.name = iface.name
                    it.index = iface.index
                    it.mtu = runCatching { iface.mtu }.getOrDefault(DEFAULT_MTU)
                    it.flags = toInterfaceFlags(iface)
                    it.addresses = SimpleStringIterator(collectInterfaceAddresses(iface))
                }
            }.getOrNull()
        }
        if (interfaces.isEmpty()) return EmptyNetworkIterator
        return SimpleNetworkIterator(interfaces)
    }

    private fun collectInterfaceAddresses(iface: NetworkInterface): List<String> {
        val result = mutableListOf<String>()
        try {
            val interfaceAddresses = iface.interfaceAddresses
            if (interfaceAddresses.isNotEmpty()) {
                interfaceAddresses.forEach { address ->
                    val host = address.address?.hostAddress?.substringBefore('%') ?: return@forEach
                    val prefix = address.networkPrefixLength.toInt()
                    if (prefix in 0..128) {
                        result.add("$host/$prefix")
                    } else {
                        result.add(host)
                    }
                }
            } else {
                val fallback = iface.inetAddresses
                while (fallback.hasMoreElements()) {
                    val host = fallback.nextElement().hostAddress?.substringBefore('%') ?: continue
                    result.add(host)
                }
            }
        } catch (_: Exception) {
        }
        return result
    }

    private fun toInterfaceFlags(iface: NetworkInterface): Int {
        var flags = 0
        if (runCatching { iface.isUp }.getOrDefault(false)) flags = flags or IFF_UP
        if (runCatching { iface.isLoopback }.getOrDefault(false)) flags = flags or IFF_LOOPBACK
        if (runCatching { iface.isPointToPoint }.getOrDefault(false)) flags = flags or IFF_POINTTOPOINT
        if (runCatching { iface.supportsMulticast() }.getOrDefault(false)) flags = flags or IFF_MULTICAST
        if ((flags and IFF_POINTTOPOINT) == 0 && (flags and IFF_LOOPBACK) == 0) {
            flags = flags or IFF_BROADCAST
        }
        return flags
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {
        // Android does not expose a public DNS cache API; ignoring keeps behavior aligned with platform defaults.
    }

    override fun readWIFIState(): WIFIState? {
        if (!hasPermission(Manifest.permission.ACCESS_WIFI_STATE)) return null
        val info = try {
            HappycatVpnApplication.wifi.connectionInfo
        } catch (security: SecurityException) {
            Log.w(TAG, "Unable to read Wi-Fi state", security)
            null
        } ?: return null
        var ssid = info.ssid ?: return null
        if (ssid == "<unknown ssid>") return null
        ssid = ssid.trim('"')
        return WIFIState(ssid, info.bssid ?: "")
    }

    override fun systemCertificates(): StringIterator {
        val certificates = mutableListOf<String>()
        try {
            val store = KeyStore.getInstance("AndroidCAStore")
            store.load(null)
            val aliases = store.aliases()
            while (aliases.hasMoreElements()) {
                val certificate = store.getCertificate(aliases.nextElement())
                certificates.add(
                    buildString {
                        appendLine("-----BEGIN CERTIFICATE-----")
                        append(android.util.Base64.encodeToString(certificate.encoded, android.util.Base64.NO_WRAP))
                        appendLine()
                        append("-----END CERTIFICATE-----")
                    },
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Unable to enumerate system certificates", t)
        }
        return SimpleStringIterator(certificates)
    }

    override fun sendNotification(notification: libbox.Notification) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = notification.identifier.ifBlank { CHANNEL_ID }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                notification.typeName.ifBlank { "sing-box alerts" },
                NotificationManager.IMPORTANCE_HIGH,
            )
            manager.createNotificationChannel(channel)
        }

        val builder = NotificationCompat.Builder(this, channelId)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setAutoCancel(true)

        if (!notification.openURL.isNullOrBlank()) {
            val tapIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_DEEPLINK, notification.openURL)
            }
            val pendingIntent = TaskStackBuilder.create(this)
                .addNextIntentWithParentStack(tapIntent)
                .getPendingIntent(notification.typeID, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.setContentIntent(pendingIntent)
        }

        manager.notify(notification.typeID, builder.build())
    }

    // endregion PlatformInterface implementation

    private fun applyRoutes(builder: Builder, options: TunOptions, hasIpv4Address: Boolean, hasIpv6Address: Boolean) {
        val ipv4Routes = options.inet4RouteAddress
        var addedIpv4 = false
        while (ipv4Routes.hasNext()) {
            builder.addRoute(toPrefix(ipv4Routes.next()))
            addedIpv4 = true
        }
        if (!addedIpv4 && options.autoRoute && hasIpv4Address) {
            builder.addRoute("0.0.0.0", 0)
        }

        val ipv6Routes = options.inet6RouteAddress
        var addedIpv6 = false
        while (ipv6Routes.hasNext()) {
            builder.addRoute(toPrefix(ipv6Routes.next()))
            addedIpv6 = true
        }
        if (!addedIpv6 && options.autoRoute && hasIpv6Address) {
            builder.addRoute("::", 0)
        }
    }

    private fun applyDnsServers(builder: Builder, options: TunOptions) {
        val configured = runCatching { options.dnsServerAddress }.getOrNull()
        val configuredValue = configured?.value?.takeIf { it.isNotBlank() }
        var addedAny = false
        val isVirtualTunDns = configuredValue?.startsWith(TUN_SUBNET_PREFIX) == true

        if (configuredValue != null && !isVirtualTunDns) {
            runCatching { builder.addDnsServer(configuredValue) }
                .onSuccess { addedAny = true }
                .onFailure { Log.w(TAG, "Unable to apply DNS server $configuredValue", it) }
        }

        if (!addedAny && isVirtualTunDns) {
            Log.d(TAG, "Ignoring virtual DNS $configuredValue, using fallback servers")
        }

        val needsFallback = !addedAny
        if (!needsFallback || !options.autoRoute) return

        for (server in FALLBACK_DNS) {
            runCatching { builder.addDnsServer(server) }
                .onSuccess { addedAny = true }
                .onFailure { Log.w(TAG, "Unable to apply fallback DNS $server", it) }
        }
        if (!addedAny) {
            Log.w(TAG, "VPN started without any DNS servers; traffic likely fails")
        }
    }

    private fun applyPackageRules(builder: Builder, options: TunOptions) {
        val includePackages = collectIterator(options.includePackage).toMutableSet()
        val excludePackages = collectIterator(options.excludePackage).toMutableSet()

        includePackages.addAll(manualIncludePackages)
        excludePackages.addAll(manualExcludePackages)

        includePackages.forEach { pkg ->
            runCatching { builder.addAllowedApplication(pkg) }
                .onFailure { Log.w(TAG, "Failed to allow package $pkg", it) }
        }

        if (includePackages.isEmpty()) {
            excludePackages.forEach { pkg ->
                runCatching { builder.addDisallowedApplication(pkg) }
                    .onFailure { Log.w(TAG, "Failed to disallow package $pkg", it) }
            }
        }

        val shouldExcludeSelf = includePackages.isEmpty() && !excludePackages.contains(packageName)
        if (shouldExcludeSelf) {
            runCatching { builder.addDisallowedApplication(packageName) }
                .onFailure { Log.w(TAG, "Unable to exclude self from VPN", it) }
        }
    }

    private fun collectIterator(iterator: StringIterator): List<String> {
        val items = mutableListOf<String>()
        while (iterator.hasNext()) {
            items.add(iterator.next())
        }
        return items
    }

    private fun applySystemProxy(builder: Builder, options: TunOptions) {
        if (!options.isHTTPProxyEnabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val bypass = mutableListOf<String>()
        val iterator = options.httpProxyBypassDomain
        while (iterator.hasNext()) {
            bypass.add(iterator.next())
        }
        builder.setHttpProxy(ProxyInfo.buildDirectProxy(options.httpProxyServer, options.httpProxyServerPort, bypass))
    }

    private fun toPrefix(prefix: RoutePrefix): IpPrefix {
        return IpPrefix(InetAddress.getByName(prefix.address()), prefix.prefix())
    }

    private fun buildNotification(state: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getStringLabel("Happycat VPN"))
            .setContentText(state)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setOngoing(true)
            .setContentIntent(mainPendingIntent())
            .build()
    }

    private fun updateNotification(state: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(state))
    }

    private fun mainPendingIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(CHANNEL_ID, "Happycat VPN", NotificationManager.IMPORTANCE_LOW)
        manager.createNotificationChannel(channel)
    }

    private fun getStringLabel(fallback: String): String {
        val labelRes = applicationInfo.labelRes
        return if (labelRes != 0) getString(labelRes) else fallback
    }

    private fun getStatusLabel(): String = if (runningState.get()) "Connected" else "Connecting"

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
    }

    companion object {
        private const val TAG = "LibboxVpnService"
        private const val CHANNEL_ID = "happycat_vpn"
        private const val NOTIFICATION_ID = 37
        private const val DEFAULT_MTU = 1500
        private const val IFF_UP = 0x1
        private const val IFF_BROADCAST = 0x2
        private const val IFF_LOOPBACK = 0x8
        private const val IFF_POINTTOPOINT = 0x10
        private const val IFF_MULTICAST = 0x1000
        private const val TUN_SUBNET_PREFIX = "172.19.0."
        private val FALLBACK_DNS = listOf("1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4")
        private val runningState = AtomicBoolean(false)
        const val ACTION_STOP = "com.example.happycat_vpnclient.vpn.ACTION_STOP"
        const val EXTRA_CONFIG = "com.example.happycat_vpnclient.vpn.EXTRA_CONFIG"
        const val EXTRA_DEEPLINK = "com.example.happycat_vpnclient.vpn.EXTRA_DEEPLINK"
        const val EXTRA_INCLUDE_PACKAGES = "com.example.happycat_vpnclient.vpn.EXTRA_INCLUDE_PACKAGES"
        const val EXTRA_EXCLUDE_PACKAGES = "com.example.happycat_vpnclient.vpn.EXTRA_EXCLUDE_PACKAGES"

        fun isRunning(): Boolean = runningState.get()

        fun start(
            context: Context,
            config: String,
            includePackages: List<String>?,
            excludePackages: List<String>?,
        ) {
            val intent = Intent(context, LibboxVpnService::class.java).apply {
                putExtra(EXTRA_CONFIG, config)
                if (!includePackages.isNullOrEmpty()) {
                    putStringArrayListExtra(EXTRA_INCLUDE_PACKAGES, ArrayList(includePackages))
                }
                if (!excludePackages.isNullOrEmpty()) {
                    putStringArrayListExtra(EXTRA_EXCLUDE_PACKAGES, ArrayList(excludePackages))
                }
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LibboxVpnService::class.java))
        }
    }
}

private object EmptyNetworkIterator : NetworkInterfaceIterator {
    override fun hasNext(): Boolean = false

    override fun next(): libbox.NetworkInterface {
        throw NoSuchElementException("No network interfaces available")
    }
}

private class SimpleNetworkIterator(
    private val items: List<libbox.NetworkInterface>,
) : NetworkInterfaceIterator {
    private var index = 0

    override fun hasNext(): Boolean = index < items.size

    override fun next(): libbox.NetworkInterface {
        if (!hasNext()) throw NoSuchElementException("No more network interfaces")
        return items[index++]
    }
}

private class SimpleStringIterator(
    private val items: List<String>,
) : StringIterator {
    private var index = 0

    override fun len(): Int = items.size

    override fun hasNext(): Boolean = index < items.size

    override fun next(): String {
        if (!hasNext()) throw NoSuchElementException("No more entries")
        return items[index++]
    }
}