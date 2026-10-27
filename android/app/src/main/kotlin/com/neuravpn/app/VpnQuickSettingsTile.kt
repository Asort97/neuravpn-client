package com.neuravpn.app

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.neuravpn.app.vpn.AndroidVpnRuntimeStateStore
import com.neuravpn.app.vpn.AndroidVpnPhase
import com.neuravpn.app.vpn.AndroidVpnConfigStore
import com.neuravpn.app.vpn.XrayVpnService

class VpnQuickSettingsTile : TileService() {
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = object : Runnable {
        override fun run() {
            updateTileState()
            handler.postDelayed(this, 500)
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        handler.removeCallbacks(refresh)
        handler.post(refresh)
    }

    override fun onStopListening() {
        handler.removeCallbacks(refresh)
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        val snapshot = AndroidVpnRuntimeStateStore.read(applicationContext)
        if (snapshot.isActive) {
            XrayVpnService.stop(applicationContext)
            updateTile(active = false, subtitle = "Отключение...")
        } else {
            if (runCatching { startVpnFromLastConfig() }.getOrDefault(false)) {
                updateTile(active = true, subtitle = "Подключение...")
            } else {
                launchApp()
            }
        }
    }

    private fun startVpnFromLastConfig(): Boolean {
        // Check if VPN permission is granted (prepare() returns null when granted)
        val prepareIntent = VpnService.prepare(applicationContext)
        if (prepareIntent != null) return false // Need user to grant permission via app

        val saved = AndroidVpnConfigStore.read(applicationContext) ?: return false
        val config = saved.optString("config", "")
        if (config.isBlank()) return false

        val executablePath = if (saved.has("executablePath")) saved.optString("executablePath") else null
        val includePackages = saved.optJSONArray("includePackages")?.let { arr ->
            (0 until arr.length()).map { arr.getString(it) }
        }
        val excludePackages = saved.optJSONArray("excludePackages")?.let { arr ->
            (0 until arr.length()).map { arr.getString(it) }
        }
        val routingMode = saved.optString("routingMode").takeIf { it.isNotBlank() }

        XrayVpnService.start(
            context = applicationContext,
            config = config,
            executablePath = executablePath,
            includePackages = includePackages,
            excludePackages = excludePackages,
            routingMode = routingMode,
        )
        return true
    }

    private fun launchApp() {
        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    applicationContext, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun updateTileState() {
        val phase = AndroidVpnRuntimeStateStore.read(applicationContext).phase
        updateTile(
            active = phase == AndroidVpnPhase.RUNNING,
            subtitle = when (phase) {
                AndroidVpnPhase.STARTING -> "Подключение..."
                AndroidVpnPhase.RUNNING -> "Подключено"
                AndroidVpnPhase.STOPPING -> "Отключение..."
                AndroidVpnPhase.ERROR -> "Ошибка"
                AndroidVpnPhase.STOPPED -> "Отключено"
            },
        )
    }

    private fun updateTile(active: Boolean, subtitle: String) {
        val tile = qsTile ?: return
        tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "NeuraVPN"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) tile.subtitle = subtitle
        tile.contentDescription = "NeuraVPN: $subtitle"
        tile.icon = Icon.createWithResource(
            this,
            if (active) R.drawable.ic_tile_connected else R.drawable.ic_tile_disconnected,
        )
        tile.updateTile()
    }
}
