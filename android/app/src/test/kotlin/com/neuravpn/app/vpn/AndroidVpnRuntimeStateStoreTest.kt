package com.neuravpn.app.vpn

import android.app.Application
import android.content.Context
import android.system.Os
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class, shadows = [HostAtomicRename::class])
class AndroidVpnRuntimeStateStoreTest {
    private lateinit var context: Context

    @Before fun setUp() {
        context = RuntimeEnvironment.getApplication()
        File(context.filesDir, "neuravpn_runtime_state.json").delete()
    }

    @Test fun failureSurvivesServiceDestruction() {
        AndroidVpnRuntimeStateStore.markError(context, "xray", "session-a",
            "TUN_ESTABLISH_FAILED", "Tunnel unavailable", "all")
        AndroidVpnRuntimeStateStore.markStopped(context, "xray", preserveError = true,
            sessionId = "session-a")
        val state = AndroidVpnRuntimeStateStore.read(context)
        assertEquals(AndroidVpnPhase.ERROR, state.phase)
        assertEquals("TUN_ESTABLISH_FAILED", state.errorCode)
        assertEquals("session-a", state.toMap()["sessionId"])
        assertFalse(state.isActive)
    }

    @Test fun previousServiceCannotStopANewerSession() {
        AndroidVpnRuntimeStateStore.markStarting(context, "xray", "new", "smart")
        AndroidVpnRuntimeStateStore.markStopped(context, "xray", sessionId = "old")
        val state = AndroidVpnRuntimeStateStore.read(context)
        assertEquals("new", state.sessionId)
        assertEquals(AndroidVpnPhase.STARTING, state.phase)
    }

    @Test fun rapidDuplicateStartsKeepOneSession() {
        val workers = Executors.newFixedThreadPool(4)
        val starts = (0 until 12).map { i ->
            workers.submit<Boolean> {
                AndroidVpnRuntimeStateStore.requestStart(context, "xray", "session-$i", "all")
            }
        }
        try {
            assertEquals(1, starts.count { it.get(5, TimeUnit.SECONDS) })
            assertTrue(AndroidVpnRuntimeStateStore.read(context).isActive)
        } finally {
            workers.shutdownNow()
        }
    }

    @Test fun explicitStopThenStartAllowsNewSession() {
        assertTrue(AndroidVpnRuntimeStateStore.requestStart(context, "xray", "one", "all"))
        AndroidVpnRuntimeStateStore.markStopping(context)
        assertFalse(AndroidVpnRuntimeStateStore.requestStart(context, "xray", "two", "all"))
        AndroidVpnRuntimeStateStore.markStopped(context, sessionId = "one")
        assertTrue(AndroidVpnRuntimeStateStore.requestStart(context, "xray", "two", "all"))
        assertEquals("two", AndroidVpnRuntimeStateStore.read(context).sessionId)
    }
}

// Robolectric's Os.rename is a no-op on the host. Model the actual Android
// atomic replacement without changing the production storage implementation.
@Implements(Os::class)
class HostAtomicRename {
    companion object {
        @JvmStatic
        @Implementation
        fun rename(oldPath: String, newPath: String) {
            Files.move(File(oldPath).toPath(), File(newPath).toPath(),
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        }
    }
}
