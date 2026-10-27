package com.neuravpn.app.vpn

internal object AndroidDnsEndpoint {
    fun format(address: String): String =
        if (address.contains(':') && !address.startsWith('[')) "[$address]:53" else "$address:53"
}
