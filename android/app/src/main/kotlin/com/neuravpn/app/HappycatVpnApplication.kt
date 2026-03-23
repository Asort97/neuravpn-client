package com.neuravpn.app

import android.app.Application
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import androidx.core.content.getSystemService
import com.neuravpn.app.vpn.AndroidVpnRuntimeManager

/**
 * Configures the selected Android VPN runtime once per process.
 */
class HappycatVpnApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        AndroidVpnRuntimeManager.bootstrap(this)
    }

    companion object {
        lateinit var instance: HappycatVpnApplication
            private set

        val connectivity: ConnectivityManager by lazy {
            instance.getSystemService() ?: throw IllegalStateException("ConnectivityManager unavailable")
        }

        val wifi: WifiManager by lazy {
            instance.getSystemService() ?: throw IllegalStateException("WifiManager unavailable")
        }

        val notifications: NotificationManager by lazy {
            instance.getSystemService() ?: throw IllegalStateException("NotificationManager unavailable")
        }

        val clipboard: ClipboardManager by lazy {
            instance.getSystemService() ?: throw IllegalStateException("ClipboardManager unavailable")
        }

        val power: PowerManager by lazy {
            instance.getSystemService() ?: throw IllegalStateException("PowerManager unavailable")
        }
    }
}
