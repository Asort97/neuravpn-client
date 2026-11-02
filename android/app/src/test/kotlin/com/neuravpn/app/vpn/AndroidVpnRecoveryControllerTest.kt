package com.neuravpn.app.vpn

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidVpnRecoveryControllerTest {
    private data class Task(val at: Long, val run: () -> Unit, var cancelled: Boolean = false)
    private var time = 1000L
    private val tasks = mutableListOf<Task>()
    private val calls = mutableListOf<String>()
    private var fails = false
    private var exhaustedCount = 0
    private val recovery = AndroidVpnRecoveryController(
        now = { time },
        schedule = { delay, run ->
            val task = Task(time + delay, run)
            tasks.add(task)
            val cancel: () -> Unit = { task.cancelled = true }
            cancel
        },
        recover = { calls.add(it); !fails },
        exhausted = { exhaustedCount++ },
    )

    private fun advance(ms: Long) {
        val target = time + ms
        while (true) {
            val task = tasks.filter { it.at <= target }.minByOrNull { it.at } ?: break
            tasks.remove(task)
            time = task.at
            if (!task.cancelled) task.run()
        }
        time = target
    }

    private fun start(network: String? = "wifi") = recovery.start(network, idle = false, interactive = true)

    @Test fun startupAndDuplicateCallbacksDoNotRestart() {
        start()
        repeat(20) { recovery.networkChanged("wifi") }
        recovery.idleChanged(false)
        recovery.interactiveChanged(true, time)
        advance(10_000)
        assertEquals(0, calls.size)
    }

    @Test fun networkHandoffRestartsOnceAfterSettling() {
        start()
        recovery.networkChanged(null)
        recovery.networkChanged("mobile")
        advance(100)
        repeat(10) { recovery.networkChanged("mobile") }
        advance(200)
        assertEquals(listOf("network changed"), calls)
    }

    @Test fun linkAddressChangeOnSameNetworkIsAHandoff() {
        start("wifi|address1")
        recovery.networkChanged("wifi|address2")
        advance(300)
        assertEquals(1, calls.size)
    }

    @Test fun offlineDoesNotLoopAndSameNetworkReturningRecovers() {
        start()
        recovery.networkChanged(null)
        advance(300_000)
        assertEquals(0, calls.size)
        recovery.networkChanged("wifi")
        advance(300)
        assertEquals(1, calls.size)
    }

    @Test fun startupWithoutNetworkRecoversWhenItArrives() {
        start(null)
        advance(10_000)
        assertEquals(0, calls.size)
        recovery.networkChanged("wifi")
        advance(300)
        assertEquals(1, calls.size)
    }

    @Test fun networkLossCancelsPendingRecovery() {
        start()
        recovery.networkChanged("mobile")
        recovery.networkChanged(null)
        advance(1000)
        assertEquals(0, calls.size)
    }

    @Test fun idleExitRecoversEvenWithTheSameNetworkAndClosedUi() {
        start()
        recovery.idleChanged(true)
        advance(60_000)
        assertEquals(0, calls.size)
        recovery.idleChanged(false)
        advance(300)
        assertEquals(listOf("device idle ended"), calls)
    }

    @Test fun handoffDuringIdleWaitsForNetworkAccess() {
        start()
        recovery.idleChanged(true)
        recovery.networkChanged("mobile")
        advance(60_000)
        assertEquals(0, calls.size)
        recovery.idleChanged(false)
        advance(300)
        assertEquals(1, calls.size)
    }

    @Test fun initialStartWhileIdleDoesNotRestartUntilIdleEnds() {
        recovery.start("wifi", idle = true, interactive = false)
        recovery.idleChanged(true)
        advance(60_000)
        assertEquals(0, calls.size)
        recovery.idleChanged(false)
        advance(300)
        assertEquals(1, calls.size)
    }

    @Test fun screenOffAndQuickUnlockDoNotInterruptTraffic() {
        start()
        recovery.interactiveChanged(false, time)
        advance(2000)
        recovery.interactiveChanged(true, 1000)
        advance(1000)
        assertEquals(0, calls.size)
    }

    @Test fun longSleepWithoutTrafficRecovers() {
        start()
        recovery.interactiveChanged(false, time)
        advance(60_000)
        recovery.interactiveChanged(true, 1000)
        advance(300)
        assertEquals(listOf("resumed after inactive sleep"), calls)
    }

    @Test fun streamingWithScreenOffIsNotInterruptedOnUnlock() {
        start()
        recovery.interactiveChanged(false, time)
        advance(60_000)
        recovery.interactiveChanged(true, time - 500)
        advance(1000)
        assertEquals(0, calls.size)
    }

    @Test fun idleExitFollowedByUnlockDoesNotRecoverTwice() {
        start()
        recovery.interactiveChanged(false, time)
        recovery.idleChanged(true)
        advance(60_000)
        recovery.idleChanged(false)
        advance(300)
        recovery.interactiveChanged(true, 1000)
        advance(1000)
        assertEquals(1, calls.size)
    }

    @Test fun sleepAndNetworkEventsCoalesce() {
        start()
        recovery.interactiveChanged(false, time)
        advance(60_000)
        recovery.networkChanged("mobile")
        recovery.interactiveChanged(true, 1000)
        advance(300)
        assertEquals(1, calls.size)
    }

    @Test fun oldHandoffDuringSleepDoesNotSuppressWakeRecovery() {
        start()
        recovery.interactiveChanged(false, time)
        recovery.networkChanged("mobile")
        advance(300)
        advance(60_000)
        recovery.interactiveChanged(true, 1000)
        advance(300)
        assertEquals(listOf("network changed", "resumed after inactive sleep"), calls)
    }

    @Test fun recentHandoffDuringSleepDoesNotRecoverAgainOnUnlock() {
        start()
        recovery.interactiveChanged(false, time)
        advance(60_000)
        recovery.networkChanged("mobile")
        advance(300)
        recovery.interactiveChanged(true, 1000)
        advance(1000)
        assertEquals(listOf("network changed"), calls)
    }

    @Test fun manualStopCancelsQueuedRecoveryAndIgnoresLateEvents() {
        start()
        recovery.networkChanged("mobile")
        recovery.stop()
        recovery.networkChanged("wifi")
        recovery.idleChanged(false)
        advance(1000)
        assertEquals(0, calls.size)
    }

    @Test fun replacedSessionCannotRunAnOldTaskEvenIfCancellationRaces() {
        start()
        recovery.networkChanged("mobile")
        val oldTask = tasks.single()
        recovery.start("wifi", idle = false, interactive = true)
        oldTask.run()
        advance(1000)
        assertEquals(0, calls.size)
    }

    @Test fun failedRecoveryHasBoundedRetriesThenReportsError() {
        fails = true
        start()
        recovery.networkChanged("mobile")
        advance(10_000)
        assertEquals(3, calls.size)
        assertEquals(1, exhaustedCount)
        advance(60_000)
        assertEquals(3, calls.size)
    }

    @Test fun successCancelsFurtherRetries() {
        fails = true
        start()
        recovery.networkChanged("mobile")
        advance(300)
        fails = false
        advance(5000)
        assertEquals(2, calls.size)
        assertEquals(0, exhaustedCount)
    }

    @Test fun manualStopWinsOverRetry() {
        fails = true
        start()
        recovery.networkChanged("mobile")
        advance(300)
        recovery.stop()
        advance(5000)
        assertEquals(1, calls.size)
        assertEquals(0, exhaustedCount)
    }
}
