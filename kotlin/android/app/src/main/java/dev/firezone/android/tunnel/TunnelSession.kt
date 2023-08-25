package dev.firezone.android.tunnel

object TunnelSession {
    external fun connect(controlPlaneUrl: String, token: String, externalId: String, callback: Any): Long
    external fun disconnect(session: Long): Boolean
}
