// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import uniffi.connlib.CallbackException
import uniffi.connlib.ProtectSocket

/**
 * Excludes connlib's sockets from the VPN so its traffic isn't routed back into the tunnel.
 *
 * `protect` returns `null` when there is no service to protect through.
 */
internal class VpnProtectSocket(
    private val protect: (Int) -> Boolean?,
) : ProtectSocket {
    override fun protectSocket(fd: Int) {
        if (protect(fd) == false) {
            throw CallbackException.Failed("`VpnService.protect` failed for fd $fd")
        }
    }
}
