package dev.firezone.connlib

public object Session {
    public external fun connect(portalURL: String, token: String, callback: Any): Long
    public external fun disconnect(session: Long): Boolean
    public external fun bumpSockets(session: Long): Boolean
    public external fun disableSomeRoamingForBrokenMobileSemantics(session: Long): Boolean
}
