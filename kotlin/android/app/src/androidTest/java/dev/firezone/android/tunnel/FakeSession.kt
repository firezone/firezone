// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import android.os.ParcelFileDescriptor
import kotlinx.coroutines.channels.Channel
import uniffi.connlib.AndroidSessionConfig
import uniffi.connlib.ClientTlsIdentity
import uniffi.connlib.Event

// Stands in for a connlib session. `disconnect` ends the event stream, which is the part of the
// real session's behaviour the service's event loop is built around.
class FakeSession(
    val config: AndroidSessionConfig,
    val tlsIdentity: ClientTlsIdentity?,
) : TunnelSession {
    private val events = Channel<Event>(Channel.UNLIMITED)

    // connlib owns the descriptor it is handed. Leaving it open keeps the interface the
    // service established alive, and the framework holds the service bound while one is up,
    // which no amount of stopping the service undoes.
    private var tun: ParcelFileDescriptor? = null

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
        tun?.close()
        tun = ParcelFileDescriptor.adoptFd(fd)
    }

    override fun close() {
        events.close()
        commands.close()
        tun?.close()
        tun = null
    }
}
