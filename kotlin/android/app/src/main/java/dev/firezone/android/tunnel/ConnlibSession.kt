/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.tunnel

object ConnlibSession {
    external fun connect(
        apiUrl: String,
        token: String,
        deviceId: String,
        deviceName: String,
        osVersion: String,
        logDir: String,
        logFilter: String,
        callback: Any,
        deviceInfo: String,
    ): Long

    external fun disconnect(connlibSession: Long): Boolean

    // `disabledResourceList` is a JSON array of Resource ID strings.
    external fun setDisabledResources(
        connlibSession: Long,
        disabledResourceList: String,
    ): Boolean

    external fun setDns(
        connlibSession: Long,
        dnsList: String,
    ): Boolean

    external fun setTun(
        connlibSession: Long,
        fd: Int,
    ): Boolean

    external fun reset(connlibSession: Long): Boolean
}
