package com.neuravpn.app.vpn

import org.json.JSONArray
import org.json.JSONObject

internal object ProfileProbeConfig {
    fun build(source: String, port: Int): String {
        require(source.length <= 512 * 1024 && port in 1..65535)
        val parsed = JSONObject(source)
        if (parsed.optBoolean("fullProfile")) return buildFull(parsed, port)
        val outbound = parsed.getJSONArray("outbounds").getJSONObject(0)
        require(outbound.getString("protocol") in setOf("vless", "hysteria"))
        if (outbound.getString("protocol") == "hysteria") {
            require(outbound.getJSONObject("settings").getInt("version") == 2)
            require(outbound.getJSONObject("streamSettings").getString("security") == "tls")
        }
        require(!outbound.has("proxySettings"))
        outbound.put("tag", "probe-out")
        // No direct/DNS bypass or sniffing: every CONNECT target uses this node.
        return JSONObject()
            .put("log", JSONObject().put("loglevel", "none").put("access", "none"))
            .put("inbounds", JSONArray().put(JSONObject()
                .put("listen", "127.0.0.1").put("port", port)
                .put("protocol", "http").put("tag", "probe-in")
                .put("settings", JSONObject())))
            .put("outbounds", JSONArray().put(outbound))
            .toString()
    }

    private fun buildFull(config: JSONObject, port: Int): String {
        val outbounds = config.getJSONArray("outbounds")
        // No direct candidate can turn a bypassed HTTPS request into a green check.
        for (index in 0 until outbounds.length()) {
            val out = outbounds.getJSONObject(index)
            require(out.getString("protocol") in setOf("vless", "hysteria", "blackhole", "dns"))
            require(!out.has("proxySettings") && !out.has("sendThrough"))
        }
        val sourceInbounds = config.getJSONArray("inbounds")
        var tag = sourceInbounds.getJSONObject(0).getString("tag")
        for (index in 0 until sourceInbounds.length()) {
            val inbound = sourceInbounds.getJSONObject(index)
            if (inbound.getString("protocol") == "socks") {
                tag = inbound.getString("tag")
                break
            }
        }
        // Copy only the validated data plane. Never import an API or listener.
        return JSONObject().apply {
            for (key in listOf("outbounds", "routing", "dns", "observatory")) {
                if (config.has(key)) put(key, config.get(key))
            }
            put("log", JSONObject().put("loglevel", "none").put("access", "none"))
            put("inbounds", JSONArray().put(JSONObject()
                .put("listen", "127.0.0.1").put("port", port)
                .put("protocol", "http").put("tag", tag).put("settings", JSONObject())))
        }.toString()
    }

    fun accepts(status: Int): Boolean = status == 204
}
