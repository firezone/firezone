// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import java.util.concurrent.atomic.AtomicBoolean

internal class OwnedTunFileDescriptor(
    private val fd: Int,
    private val closeFd: (Int) -> Unit,
) : AutoCloseable {
    private val owned = AtomicBoolean(true)

    fun transferTo(consumer: (Int) -> Unit) {
        check(owned.compareAndSet(true, false)) { "TUN file descriptor ownership was already released" }

        try {
            consumer(fd)
        } catch (error: Throwable) {
            try {
                closeFd(fd)
            } catch (closeError: Throwable) {
                error.addSuppressed(closeError)
            }
            throw error
        }
    }

    override fun close() {
        if (owned.compareAndSet(true, false)) {
            closeFd(fd)
        }
    }
}
