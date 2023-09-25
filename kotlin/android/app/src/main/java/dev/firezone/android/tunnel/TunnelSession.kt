package dev.firezone.android.tunnel

object TunnelSession {
    external fun connect(controlPlaneUrl: String, token: String, deviceId: String, logDir: String, logFilter: String, callback: Any): Long
    external fun disconnect(session: Long): Boolean
}
