// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import kotlinx.coroutines.channels.Channel
import uniffi.connlib.AndroidSessionConfig
import uniffi.connlib.ClientTlsIdentity
import java.util.concurrent.CopyOnWriteArrayList

// Deliberately outlives the per-test object graph: a service can still be running when the graph
// it was injected from is torn down, and the next test has to see the sessions it opens.
object FakeSessionFactory : SessionFactory {
    private val sessions = Channel<FakeSession>(Channel.UNLIMITED)
    private val handedOut = CopyOnWriteArrayList<FakeSession>()

    // Set to make the next `open` fail the way a connlib constructor would.
    @Volatile
    var failWith: (() -> Throwable)? = null

    @Volatile
    var opened: Int = 0
        private set

    override fun open(
        config: AndroidSessionConfig,
        tlsIdentity: ClientTlsIdentity?,
    ): TunnelSession {
        opened++
        failWith?.let { throw it() }

        return FakeSession(config, tlsIdentity).also {
            handedOut += it
            sessions.trySend(it).getOrThrow()
        }
    }

    suspend fun awaitSession(): FakeSession = sessions.receive()

    fun reset() {
        failWith = null
        opened = 0

        // A session still handing out events keeps the service's event loop alive, and a live
        // loop is what keeps a service the last test started from ever stopping.
        handedOut.forEach { it.endEventStream() }
        handedOut.clear()

        while (sessions.tryReceive().isSuccess) {
            // Drain whatever the last test left behind.
        }
    }
}
