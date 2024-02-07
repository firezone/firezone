/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.data

import android.content.SharedPreferences
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.CONFIG_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.RESOURCES_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.ROUTES_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.STATE_KEY
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.Tunnel
import dev.firezone.android.tunnel.model.TunnelConfig
import javax.inject.Inject

@OptIn(ExperimentalStdlibApi::class)
class TunnelRepositoryImpl
    @Inject
    constructor(
        private val sharedPreferences: SharedPreferences,
        private val moshi: Moshi,
    ) : TunnelRepository {
        override fun addListener(callback: SharedPreferences.OnSharedPreferenceChangeListener) {
            sharedPreferences.registerOnSharedPreferenceChangeListener(callback)
        }

        override fun removeListener(callback: SharedPreferences.OnSharedPreferenceChangeListener) {
            sharedPreferences.unregisterOnSharedPreferenceChangeListener(callback)
        }

        override fun setConfig(config: TunnelConfig) {
            val json = moshi.adapter<TunnelConfig>().toJson(config)
            sharedPreferences.edit().putString(CONFIG_KEY, json).apply()
        }

        override fun getConfig(): TunnelConfig? {
            sharedPreferences.getString(CONFIG_KEY, null)?.let {
                return moshi.adapter<TunnelConfig>().fromJson(it)
            }

            return null
        }

        override fun setState(state: Tunnel.State) {
            sharedPreferences.edit().putString(STATE_KEY, state.name).apply()
        }

        override fun getState(): Tunnel.State {
            sharedPreferences.getString(STATE_KEY, null)?.let {
                return Tunnel.State.valueOf(it)
            }

            return Tunnel.State.Closed
        }

        override fun setResources(resources: List<Resource>) {
            val json = moshi.adapter<List<Resource>>().toJson(resources)
            sharedPreferences.edit().putString(RESOURCES_KEY, json).apply()
        }

        override fun getResources(): List<Resource>? {
            sharedPreferences.getString(RESOURCES_KEY, null)?.let {
                return moshi.adapter<List<Resource>>().fromJson(it)
            }

            return null
        }

        override fun setRoutes(routes: List<Cidr>) {
            val json = moshi.adapter<List<Cidr>>().toJson(routes)
            sharedPreferences.edit().putString(ROUTES_KEY, json).apply()
        }

        override fun addRoute(route: Cidr) {
            getRoutes()?.toMutableList()?.run {
                add(route)
                val json = moshi.adapter<List<Cidr>>().toJson(this)
                sharedPreferences.edit().putString(ROUTES_KEY, json).apply()
            }
        }

        override fun removeRoute(route: Cidr) {
            getRoutes()?.toMutableList()?.run {
                remove(route)
                val json = moshi.adapter<List<Cidr>>().toJson(this)
                sharedPreferences.edit().putString(ROUTES_KEY, json).apply()
            }
        }

        override fun getRoutes(): List<Cidr>? {
            sharedPreferences.getString(ROUTES_KEY, null)?.let {
                return moshi.adapter<List<Cidr>>().fromJson(it)
            }

            return null
        }

        override fun clearAll() {
            sharedPreferences.edit().clear().apply()
        }
    }
