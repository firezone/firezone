package dev.firezone.connlib

interface SessionCallback {

    fun onConnect(addresses: String): Boolean

    fun onUpdateResources(resources: String): Boolean

    fun onDisconnect(): Boolean
}
