// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import kotlinx.coroutines.channels.Channel
import uniffi.connlib.AndroidSessionConfig
import uniffi.connlib.ClientTlsIdentity
import uniffi.connlib.Event

/**
 * Plays connlib for a debug launch: it reports the deployment the screenshot fixtures describe and
 * then goes quiet, so the app runs with no portal, no gateways and no TUN device.
 *
 * The service drives this through the same [TunnelSession] it drives a real session through, which
 * is what keeps its event loop, its notifications and its UI on the paths they ship with.
 */
object MockSessionFactory : SessionFactory {
    override fun open(
        config: AndroidSessionConfig,
        tlsIdentity: ClientTlsIdentity?,
    ): TunnelSession = MockSession()
}

private class MockSession : TunnelSession {
    private val events = Channel<Event>(Channel.UNLIMITED)

    init {
        // No `TunInterfaceUpdated`: that is what would have the service establish a TUN device.
        events.trySend(Event.ConnectedToPortal(accountSlug = MOCK_ACCOUNT_SLUG, actorName = MOCK_ACTOR_NAME))
        events.trySend(Event.ResourcesUpdated(resources = mockResources, connectedDevices = mockConnectedDevices))
    }

    override suspend fun nextEvent(): Event? = events.receiveCatching().getOrNull()

    override fun disconnect() {
        events.close()
    }

    override fun reset(reason: String) = Unit

    override fun setDns(dnsServers: List<String>) = Unit

    override fun setInternetResourceState(active: Boolean) = Unit

    override fun setTun(fd: Int) = Unit

    override fun close() {
        events.close()
    }
}
