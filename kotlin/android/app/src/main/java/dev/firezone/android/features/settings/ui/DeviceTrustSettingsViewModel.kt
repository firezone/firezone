// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.net.Uri
import android.os.Bundle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.KeyChain
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
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
        private val applicationRestrictions: Bundle,
        private val keyChain: KeyChain,
    ) : ViewModel() {
        private val uiMutableStateFlow = MutableStateFlow(UiState())
        val uiStateFlow: StateFlow<UiState> = uiMutableStateFlow
        private var loadJob: Job? = null

        fun loadDetails() {
            val alias = repository.getX509CertificateAliasSync(applicationRestrictions)

            // No alias yet means the policy named none, so it is the user's turn.
            uiMutableStateFlow.value =
                UiState(alias = alias, isLoading = alias != null, needsSelection = alias == null)

            loadJob?.cancel()

            if (alias == null) {
                return
            }

            loadJob =
                viewModelScope.launch {
                    val chain =
                        try {
                            withContext(Dispatchers.IO) {
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

        /** Records the alias the user released, which the fragment has checked is a device certificate. */
        fun onAliasSelected(alias: String) {
            repository.saveX509CertificateAliasSync(alias)
            loadDetails()
        }

        /** The portal the certificate is meant for, shown by Android in the chooser dialog. */
        fun keyChainRequestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()

        internal data class UiState(
            val alias: String? = null,
            val isLoading: Boolean = false,
            val details: List<DetailField> = emptyList(),
            /** Whether the user has to release the device certificate before the app can use one. */
            val needsSelection: Boolean = false,
        )

        private companion object {
            private const val TAG = "DeviceTrustSettingsViewModel"
        }
    }
