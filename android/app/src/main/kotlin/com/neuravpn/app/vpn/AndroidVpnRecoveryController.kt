package com.neuravpn.app.vpn

/** All entry points and scheduled callbacks run on the native runtime's single worker. */
internal class AndroidVpnRecoveryController(
    private val now: () -> Long,
    private val schedule: (Long, () -> Unit) -> (() -> Unit),
    private val recover: (String) -> Boolean,
    private val exhausted: () -> Unit,
) {
    private var active = false
    private var generation = 0L
    private var network: String? = null
    private var idle = false
    private var sleepingSince: Long? = null
    private var lastRecoveryAt = Long.MIN_VALUE
    private var reason: String? = null
    private var attempts = 0
    private var cancelPending: (() -> Unit)? = null

    fun start(network: String?, idle: Boolean, interactive: Boolean) {
        stop()
        active = true
        this.network = network
        this.idle = idle
        sleepingSince = if (interactive) null else now()
        lastRecoveryAt = Long.MIN_VALUE
        // Startup already used this network. Initial callback delivery is not a handoff.
    }

    fun stop() {
        active = false
        generation++
        cancelPending?.invoke()
        cancelPending = null
        reason = null
        attempts = 0
        sleepingSince = null
    }

    fun networkChanged(network: String?) {
        if (!active || this.network == network) return
        this.network = network
        request("network changed")
    }

    fun idleChanged(idle: Boolean) {
        if (!active || this.idle == idle) return
        this.idle = idle
        request("device idle ended")
    }

    fun interactiveChanged(interactive: Boolean, lastTrafficAt: Long) {
        if (!active) return
        if (!interactive) {
            if (sleepingSince == null) sleepingSince = now()
            return
        }
        val sleptAt = sleepingSince ?: return
        sleepingSince = null
        val time = now()
        if (time - sleptAt >= STALE_AFTER_MS && time - lastTrafficAt >= STALE_AFTER_MS &&
            (lastRecoveryAt < sleptAt || time - lastRecoveryAt >= STALE_AFTER_MS)
        ) request("resumed after inactive sleep")
    }

    private fun request(reason: String) {
        this.reason = reason
        attempts = 0
        cancelPending?.invoke()
        cancelPending = null
        generation++
        enqueue(COALESCE_MS)
    }

    private fun enqueue(delay: Long) {
        if (!active || network == null || idle || reason == null) return
        val token = generation
        cancelPending = schedule(delay) {
            if (!active || token != generation || network == null || idle) return@schedule
            cancelPending = null
            val cause = reason ?: return@schedule
            attempts++
            if (recover(cause)) {
                reason = null
                attempts = 0
                lastRecoveryAt = now()
            } else if (active && token == generation) {
                if (attempts < MAX_ATTEMPTS) enqueue(1000L * attempts)
                else {
                    stop()
                    exhausted()
                }
            }
        }
    }

    companion object {
        internal const val COALESCE_MS = 300L
        internal const val STALE_AFTER_MS = 30_000L
        private const val MAX_ATTEMPTS = 3
    }
}
