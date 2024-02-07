/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.tunnel.data

import android.content.SharedPreferences
import com.squareup.moshi.Moshi
import com.squareup.moshi.adapter
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.RESOURCES_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.ROUTES_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.STATE_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.DNS_ADDRESSES_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.IPV4_ADDRESS_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.IPV6_ADDRESS_KEY
import dev.firezone.android.tunnel.data.TunnelRepository.Companion.TunnelState
import dev.firezone.android.tunnel.model.Cidr
import dev.firezone.android.tunnel.model.Resource
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

        override fun setIPv4Address(address: String): Boolean {
            return sharedPreferences.edit().putString(IPV4_ADDRESS_KEY, address).commit()
        }

        override fun setIPv6Address(address: String): Boolean {
            return sharedPreferences.edit().putString(IPV6_ADDRESS_KEY, address).commit()
        }

        override fun setDnsAddresses(dnsAddresses: List<String>): Boolean {
            val json = moshi.adapter<List<String>>().toJson(dnsAddresses)
            return sharedPreferences.edit().putString(DNS_ADDRESSES_KEY, json).commit()
        }
        override fun setRoutes(routes: List<Cidr>): Boolean {
            val json = moshi.adapter<List<Cidr>>().toJson(routes)
            return sharedPreferences.edit().putString(ROUTES_KEY, json).commit()
        }

        override fun setState(state: TunnelState): Boolean {
            return sharedPreferences.edit().putString(STATE_KEY, state.name).commit()
        }

        override fun setResources(resources: List<Resource>): Boolean {
            val json = moshi.adapter<List<Resource>>().toJson(resources)
            return sharedPreferences.edit().putString(RESOURCES_KEY, json).commit()
        }

        override fun getIPv4Address(): String? {
            return sharedPreferences.getString(IPV4_ADDRESS_KEY, null)
        }

        override fun getIPv6Address(): String? {
            return sharedPreferences.getString(IPV6_ADDRESS_KEY, null)
        }

        override fun getDnsAddresses(): List<String>? {
            return sharedPreferences.getString(DNS_ADDRESSES_KEY, null)?.let {
                moshi.adapter<List<String>>().fromJson(it)
            }
        }

        override fun getState(): TunnelState {
            return sharedPreferences.getString(STATE_KEY, null)?.let {
                TunnelState.valueOf(it)
            } ?: TunnelState.Closed
        }


        override fun getResources(): List<Resource>? {
            return sharedPreferences.getString(RESOURCES_KEY, null)?.let {
                moshi.adapter<List<Resource>>().fromJson(it)
            }
        }

        // TODO: This needs to be debounced. See https://github.com/firezone/firezone/issues/3343
        override fun addRoute(route: Cidr) {
            getRoutes()?.toMutableList()?.run {
                add(route)
                val json = moshi.adapter<List<Cidr>>().toJson(this)
                sharedPreferences.edit().putString(ROUTES_KEY, json).commit()
            }
        }

        // TODO: This needs to be debounced. See https://github.com/firezone/firezone/issues/3343
        override fun removeRoute(route: Cidr) {
            getRoutes()?.toMutableList()?.run {
                remove(route)
                val json = moshi.adapter<List<Cidr>>().toJson(this)
                sharedPreferences.edit().putString(ROUTES_KEY, json).commit()
            }
        }

        override fun getRoutes(): List<Cidr>? {
            return sharedPreferences.getString(ROUTES_KEY, null)?.let {
                moshi.adapter<List<Cidr>>().fromJson(it)
            }
        }

        override fun clearAll() {
            sharedPreferences.edit().clear().commit()
        }
    }
