package com.neuravpn.app.vpn

import org.json.JSONArray
import org.json.JSONObject

internal object ProfileProbeConfig {
    /** Hard caps keep a hostile or broken subscription from exhausting the worker. */
    const val MAX_TARGETS = 256
    const val MAX_PAYLOAD = 400_000

    /** Protocols that always leave through a remote server: no false greens. */
    private val PROXY_PROTOCOLS = setOf("vless", "vmess", "trojan", "shadowsocks", "hysteria")

    data class Target(val id: String, val outbound: JSONObject)

    /** Parses and validates the targets sent by Dart. Invalid entries are dropped. */
    fun parseTargets(source: String): Pair<List<Target>, List<String>> {
        require(source.length <= MAX_PAYLOAD)
        val array = JSONArray(source)
        require(array.length() in 1..MAX_TARGETS)
        val valid = ArrayList<Target>(array.length())
        val rejected = ArrayList<String>()
        for (index in 0 until array.length()) {
            val item = array.getJSONObject(index)
            val id = item.getString("id")
            val outbound = item.optJSONObject("outbound")
            if (outbound != null && isProbeable(outbound)) {
                valid.add(Target(id, outbound))
            } else {
                rejected.add(id)
            }
        }
        return valid to rejected
    }

    private fun isProbeable(outbound: JSONObject): Boolean = runCatching {
        val protocol = outbound.getString("protocol")
        if (protocol !in PROXY_PROTOCOLS) return false
        // A chained server needs its detour; alone it would be a false failure
        // or, worse, a detour through something direct.
        if (outbound.has("proxySettings") || outbound.has("sendThrough")) return false
        val sockopt = outbound.optJSONObject("streamSettings")?.optJSONObject("sockopt")
        if (sockopt?.has("dialerProxy") == true) return false
        if (protocol == "hysteria") {
            require(outbound.getJSONObject("streamSettings").getString("security") == "tls")
        }
        true
    }.getOrDefault(false)

    /**
     * One core for the whole batch: inbound `probe-in-i` on [ports][i] is routed
     * only to outbound `probe-out-i`, so every request measures exactly one server.
     */
    fun build(targets: List<Target>, ports: IntArray): String {
        require(targets.isNotEmpty() && targets.size == ports.size)
        val inbounds = JSONArray()
        val outbounds = JSONArray()
        val rules = JSONArray()
        targets.forEachIndexed { index, target ->
            require(ports[index] in 1..65535)
            val inTag = "probe-in-$index"
            val outTag = "probe-out-$index"
            inbounds.put(JSONObject()
                .put("listen", "127.0.0.1").put("port", ports[index])
                .put("protocol", "http").put("tag", inTag)
                .put("settings", JSONObject()))
            outbounds.put(JSONObject(target.outbound.toString()).put("tag", outTag))
            rules.put(JSONObject()
                .put("type", "field")
                .put("inboundTag", JSONArray().put(inTag))
                .put("outboundTag", outTag))
        }
        // Anything unmatched is dropped, never sent direct.
        outbounds.put(JSONObject().put("protocol", "blackhole").put("tag", "probe-drop"))
        rules.put(JSONObject().put("type", "field").put("network", "tcp,udp").put("outboundTag", "probe-drop"))
        return JSONObject()
            .put("log", JSONObject().put("loglevel", "none").put("access", "none"))
            .put("inbounds", inbounds)
            .put("outbounds", outbounds)
            .put("routing", JSONObject().put("domainStrategy", "AsIs").put("rules", rules))
            .toString()
    }


    fun accepts(status: Int): Boolean = status == 204
}
