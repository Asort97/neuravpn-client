package com.neuravpn.app.vpn

/** One native registration per process; the active service can change without leaking callbacks. */
internal class AndroidXraySocketProtector(
    private val register: ((Long) -> Boolean) -> Unit,
) {
    private data class Target(val owner: Any, val protect: (Long) -> Boolean)
    @Volatile private var target: Target? = null
    private var registered = false

    // Activation/deactivation is serialized with the native core lifecycle.
    fun activate(owner: Any, protect: (Long) -> Boolean) {
        val previous = target
        target = Target(owner, protect)
        try {
            if (!registered) {
                register { fd -> target?.protect?.invoke(fd) ?: false }
                registered = true
            }
        } catch (error: Throwable) {
            target = previous
            throw error
        }
    }

    fun deactivate(owner: Any) {
        if (target?.owner === owner) target = null
    }
}
