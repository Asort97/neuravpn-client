package com.neuravpn.app.vpn

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class ProfileProbeConfigTest {
    @Test fun preservesHysteria2TransportAndObfuscation() {
        val source = """{"outbounds":[{"protocol":"hysteria","settings":{"version":2,"address":"example.com","port":443},"streamSettings":{"network":"hysteria","security":"tls","hysteriaSettings":{"version":2,"auth":"secret"},"finalmask":{"udp":[{"type":"salamander","settings":{"password":"test"}}]}}}]}"""
        val result = JSONObject(ProfileProbeConfig.build(source, 19582))
        val outbound = result.getJSONArray("outbounds").getJSONObject(0)
        assertEquals("hysteria", outbound.getString("protocol"))
        assertEquals(JSONObject(source).getJSONArray("outbounds").getJSONObject(0).getJSONObject("streamSettings").toString(), outbound.getJSONObject("streamSettings").toString())
        assertFalse(result.has("routing"))
    }

    @Test fun isolatesRealTransportWithoutDirectBypass() {
        for (transport in listOf("tcp", "xhttp")) {
            val source = """{"outbounds":[{"tag":"user-name","protocol":"vless",
                "settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"test-id","flow":"xtls-rprx-vision"}]}]},
                "streamSettings":{"network":"$transport","security":"reality","realitySettings":{"serverName":"example.org","publicKey":"test-key","shortId":"aa"}}},
                {"protocol":"freedom"}],"dns":{},"routing":{"rules":[]}}"""
            val config = JSONObject(ProfileProbeConfig.build(source, 19582))
            assertFalse(config.has("dns"))
            assertFalse(config.has("routing"))
            assertEquals(1, config.getJSONArray("outbounds").length())
            val outbound = config.getJSONArray("outbounds").getJSONObject(0)
            val original = JSONObject(source).getJSONArray("outbounds").getJSONObject(0)
            assertEquals(original.getJSONObject("settings").toString(), outbound.getJSONObject("settings").toString())
            assertEquals(original.getJSONObject("streamSettings").toString(), outbound.getJSONObject("streamSettings").toString())
            val inbound = config.getJSONArray("inbounds").getJSONObject(0)
            assertEquals("127.0.0.1", inbound.getString("listen"))
            assertEquals("http", inbound.getString("protocol"))
            assertEquals(19582, inbound.getInt("port"))
            assertFalse(inbound.has("sniffing"))
            assertEquals("none", config.getJSONObject("log").getString("loglevel"))
        }
    }

    @Test fun rejectsDirectProfilesAndUnexpectedHttpResponses() {
        assertThrows(IllegalArgumentException::class.java) {
            ProfileProbeConfig.build("""{"outbounds":[{"protocol":"freedom"}]}""", 10809)
        }
        assertTrue(ProfileProbeConfig.accepts(204))
        for (status in listOf(200, 301, 302, 403, 407, 500)) assertFalse(ProfileProbeConfig.accepts(status))
    }
}
