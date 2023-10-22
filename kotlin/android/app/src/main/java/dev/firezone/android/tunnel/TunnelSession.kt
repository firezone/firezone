/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel

object TunnelSession {
    external fun connect(
        token: String,
        deviceId: String,
        logDir: String,
        callback: Any,
    ): Long

    external fun disconnect(session: Long): Boolean
}
