package com.neuravpn.app.vpn

import org.json.JSONArray
import org.json.JSONObject

internal object ProfileProbeConfig {
    fun build(source: String, port: Int): String {
        require(source.length <= 65536 && port in 1..65535)
        val outbound = JSONObject(source).getJSONArray("outbounds").getJSONObject(0)
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

    fun accepts(status: Int): Boolean = status == 204
}
