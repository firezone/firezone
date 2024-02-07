/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.data

import android.content.SharedPreferences
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.Tunnel
import dev.firezone.android.tunnel.model.TunnelConfig

interface TunnelRepository {
    fun setConfig(config: TunnelConfig)

    fun getConfig(): TunnelConfig?

    fun setState(state: Tunnel.State)

    fun getState(): Tunnel.State

    fun setResources(resources: List<Resource>)

    fun getResources(): List<Resource>?

    fun setRoutes(routes: List<Cidr>)

    fun addRoute(route: Cidr)

    fun removeRoute(route: Cidr)

    fun getRoutes(): List<Cidr>?

    fun clearAll()

    fun addListener(callback: SharedPreferences.OnSharedPreferenceChangeListener)

    fun removeListener(callback: SharedPreferences.OnSharedPreferenceChangeListener)

    companion object {
        const val TAG = "TunnelRepository"
        const val CONFIG_KEY = "tunnelConfigKey"
        const val STATE_KEY = "tunnelStateKey"
        const val RESOURCES_KEY = "tunnelResourcesKey"
        const val ROUTES_KEY = "tunnelRoutesKey"
    }
}
