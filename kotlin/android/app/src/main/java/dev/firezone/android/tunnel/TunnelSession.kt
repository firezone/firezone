package dev.firezone.android.tunnel

object TunnelSession {
    external fun connect(fd: Int, controlPlaneUrl: String, token: String, callback: Any): Long
    external fun disconnect(session: Long): Boolean
}
