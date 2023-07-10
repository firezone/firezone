package dev.firezone.connlib.session

interface SessionCallback {

    fun onConnect(status: String): Boolean

    fun onUpdateResources(resources: String): Boolean

    fun onSetTunnelAddresses(addresses: String): Boolean
}
