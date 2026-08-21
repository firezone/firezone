// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.CertificateUser
import dev.firezone.android.tunnel.TunnelService.Companion.State
import dev.firezone.android.tunnel.model.ConnectedDevice
import dev.firezone.android.tunnel.model.Resource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import uniffi.x509claims.UserIdentity
import javax.inject.Inject

@HiltViewModel
internal class SessionViewModel
    @Inject
    constructor(
        private val repo: Repository,
        private val certificateUser: CertificateUser,
    ) : ViewModel() {
        private val _serviceStatusStateFlow = MutableStateFlow<State?>(null)
        private val _resourcesStateFlow = MutableStateFlow<List<Resource>>(emptyList())
        private val _connectedDevicesStateFlow = MutableStateFlow<List<ConnectedDevice>>(emptyList())
        private val _certificateUserStateFlow = MutableStateFlow<UserIdentity?>(null)

        val serviceStatusStateFlow: StateFlow<State?>
            get() = _serviceStatusStateFlow
        val resourcesStateFlow: StateFlow<List<Resource>>
            get() = _resourcesStateFlow
        val connectedDevicesStateFlow: StateFlow<List<ConnectedDevice>>
            get() = _connectedDevicesStateFlow

        /** The user a configured client certificate authenticates, who has no token to sign out of. */
        val certificateUserStateFlow: StateFlow<UserIdentity?>
            get() = _certificateUserStateFlow

        // Internal getters for TunnelService to update state
        internal fun getServiceStatusMutableStateFlow(): MutableStateFlow<State?> = _serviceStatusStateFlow

        internal fun getResourcesMutableStateFlow(): MutableStateFlow<List<Resource>> = _resourcesStateFlow

        internal fun getConnectedDevicesMutableStateFlow(): MutableStateFlow<List<ConnectedDevice>> = _connectedDevicesStateFlow

        val favorites: StateFlow<Favorites>
            get() = repo.favorites

        // Actor name
        fun clearActorName() = repo.clearActorName()

        fun getActorName() = repo.getActorNameSync()

        fun refreshCertificateUser() {
            viewModelScope.launch {
                _certificateUserStateFlow.value = certificateUser.identity()
            }
        }

        fun addFavoriteResource(id: String) {
            repo.addFavoriteResource(id)
        }

        fun removeFavoriteResource(id: String) {
            repo.removeFavoriteResource(id)
        }

        fun clearToken() = repo.clearToken()
    }
