package dev.firezone.connlib.session

interface SessionCallback {

    fun onConnect(addresses: String): Boolean

    fun onUpdateResources(resources: String): Boolean

    fun onDisconnect(): Boolean
}
