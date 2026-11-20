package com.neuravpn.app.vpn

import android.content.*
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.time.Duration
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class ProfileProbeChannelTest {
    private class FlutterMessenger : BinaryMessenger {
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        val streamed = mutableListOf<MethodCall>()
        override fun send(channel: String, message: ByteBuffer?) = record(message)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = record(message)
        private fun record(message: ByteBuffer?) {
            message ?: return
            message.rewind()
            streamed.add(StandardMethodCodec.INSTANCE.decodeMethodCall(message))
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }
        fun call(method: String, callback: (Any?) -> Unit) {
            val encoded = StandardMethodCodec.INSTANCE.encodeMethodCall(
                MethodCall(method, mapOf("run" to 7, "targets" to "[]")),
            )
            encoded.rewind()
            handler!!.onMessage(encoded) { reply ->
                reply?.rewind()
                callback(StandardMethodCodec.INSTANCE.decodeEnvelope(reply!!))
            }
        }
    }
    private class BindContext : ContextWrapper(RuntimeEnvironment.getApplication()) {
        var connection: ServiceConnection? = null
        var unbinds = 0
        var boundIntent: Intent? = null
        var allowBinding = true
        val requests = mutableListOf<Message>()
        val worker = Messenger(Handler(Looper.getMainLooper()) { message ->
            requests.add(Message.obtain(message))
            true
        })
        override fun bindService(intent: Intent, conn: ServiceConnection, flags: Int): Boolean {
            boundIntent = intent
            connection = conn
            return allowBinding
        }
        override fun unbindService(conn: ServiceConnection) { unbinds++ }
        fun connect() {
            connection!!.onServiceConnected(boundIntent!!.component!!, worker.binder)
            idle()
        }
        private val replyTo get() = requests.first { it.what == ProfileProbeService.CHECK }.replyTo
        fun result(id: Int, target: String) {
            replyTo.send(Message.obtain(null, ProfileProbeService.RESULT, id, 0).apply {
                data = Bundle().apply {
                    putString("id", target); putString("status", "available")
                    putString("code", "HTTPS_OK"); putLong("elapsedMs", 123)
                }
            })
            idle()
        }
        fun reply(id: Int, status: String = "done") {
            replyTo.send(Message.obtain(null, ProfileProbeService.CHECK, id, 0).apply {
                data = Bundle().apply { putString("status", status); putString("code", "") }
            })
            idle()
        }
    }

    @Test fun bindsOnlyOnDemandAndIgnoresStaleReplies() {
        val flutter = FlutterMessenger()
        val context = BindContext()
        val channel = ProfileProbeChannel(context, flutter)
        try {
            assertNull(context.boundIntent)
            var response: Any? = null
            flutter.call("check") { response = it }
            assertEquals(ProfileProbeService::class.java.name, context.boundIntent!!.component!!.className)
            context.connect()
            val request = context.requests.single()
            assertEquals("[]", request.data.getString("targets"))
            context.result(request.arg1 + 1, "stale")
            context.reply(request.arg1 + 1)
            assertNull(response)
            assertTrue(flutter.streamed.isEmpty())
            context.result(request.arg1, "t0")
            val streamed = flutter.streamed.single()
            assertEquals("result", streamed.method)
            assertEquals(7, streamed.argument<Int>("run"))
            assertEquals("t0", streamed.argument<String>("id"))
            assertEquals(123L, (streamed.argument<Any>("elapsedMs") as Number).toLong())
            assertNull(response)
            context.reply(request.arg1)
            assertEquals("done", (response as Map<*, *>)["status"])
            flutter.call("release") {}
            assertEquals(1, context.unbinds)
        } finally { channel.close() }
        assertEquals(1, context.unbinds)
    }

    @Test fun cancelWaitsForWorkerCleanupRatherThanStartingConcurrentCores() {
        val flutter = FlutterMessenger()
        val context = BindContext()
        val channel = ProfileProbeChannel(context, flutter)
        try {
            var response: Any? = null
            var cancelReply = false
            flutter.call("check") { response = it }
            context.connect()
            flutter.call("cancel") { cancelReply = true }
            idle()
            assertTrue(cancelReply)
            assertNull(response)
            assertEquals(ProfileProbeService.CANCEL, context.requests.last().what)
            context.reply(context.requests.first().arg1, "cancelled")
            assertEquals("cancelled", (response as Map<*, *>)["status"])
        } finally { channel.close() }
    }

    @Test fun missingWorkerTimesOutAndReleasesBinding() {
        val flutter = FlutterMessenger()
        val context = BindContext()
        val channel = ProfileProbeChannel(context, flutter)
        try {
            var response: Any? = null
            flutter.call("check") { response = it }
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(31))
            assertEquals("WORKER_TIMEOUT", (response as Map<*, *>)["code"])
            assertEquals(1, context.unbinds)
        } finally { channel.close() }
    }

    @Test fun streamedResultsKeepALongCheckAlive() {
        val flutter = FlutterMessenger()
        val context = BindContext()
        val channel = ProfileProbeChannel(context, flutter)
        try {
            var response: Any? = null
            flutter.call("check") { response = it }
            context.connect()
            val id = context.requests.first().arg1
            repeat(3) { index ->
                shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(25))
                context.result(id, "t$index")
            }
            assertNull(response)
            context.reply(id)
            assertEquals("done", (response as Map<*, *>)["status"])
        } finally { channel.close() }
    }

    @Test fun deniedBindingReturnsNeutralErrorWithoutStartingVpn() {
        val flutter = FlutterMessenger()
        val context = BindContext().apply { allowBinding = false }
        val channel = ProfileProbeChannel(context, flutter)
        try {
            var response: Any? = null
            flutter.call("check") { response = it }
            assertEquals("WORKER_UNAVAILABLE", (response as Map<*, *>)["code"])
            assertTrue(context.requests.isEmpty())
        } finally { channel.close() }
    }

    companion object {
        private fun idle() = shadowOf(Looper.getMainLooper()).idle()
    }
}
