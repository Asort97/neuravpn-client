package com.neuravpn.app.vpn

import android.content.*
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter side of the profile probe worker. A `check` call carries every server
 * of one subscription; per-server results stream back as `result` calls while
 * the check runs, and the `check` reply arrives once the worker is done.
 */
internal class ProfileProbeChannel(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "neuravpn/profile_probe")
    private val main = Handler(Looper.getMainLooper())
    private var remote: Messenger? = null
    private var binding: ServiceConnection? = null
    private var pending: MethodChannel.Result? = null
    private var payload: String? = null
    private var run: Int = 0
    private var requestId = 0

    // Resets on every streamed result: a big subscription may take long, but a
    // worker that stops reporting is stuck.
    private val timeout = Runnable {
        sendCancel()
        finish(mapOf("status" to "error", "code" to "WORKER_TIMEOUT"))
        unbind()
    }
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.arg1 == requestId && pending != null) {
            when (message.what) {
                ProfileProbeService.RESULT -> {
                    armTimeout()
                    channel.invokeMethod("result", mapOf(
                        "run" to run,
                        "id" to message.data.getString("id"),
                        "status" to message.data.getString("status"),
                        "code" to message.data.getString("code"),
                        "elapsedMs" to message.data.getLong("elapsedMs"),
                    ))
                }
                ProfileProbeService.CHECK -> finish(mapOf(
                    "status" to message.data.getString("status"),
                    "code" to message.data.getString("code"),
                ))
            }
        }
        true
    })

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "check" -> {
                    val targets = call.argument<String>("targets")
                    when {
                        pending != null -> result.error("BUSY", "Check already running", null)
                        targets == null || targets.length > ProfileProbeConfig.MAX_PAYLOAD ->
                            result.error("INVALID_CONFIG", "Invalid check configuration", null)
                        else -> {
                            requestId++
                            run = call.argument<Int>("run") ?: 0
                            pending = result
                            payload = targets
                            armTimeout()
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

    private fun armTimeout() {
        main.removeCallbacks(timeout)
        main.postDelayed(timeout, IDLE_TIMEOUT_MS)
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
        val targets = payload ?: return
        payload = null
        runCatching {
            remote!!.send(Message.obtain(null, ProfileProbeService.CHECK, requestId, 0).apply {
                replyTo = replies
                data = Bundle().apply { putString("targets", targets) }
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

    companion object {
        const val IDLE_TIMEOUT_MS = 30_000L
    }
}
