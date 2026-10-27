package com.neuravpn.app.vpn

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [33])
class AndroidXrayApiTest {
    @Test
    fun startUsesVersionedJsonEnvelopeAndConfigEnvironment() {
        var captured = JSONObject()
        val api = AndroidXrayApi { captured = JSONObject(it); """{"success":true,"data":{}}""" }
        api.start("""{"outbounds":[],"env":{"xray.buf.readv":"false"}}""", "/private/geodata")
        assertEquals(1, captured.getInt("apiVersion"))
        assertEquals("runXrayFromJson", captured.getString("method"))
        assertFalse(captured.has("env"))
        val config = JSONObject(captured.getJSONObject("payload").getString("configJSON"))
        assertEquals("/private/geodata", config.getJSONObject("env").getString("xray.location.asset"))
        assertEquals("false", config.getJSONObject("env").getString("xray.buf.readv"))
        assertTrue(config.has("outbounds"))
    }

    @Test
    fun versionAndStateUseStructuredDataRatherThanLegacyBase64() {
        val api = AndroidXrayApi {
            when (JSONObject(it).getString("method")) {
                "xrayVersion" -> """{"success":true,"data":{"version":"26.7.28"}}"""
                "getXrayState" -> """{"success":true,"data":{"running":false}}"""
                else -> error("Unexpected method")
            }
        }
        assertEquals("26.7.28", api.version())
        assertFalse(api.isRunning())
    }

    @Test
    fun failuresAreNotTreatedAsSuccessfulStartsAndAreRedacted() {
        val api = AndroidXrayApi {
            """{"success":false,"error":"dial tcp 203.0.113.1:443 failed"}"""
        }
        val error = assertThrows(IllegalStateException::class.java) { api.start("{}", "/data") }
        assertFalse(error.message!!.contains("203.0.113.1"))
        assertTrue(error.message!!.contains("failed"))
    }

    @Test
    fun stopUsesTheSameStructuredEntrypoint() {
        val api = AndroidXrayApi {
            assertEquals("stopXray", JSONObject(it).getString("method"))
            """{"success":true,"data":{}}"""
        }
        api.stop()
    }
}
