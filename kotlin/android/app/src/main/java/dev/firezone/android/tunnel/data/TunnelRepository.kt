/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.data

import android.content.SharedPreferences
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource

interface TunnelRepository {

    fun setIPv4Address(address: String): Boolean

    fun setIPv6Address(address: String): Boolean

    fun setDnsAddresses(dnsAddresses: List<String>): Boolean

    fun getIPv4Address(): String?

    fun getIPv6Address(): String?

    fun getDnsAddresses(): List<String>?

    fun setState(state: TunnelState): Boolean

    fun getState(): TunnelState

    fun setResources(resources: List<Resource>): Boolean

    fun getResources(): List<Resource>?

    fun setRoutes(routes: List<Cidr>): Boolean

    fun addRoute(route: Cidr)

    fun removeRoute(route: Cidr)

    fun getRoutes(): List<Cidr>?

    fun clearAll()

    fun addListener(callback: SharedPreferences.OnSharedPreferenceChangeListener)

    fun removeListener(callback: SharedPreferences.OnSharedPreferenceChangeListener)

    companion object {
        const val TAG = "TunnelRepository"
        const val STATE_KEY = "tunnelStateKey"
        const val RESOURCES_KEY = "tunnelResourcesKey"
        const val ROUTES_KEY = "tunnelRoutesKey"
        const val DNS_ADDRESSES_KEY = "tunnelDnsAddressesKey"
        const val IPV4_ADDRESS_KEY = "tunnelIpv4AddressKey"
        const val IPV6_ADDRESS_KEY = "tunnelIpv6AddressKey"
        enum class TunnelState {
            Connecting,
            Up,
            Down,
            Closed,
        }
    }
}
