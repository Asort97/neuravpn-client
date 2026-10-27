package com.neuravpn.app.vpn

import android.app.Application
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class AndroidVpnStopWatchdogTest {
    @Test fun ordinaryStopCancelsFallback() {
        val watchdog = AndroidVpnStopWatchdog(timeoutMs = 100)
        var calls = 0
        watchdog.arm({ true }) { calls++ }
        watchdog.cancel()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(200))
        assertEquals(0, calls)
    }

    @Test fun staleSessionCannotTriggerFallback() {
        val watchdog = AndroidVpnStopWatchdog(timeoutMs = 100)
        var stopping = true
        var calls = 0
        watchdog.arm({ stopping }) { calls++ }
        stopping = false
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(200))
        assertEquals(0, calls)
    }

    @Test fun repeatedStopDoesNotPostponeDeadline() {
        val watchdog = AndroidVpnStopWatchdog(timeoutMs = 100)
        var calls = 0
        watchdog.arm({ true }) { calls++ }
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(60))
        watchdog.arm({ true }) { calls++ }
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(40))
        assertEquals(1, calls)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(200))
        assertEquals(1, calls)
    }
}
