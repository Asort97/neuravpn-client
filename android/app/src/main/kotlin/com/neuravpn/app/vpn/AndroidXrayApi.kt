package com.neuravpn.app.vpn

import libXray.LibXray
import org.json.JSONObject

internal class AndroidXrayApi(
    private val invoke: (String) -> String = { LibXray.invoke(it) },
) {
    fun version(): String = call("xrayVersion").getJSONObject("data").getString("version")

    fun isRunning(): Boolean = call("getXrayState").getJSONObject("data").getBoolean("running")

    fun start(config: String, datDir: String) {
        val runtimeConfig = JSONObject(config)
        // The new API reads runtime environment from the config, not the envelope.
        val env = runtimeConfig.optJSONObject("env") ?: JSONObject()
        env.put("xray.location.asset", datDir)
        runtimeConfig.put("env", env)
        call("runXrayFromJson", JSONObject().put("configJSON", runtimeConfig.toString()))
    }

    fun stop() {
        call("stopXray")
    }

    private fun call(method: String, payload: JSONObject = JSONObject()): JSONObject {
        val request = JSONObject()
            .put("apiVersion", 1)
            .put("method", method)
            .put("payload", payload)
        val response = JSONObject(invoke(request.toString()))
        check(response.optBoolean("success")) {
            AndroidVpnLogSanitizer.redact(
                response.optString("error").ifBlank { "Xray $method failed" },
            )
        }
        return response
    }
}
