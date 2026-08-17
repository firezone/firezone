// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import android.os.Bundle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.X509_CERTIFICATE_ALIAS_RESTRICTION
import dev.firezone.android.core.x509.X509Identity
import dev.firezone.android.core.x509.X509UserIdentity
import dev.firezone.android.tunnel.TunnelService.Companion.State
import dev.firezone.android.tunnel.model.ConnectedDevice
import dev.firezone.android.tunnel.model.Resource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

@HiltViewModel
internal class SessionViewModel
    @Inject
    constructor(
        private val repo: Repository,
        private val applicationRestrictions: Bundle,
        private val x509Identity: X509Identity,
    ) : ViewModel() {
        private val _serviceStatusStateFlow = MutableStateFlow<State?>(null)
        private val _resourcesStateFlow = MutableStateFlow<List<Resource>>(emptyList())
        private val _connectedDevicesStateFlow = MutableStateFlow<List<ConnectedDevice>>(emptyList())
        private val _certificateUserIdentity = MutableStateFlow<X509UserIdentity?>(null)

        val serviceStatusStateFlow: StateFlow<State?>
            get() = _serviceStatusStateFlow
        val resourcesStateFlow: StateFlow<List<Resource>>
            get() = _resourcesStateFlow
        val connectedDevicesStateFlow: StateFlow<List<ConnectedDevice>>
            get() = _connectedDevicesStateFlow
        val certificateUserIdentity: StateFlow<X509UserIdentity?>
            get() = _certificateUserIdentity

        // Internal getters for TunnelService to update state
        internal fun getServiceStatusMutableStateFlow(): MutableStateFlow<State?> = _serviceStatusStateFlow

        internal fun getResourcesMutableStateFlow(): MutableStateFlow<List<Resource>> = _resourcesStateFlow

        internal fun getConnectedDevicesMutableStateFlow(): MutableStateFlow<List<ConnectedDevice>> = _connectedDevicesStateFlow

        val favorites: StateFlow<Favorites>
            get() = repo.favorites

        // Actor name
        fun clearActorName() = repo.clearActorName()

        fun getActorName() = repo.getActorNameSync()

        fun refreshCertificateUserIdentity() {
            viewModelScope.launch {
                _certificateUserIdentity.value =
                    withContext(Dispatchers.IO) {
                        runCatching {
                            if (!x509Identity.isSupportedProfile()) return@runCatching null
                            x509Identity.userIdentity(configuredX509Alias())
                        }.onFailure { exception ->
                            Log.w(
                                TAG,
                                "Could not refresh the connected X.509 user identity",
                                exception,
                            )
                        }.getOrNull()
                    }
            }
        }

        fun addFavoriteResource(id: String) {
            repo.addFavoriteResource(id)
        }

        fun removeFavoriteResource(id: String) {
            repo.removeFavoriteResource(id)
        }

        fun clearToken() = repo.clearToken()

        private fun configuredX509Alias(): String? =
            applicationRestrictions
                .getString(X509_CERTIFICATE_ALIAS_RESTRICTION)
                ?.takeUnless { it.isBlank() || it == "null" }
                ?: if (applicationRestrictions.containsKey(X509_CERTIFICATE_ALIAS_RESTRICTION)) {
                    null
                } else {
                    repo.getX509CertificateAliasSync()
                }

        companion object {
            private const val TAG = "SessionViewModel"
        }
    }
