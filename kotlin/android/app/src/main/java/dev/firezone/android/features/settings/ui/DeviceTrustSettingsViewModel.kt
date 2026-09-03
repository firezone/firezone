// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.ManagedConfiguration
import dev.firezone.android.core.di.IoDispatcher
import dev.firezone.android.core.x509.KeyChain
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.x509claims.DetailField
import uniffi.x509claims.parseClientCertificate
import javax.inject.Inject

@HiltViewModel
internal class DeviceTrustSettingsViewModel
    @Inject
    constructor(
        private val repository: Repository,
        private val managedConfigurationSource: ManagedConfigurationSource,
        private val keyChain: KeyChain,
        @IoDispatcher private val coroutineDispatcher: CoroutineDispatcher,
    ) : ViewModel() {
        private val uiMutableStateFlow = MutableStateFlow(UiState())
        val uiStateFlow: StateFlow<UiState> = uiMutableStateFlow
        private var refreshJob: Job? = null
        private var loadJob: Job? = null

        init {
            viewModelScope.launch {
                managedConfigurationSource.configuration.filterNotNull().collect(::showDetails)
            }
        }

        fun loadDetails() = refreshAndApply()

        /** Records the alias the user picked, unless the administrator dictates one. */
        fun onAliasSelected(alias: String) =
            refreshAndApply { managedConfiguration ->
                if (managedConfiguration.isX509CertificateAliasManaged()) {
                    // The administrator chooses the alias; what the prompt achieves is the KeyChain
                    // grant that lets us read the key behind it.
                    Log.d(TAG, "Keeping the managed alias after the user answered the KeyChain prompt")
                } else {
                    repository.saveX509CertificateAliasSync(alias)
                }
            }

        fun forgetSelection() =
            refreshAndApply { managedConfiguration ->
                if (!managedConfiguration.isX509CertificateAliasManaged()) {
                    repository.saveX509CertificateAliasSync(null)
                }
            }

        private fun refreshAndApply(action: ((ManagedConfiguration) -> Unit)? = null) {
            refreshJob?.cancel()
            refreshJob =
                viewModelScope.launch {
                    val previousConfiguration = managedConfigurationSource.configuration.value
                    val managedConfiguration = managedConfigurationSource.refresh()
                    action?.invoke(managedConfiguration)
                    if (action != null || managedConfiguration == previousConfiguration) {
                        showDetails(managedConfiguration)
                    }
                }
        }

        private fun showDetails(managedConfiguration: ManagedConfiguration) {
            val alias =
                managedConfiguration.resolveX509CertificateAlias(
                    repository.getUserX509CertificateAliasSync(),
                )
            val isManaged = managedConfiguration.isX509CertificateAliasManaged()

            uiMutableStateFlow.value =
                UiState(alias = alias, isManaged = isManaged, isLoading = alias != null)

            loadJob?.cancel()

            if (alias == null) {
                return
            }

            loadJob =
                viewModelScope.launch {
                    val chain =
                        try {
                            withContext(coroutineDispatcher) {
                                try {
                                    keyChain.certificateChain(alias)
                                } catch (exception: InterruptedException) {
                                    Thread.currentThread().interrupt()

                                    throw exception
                                }
                            }
                        } catch (exception: CancellationException) {
                            throw exception
                        } catch (exception: Exception) {
                            Log.d(TAG, "Could not read the certificate of alias '$alias'", exception)
                            uiMutableStateFlow.value = uiMutableStateFlow.value.copy(isLoading = false)

                            return@launch
                        }

                    if (chain.isNullOrEmpty()) {
                        uiMutableStateFlow.value =
                            uiMutableStateFlow.value.copy(
                                isLoading = false,
                                needsSelection = true,
                            )

                        return@launch
                    }

                    val certificate =
                        try {
                            parseClientCertificate(chain.first().encoded)
                        } catch (exception: Exception) {
                            Log.d(TAG, "Could not parse the certificate of alias '$alias'", exception)
                            uiMutableStateFlow.value = uiMutableStateFlow.value.copy(isLoading = false)

                            return@launch
                        }

                    if (certificate == null) {
                        Log.d(TAG, "Could not parse the certificate of alias '$alias'")
                    }

                    uiMutableStateFlow.value =
                        uiMutableStateFlow.value.copy(
                            isLoading = false,
                            details = certificate?.detailFields.orEmpty(),
                        )
                }
        }

        /** The portal the certificate is meant for, shown by Android in the chooser dialog. */
        fun keyChainRequestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()

        internal data class UiState(
            val alias: String? = null,
            val isManaged: Boolean = false,
            val isLoading: Boolean = false,
            val details: List<DetailField> = emptyList(),
            /** Whether Android must grant this app access to the configured certificate. */
            val needsSelection: Boolean = false,
        )

        private companion object {
            private const val TAG = "DeviceTrustSettingsViewModel"
        }
    }
