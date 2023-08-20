package dev.firezone.connlib

object Session {
    external fun connect(fd: Int, controlPlaneUrl: String, token: String, callback: Any): Long
    external fun disconnect(session: Long): Boolean
}
