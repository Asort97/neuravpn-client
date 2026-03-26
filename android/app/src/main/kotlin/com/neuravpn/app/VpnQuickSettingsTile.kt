package com.neuravpn.app

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.neuravpn.app.vpn.AndroidVpnRuntimeStateStore
import com.neuravpn.app.vpn.XrayVpnService
import org.json.JSONObject
import java.io.File

class VpnQuickSettingsTile : TileService() {

    companion object {
        const val LAST_CONFIG_FILE = "neuravpn_last_config.json"
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()
        val isRunning = AndroidVpnRuntimeStateStore.isMarkedRunning(applicationContext)
        if (isRunning) {
            XrayVpnService.stop(applicationContext)
            updateTile(active = false, subtitle = "Отключение...")
        } else {
            if (startVpnFromLastConfig()) {
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

        val file = File(applicationContext.filesDir, LAST_CONFIG_FILE)
        if (!file.exists()) return false

        val saved = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return false
        val config = saved.optString("config", "")
        if (config.isBlank()) return false

        val executablePath = if (saved.has("executablePath")) saved.optString("executablePath") else null
        val includePackages = saved.optJSONArray("includePackages")?.let { arr ->
            (0 until arr.length()).map { arr.getString(it) }
        }
        val excludePackages = saved.optJSONArray("excludePackages")?.let { arr ->
            (0 until arr.length()).map { arr.getString(it) }
        }

        XrayVpnService.start(
            context = applicationContext,
            config = config,
            executablePath = executablePath,
            includePackages = includePackages,
            excludePackages = excludePackages,
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
        val isRunning = AndroidVpnRuntimeStateStore.isMarkedRunning(applicationContext)
        updateTile(
            active = isRunning,
            subtitle = if (isRunning) "Подключено" else "Отключено",
        )
    }

    private fun updateTile(active: Boolean, subtitle: String) {
        val tile = qsTile ?: return
        tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "NeuraVPN"
        tile.subtitle = subtitle
        tile.icon = Icon.createWithResource(
            this,
            if (active) R.drawable.ic_tile_connected else R.drawable.ic_tile_disconnected,
        )
        tile.updateTile()
    }
}
