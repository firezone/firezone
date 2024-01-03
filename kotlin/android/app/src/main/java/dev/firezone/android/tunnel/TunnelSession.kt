/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel

object TunnelSession {
    external fun connect(
        apiUrl: String,
        token: String,
        deviceId: String,
        deviceName: String,
        osVersion: String,
        logDir: String,
        logFilter: String,
        callback: Any,
    ): Long

    external fun disconnect(session: Long): Boolean
}
