package com.neuravpn.app

import android.app.Application
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import androidx.core.content.getSystemService
import go.Seq
import libbox.Libbox
import libbox.SetupOptions
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Configures the sing-box Libbox runtime once per process so VpnService can bind immediately.
 */
class HappycatVpnApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        Seq.setContext(this)
        Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
        initializeOnce()
    }

    private fun initializeOnce() {
        if (!libboxInitialized.compareAndSet(false, true)) return
        backgroundExecutor.execute {
            val baseDir = File(filesDir, "libbox_base").apply { mkdirs() }
            val workingDir = File(getExternalFilesDir(null) ?: filesDir, "libbox_work").apply { mkdirs() }
            val tempDir = File(cacheDir, "libbox_temp").apply { mkdirs() }

            val options = SetupOptions().also {
                it.basePath = baseDir.absolutePath
                it.workingPath = workingDir.absolutePath
                it.tempPath = tempDir.absolutePath
                it.username = "android"
                it.fixAndroidStack = true
            }

            try {
                Libbox.setup(options)
                Libbox.redirectStderr(File(workingDir, "libbox_stderr.log").absolutePath)
            } catch (t: Throwable) {
                // Libbox.setup throws if directories cannot be created; surface via logcat and keep app usable.
                t.printStackTrace()
            }
        }
    }

    companion object {
        private val backgroundExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "libbox-init").apply { isDaemon = true }
        }
        private val libboxInitialized = AtomicBoolean(false)

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
