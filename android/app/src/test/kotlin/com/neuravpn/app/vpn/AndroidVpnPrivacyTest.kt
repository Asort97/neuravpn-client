package com.neuravpn.app.vpn

import org.junit.Assert.*
import org.junit.Test

class AndroidVpnPrivacyTest {
    @Test fun nativeDiagnosticsKeepFailuresWithoutDestinations() {
        assertNull(AndroidXrayDiagnostics.failureMessage("[Info] accepted tcp:example.com:443"))
        val line = AndroidXrayDiagnostics.failureMessage(
            "[Info] [123] failed to dial tcp:203.0.113.42:443 > connection refused",
        )!!
        assertTrue(line.contains("connection refused"))
        assertFalse(line.contains("203.0.113.42"))
        assertFalse(line.contains("[123]"))
    }

    @Test fun dnsEndpointSupportsIpv4Ipv6AndScopedIpv6() {
        assertEquals("192.168.1.1:53", AndroidDnsEndpoint.format("192.168.1.1"))
        assertEquals("[2001:4860:4860::8888]:53", AndroidDnsEndpoint.format("2001:4860:4860::8888"))
        assertEquals("[fe80::1%wlan0]:53", AndroidDnsEndpoint.format("fe80::1%wlan0"))
    }

    @Test fun logsRemoveSubscriptionCredentialsAndAddresses() {
        val secrets = listOf(
            "11111111-1111-1111-1111-111111111111",
            "https://example.com/merged-sub/private-token",
            "203.0.113.42", "edge.example.org", "2001:db8::1234",
            "PUBLICKEY0123456789ABCDEFGHIJKLMNOPQRSTUVWX",
        )
        val sanitized = AndroidVpnLogSanitizer.redact("startup failed: ${secrets.joinToString(" ")}")
        secrets.forEach { assertFalse(sanitized.contains(it)) }
        assertTrue(sanitized.contains("startup failed"))
        assertEquals("configBytes=512", AndroidVpnLogSanitizer.redact("configBytes=512"))
    }
}
