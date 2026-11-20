package com.neuravpn.app.vpn

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class ProfileProbeConfigTest {
    private val vless = """{"tag":"user-name","protocol":"vless",
        "settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"test-id","flow":"xtls-rprx-vision"}]}]},
        "streamSettings":{"network":"xhttp","security":"reality","realitySettings":{"serverName":"example.org","publicKey":"test-key","shortId":"aa"}}}"""
    private val hysteria = """{"protocol":"hysteria","settings":{"version":2,"address":"example.com","port":443},"streamSettings":{"network":"hysteria","security":"tls","hysteriaSettings":{"version":2,"auth":"secret"},"finalmask":{"udp":[{"type":"salamander","settings":{"password":"test"}}]}}}"""

    private fun targets(vararg outbounds: String) =
        JSONArray().apply {
            outbounds.forEachIndexed { index, outbound ->
                put(JSONObject().put("id", "t$index").put("outbound", JSONObject(outbound)))
            }
        }.toString()

    @Test fun routesEachLocalPortToExactlyOneServer() {
        val (valid, rejected) = ProfileProbeConfig.parseTargets(targets(vless, hysteria))
        assertTrue(rejected.isEmpty())
        val config = JSONObject(ProfileProbeConfig.build(valid, intArrayOf(19582, 19583)))
        assertFalse(config.has("dns"))
        assertEquals("none", config.getJSONObject("log").getString("loglevel"))

        val inbounds = config.getJSONArray("inbounds")
        assertEquals(2, inbounds.length())
        for (index in 0 until 2) {
            val inbound = inbounds.getJSONObject(index)
            assertEquals("127.0.0.1", inbound.getString("listen"))
            assertEquals("http", inbound.getString("protocol"))
            assertEquals(19582 + index, inbound.getInt("port"))
            assertFalse(inbound.has("sniffing"))
        }
        val outbounds = config.getJSONArray("outbounds")
        val original = JSONObject(vless)
        val first = outbounds.getJSONObject(0)
        assertEquals("probe-out-0", first.getString("tag"))
        assertEquals(original.getJSONObject("settings").toString(), first.getJSONObject("settings").toString())
        assertEquals(original.getJSONObject("streamSettings").toString(), first.getJSONObject("streamSettings").toString())
        assertEquals(
            JSONObject(hysteria).getJSONObject("streamSettings").toString(),
            outbounds.getJSONObject(1).getJSONObject("streamSettings").toString(),
        )
        // Nothing can leave direct: the only extra outbound drops traffic.
        assertEquals("blackhole", outbounds.getJSONObject(2).getString("protocol"))
        for (index in 0 until outbounds.length()) {
            assertNotEquals("freedom", outbounds.getJSONObject(index).getString("protocol"))
        }
        val rules = config.getJSONObject("routing").getJSONArray("rules")
        for (index in 0 until 2) {
            val rule = rules.getJSONObject(index)
            assertEquals("probe-in-$index", rule.getJSONArray("inboundTag").getString(0))
            assertEquals("probe-out-$index", rule.getString("outboundTag"))
        }
        assertEquals("probe-drop", rules.getJSONObject(2).getString("outboundTag"))
    }

    @Test fun rejectsDirectChainedAndBrokenServersButKeepsTheRest() {
        val chained = """{"protocol":"vless","proxySettings":{"tag":"other"},"settings":{}}"""
        val dialer = """{"protocol":"trojan","streamSettings":{"sockopt":{"dialerProxy":"x"}}}"""
        val (valid, rejected) = ProfileProbeConfig.parseTargets(
            targets(vless, """{"protocol":"freedom"}""", chained, dialer, """{"protocol":"hysteria"}"""),
        )
        assertEquals(listOf("t0"), valid.map { it.id })
        assertEquals(listOf("t1", "t2", "t3", "t4"), rejected)
    }

    @Test fun capsPayloadAndAcceptsOnlyNoContent() {
        assertThrows(IllegalArgumentException::class.java) { ProfileProbeConfig.parseTargets("[]") }
        assertThrows(IllegalArgumentException::class.java) {
            ProfileProbeConfig.parseTargets("x".repeat(ProfileProbeConfig.MAX_PAYLOAD + 1))
        }
        assertTrue(ProfileProbeConfig.accepts(204))
        for (status in listOf(200, 301, 302, 403, 407, 500)) assertFalse(ProfileProbeConfig.accepts(status))
    }
}
