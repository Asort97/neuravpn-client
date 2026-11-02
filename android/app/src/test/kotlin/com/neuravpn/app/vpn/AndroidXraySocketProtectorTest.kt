package com.neuravpn.app.vpn

import org.junit.Assert.*
import org.junit.Test

class AndroidXraySocketProtectorTest {
    @Test fun repeatedStartsKeepOneNativeControllerAndUseOnlyCurrentService() {
        val controllers = mutableListOf<(Long) -> Boolean>()
        val protector = AndroidXraySocketProtector(controllers::add)
        var staleCalls = 0
        var currentCalls = 0
        val old = Any()
        val current = Any()
        protector.activate(old) { staleCalls++; false }
        protector.deactivate(old)
        protector.activate(current) { fd -> currentCalls++; fd == 7L }
        protector.activate(current) { fd -> currentCalls++; fd == 7L }
        assertEquals(1, controllers.size)
        assertTrue(controllers.single()(7))
        assertEquals(0, staleCalls)
        assertEquals(1, currentCalls)
    }

    @Test fun oldServiceCleanupCannotRemoveNewOwner() {
        lateinit var callback: (Long) -> Boolean
        val protector = AndroidXraySocketProtector { callback = it }
        val old = Any()
        val current = Any()
        protector.activate(old) { false }
        protector.activate(current) { true }
        protector.deactivate(old)
        assertTrue(callback(1))
        protector.deactivate(current)
        assertFalse(callback(1))
    }

    @Test fun failedRegistrationCanRetryWithoutRetainingFailedOwner() {
        var attempts = 0
        lateinit var callback: (Long) -> Boolean
        val protector = AndroidXraySocketProtector {
            attempts++
            if (attempts == 1) throw IllegalStateException("registration failed")
            callback = it
        }
        assertThrows(IllegalStateException::class.java) { protector.activate(Any()) { false } }
        protector.activate(Any()) { true }
        assertEquals(2, attempts)
        assertTrue(callback(1))
    }

    @Test fun liveNetworkChangeIsObservedWithoutAnotherRegistration() {
        var network = "wifi"
        lateinit var callback: (Long) -> Boolean
        val seen = mutableListOf<String>()
        val protector = AndroidXraySocketProtector { callback = it }
        protector.activate(Any()) { seen.add(network); true }
        callback(1)
        network = "mobile"
        callback(2)
        assertEquals(listOf("wifi", "mobile"), seen)
    }
}
