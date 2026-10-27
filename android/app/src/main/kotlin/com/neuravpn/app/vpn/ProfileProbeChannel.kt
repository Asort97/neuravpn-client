package com.neuravpn.app.vpn

import android.content.*
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class ProfileProbeChannel(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "neuravpn/profile_probe")
    private val main = Handler(Looper.getMainLooper())
    private var remote: Messenger? = null
    private var binding: ServiceConnection? = null
    private var pending: MethodChannel.Result? = null
    private var payload: String? = null
    private var requestId = 0
    private val timeout = Runnable {
        sendCancel()
        finish(mapOf("status" to "error", "code" to "WORKER_TIMEOUT"))
        unbind()
    }
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.arg1 == requestId) {
            finish(mapOf(
                "status" to message.data.getString("status"),
                "code" to message.data.getString("code"),
                "elapsedMs" to message.data.getLong("elapsedMs"),
            ))
        }
        true
    })

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "check" -> {
                    val config = call.argument<String>("config")
                    when {
                        pending != null -> result.error("BUSY", "Check already running", null)
                        config == null || config.length > 65536 ->
                            result.error("INVALID_CONFIG", "Invalid check configuration", null)
                        else -> {
                            requestId++
                            pending = result
                            payload = config
                            main.postDelayed(timeout, 20000)
                            if (remote != null) dispatch() else bind()
                        }
                    }
                }
                "cancel" -> {
                    sendCancel()
                    // Acknowledge the command now, but wait for worker cleanup before another check.
                    result.success(null)
                    if (remote == null) {
                        finish(mapOf("status" to "cancelled"))
                        unbind()
                    }
                }
                "release" -> {
                    if (pending != null) {
                        result.error("BUSY", "Check still running", null)
                    } else {
                        unbind()
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun bind() {
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                if (binding !== this) return
                remote = Messenger(binder)
                dispatch()
            }
            override fun onServiceDisconnected(name: ComponentName) = lost()
            override fun onBindingDied(name: ComponentName) = lost()
            override fun onNullBinding(name: ComponentName) = lost()
            private fun lost() {
                if (binding !== this) return
                finish(mapOf("status" to "error", "code" to "WORKER_STOPPED"))
                unbind()
            }
        }
        binding = connection
        val bound = runCatching {
            context.bindService(Intent(context, ProfileProbeService::class.java), connection, Context.BIND_AUTO_CREATE)
        }.getOrDefault(false)
        if (!bound) {
            binding = null
            finish(mapOf("status" to "error", "code" to "WORKER_UNAVAILABLE"))
        }
    }

    private fun dispatch() {
        val config = payload ?: return
        payload = null
        runCatching {
            remote!!.send(Message.obtain(null, ProfileProbeService.CHECK, requestId, 0).apply {
                replyTo = replies
                data = Bundle().apply { putString("config", config) }
            })
        }.onFailure {
            finish(mapOf("status" to "error", "code" to "WORKER_STOPPED"))
            unbind()
        }
    }

    private fun sendCancel() {
        runCatching { remote?.send(Message.obtain(null, ProfileProbeService.CANCEL)) }
    }

    private fun finish(value: Map<String, Any?>) {
        main.removeCallbacks(timeout)
        val result = pending
        pending = null
        payload = null
        result?.success(value)
    }

    private fun unbind() {
        val connection = binding
        binding = null
        remote = null
        if (connection != null) runCatching { context.unbindService(connection) }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        sendCancel()
        finish(mapOf("status" to "cancelled"))
        unbind()
    }
}
