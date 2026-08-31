// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.core.data.Repository
import dev.firezone.android.tunnel.TunnelService.Companion.State
import dev.firezone.android.tunnel.model.ConnectedDevice
import dev.firezone.android.tunnel.model.Resource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
internal class SessionViewModel
    @Inject
    constructor() : ViewModel() {
        // Must be `internal` because Dagger does not support injection into `private` fields
        @Inject
        internal lateinit var repo: Repository
        private val _serviceStatusStateFlow = MutableStateFlow<State?>(null)
        private val _resourcesStateFlow = MutableStateFlow<List<Resource>>(emptyList())
        private val _connectedDevicesStateFlow = MutableStateFlow<List<ConnectedDevice>>(emptyList())
        private val _actorNameStateFlow = MutableStateFlow<String?>(null)

        val serviceStatusStateFlow: StateFlow<State?>
            get() = _serviceStatusStateFlow
        val resourcesStateFlow: StateFlow<List<Resource>>
            get() = _resourcesStateFlow
        val connectedDevicesStateFlow: StateFlow<List<ConnectedDevice>>
            get() = _connectedDevicesStateFlow
        val actorNameStateFlow: StateFlow<String?>
            get() = _actorNameStateFlow

        // Internal getters for TunnelService to update state
        internal fun getServiceStatusMutableStateFlow(): MutableStateFlow<State?> = _serviceStatusStateFlow

        internal fun getResourcesMutableStateFlow(): MutableStateFlow<List<Resource>> = _resourcesStateFlow

        internal fun getConnectedDevicesMutableStateFlow(): MutableStateFlow<List<ConnectedDevice>> = _connectedDevicesStateFlow

        internal fun getActorNameMutableStateFlow(): MutableStateFlow<String?> = _actorNameStateFlow

        val favorites: StateFlow<Favorites>
            get() = repo.favorites

        fun addFavoriteResource(id: String) {
            repo.addFavoriteResource(id)
        }

        fun removeFavoriteResource(id: String) {
            repo.removeFavoriteResource(id)
        }

        fun clearToken() = repo.clearToken()
    }
