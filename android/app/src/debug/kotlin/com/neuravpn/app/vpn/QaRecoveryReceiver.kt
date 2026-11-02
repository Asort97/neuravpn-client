package com.neuravpn.app.vpn

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.util.Log
import com.neuravpn.app.BuildConfig
import java.util.concurrent.atomic.AtomicBoolean
import android.util.Base64
import org.json.JSONObject

/** ADB-only device checks. Never packaged in release or enabled for the Play app. */
class QaRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!BuildConfig.DEBUG || context.packageName != "com.neuravpn.app.qa") return
        val saved = AndroidVpnConfigStore.read(context) ?: return
        runCatching {
            intent.getStringExtra("outbound")?.let { encoded ->
                val replacement = JSONObject(String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8))
                    .getJSONArray("outbounds").getJSONObject(0)
                val config = JSONObject(saved.getString("config"))
                val outbounds = config.getJSONArray("outbounds")
                replacement.put("tag", outbounds.getJSONObject(0).getString("tag"))
                outbounds.put(0, replacement)
                saved.put("config", config.toString())
            }
        }.onFailure {
            Log.w("NeuraQA", "Invalid QA outbound")
            return
        }
        if (intent.action == "neuravpn.qa.START") {
            intent.getStringExtra("profileUri")?.let { encoded ->
                val uri = String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8)
                context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    .edit().putString("flutter.vpn_profile_selected_uri", uri)
                    .putString("flutter.vless_uri", uri)
                    .putString("flutter.vpn_profile_selected", android.net.Uri.parse(uri).fragment)
                    .apply()
            }
        }
        when (intent.action) {
            "neuravpn.qa.START" -> XrayVpnService.start(
                context, saved.getString("config"), saved.optString("executablePath"),
                saved.optJSONArray("includePackages")?.let { a -> (0 until a.length()).map(a::getString) },
                saved.optJSONArray("excludePackages")?.let { a -> (0 until a.length()).map(a::getString) },
                saved.optString("routingMode"),
            )
            "neuravpn.qa.PROBE" -> {
                val pending = goAsync()
                val requestConfig = JSONObject(saved.getString("config"))
                val app = context.applicationContext
                val main = Handler(Looper.getMainLooper())
                val finished = AtomicBoolean(false)
                var bound = false
                lateinit var connection: ServiceConnection
                fun finish(status: String) {
                    if (!finished.compareAndSet(false, true)) return
                    Log.i("NeuraQA", status)
                    if (bound) app.unbindService(connection)
                    pending.finish()
                }
                val reply = Messenger(Handler(Looper.getMainLooper()) { response ->
                    val data = response.data
                    finish("cold probe: ${data.getString("status")} ${data.getString("code")} " +
                        "${data.getLong("elapsedMs")}ms")
                    true
                })
                connection = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                        runCatching {
                            Messenger(binder).send(Message.obtain(null, ProfileProbeService.CHECK, 1, 0).apply {
                                replyTo = reply
                                data = Bundle().apply { putString("config", requestConfig.toString()) }
                            })
                        }.onFailure { finish("cold probe dispatch failed") }
                    }
                    override fun onServiceDisconnected(name: ComponentName) = finish("cold probe disconnected")
                }
                bound = app.bindService(Intent(app, ProfileProbeService::class.java), connection, Context.BIND_AUTO_CREATE)
                if (!bound) finish("cold probe bind failed")
                else main.postDelayed({ finish("cold probe timed out") }, 20000)
            }
        }
    }
}
