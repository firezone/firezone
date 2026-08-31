// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import kotlinx.coroutines.channels.Channel
import uniffi.connlib.AndroidSessionConfig
import uniffi.connlib.Event

// Stands in for a connlib session. `disconnect` ends the event stream, which is the part of the
// real session's behaviour the service's event loop is built around.
class FakeSession(
    val config: AndroidSessionConfig,
) : TunnelSession {
    private val events = Channel<Event>(Channel.UNLIMITED)

    val commands = Channel<String>(Channel.UNLIMITED)

    fun emit(event: Event) {
        events.trySend(event).getOrThrow()
    }

    // Lets the service's event loop finish, which is what makes the service stop itself.
    fun endEventStream() {
        events.close()
    }

    override suspend fun nextEvent(): Event? = events.receiveCatching().getOrNull()

    override fun disconnect() {
        commands.trySend("disconnect")
        events.close()
    }

    override fun reset(reason: String) {
        commands.trySend("reset")
    }

    override fun setDns(dnsServers: List<String>) {
        commands.trySend("setDns=$dnsServers")
    }

    override fun setInternetResourceState(active: Boolean) {
        commands.trySend("setInternetResourceState=$active")
    }

    suspend fun awaitCommand(command: String) {
        while (commands.receive() != command) {
            // Skip the commands the service sends on its own, such as the initial resource state.
        }
    }

    override fun setTun(fd: Int) {
        commands.trySend("setTun")
    }

    override fun close() {
        events.close()
        commands.close()
    }
}
