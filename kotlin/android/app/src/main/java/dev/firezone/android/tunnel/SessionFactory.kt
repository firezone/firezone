// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import uniffi.connlib.AndroidSessionConfig
import uniffi.connlib.ClientTlsIdentity
import uniffi.connlib.EventStream
import uniffi.connlib.SessionInterface

// A connlib session together with the `close` that releases it.
interface TunnelSession :
    SessionInterface,
    AutoCloseable

// A session together with its event stream, which is handed out only once.
data class TunnelConnection(
    val session: TunnelSession,
    val events: EventStream,
) : AutoCloseable by session

// Opens connlib sessions. Tests bind a factory handing out a scripted session, which is
// what puts the service's event loop within reach of a test that has no portal.
fun interface SessionFactory {
    fun open(
        config: AndroidSessionConfig,
        tlsIdentity: ClientTlsIdentity?,
    ): TunnelConnection
}
