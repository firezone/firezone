// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.X509Identity
import dev.firezone.android.core.x509.X509IdentityDetails
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

@HiltViewModel
internal class X509SettingsViewModel
    @Inject
    constructor(
        private val repository: Repository,
        private val x509Identity: X509Identity,
    ) : ViewModel() {
        private val _uiState = MutableStateFlow(UiState())
        val uiState: StateFlow<UiState> = _uiState
        private var loadJob: Job? = null

        fun loadDetails() {
            val alias = repository.getX509CertificateAliasSync()
            val isManaged = repository.isX509CertificateAliasManaged()
            _uiState.value =
                _uiState.value.copy(
                    alias = alias,
                    isManaged = isManaged,
                    isLoading = true,
                    summary = "",
                    details = "",
                    error = null,
                    isProfileSupported = null,
                )

            loadJob?.cancel()
            loadJob =
                viewModelScope.launch {
                    try {
                        val isProfileSupported =
                            withContext(Dispatchers.IO) {
                                x509Identity.isSupportedProfile()
                            }
                        if (!isProfileSupported) {
                            _uiState.value =
                                _uiState.value.copy(
                                    isLoading = false,
                                    isProfileSupported = false,
                                )
                            return@launch
                        }

                        _uiState.value = _uiState.value.copy(isProfileSupported = true)

                        val result =
                            withContext(Dispatchers.IO) {
                                x509Identity.details(alias = alias, isManaged = isManaged)
                            }
                        _uiState.value =
                            _uiState.value.copy(
                                isLoading = false,
                                isProfileSupported = true,
                                summary = result.summary,
                                details = result.textDescription(),
                            )
                    } catch (exception: CancellationException) {
                        throw exception
                    } catch (exception: Exception) {
                        Log.e(TAG, "Failed to load X.509 settings diagnostics", exception)
                        _uiState.value =
                            _uiState.value.copy(
                                isLoading = false,
                                error = exception.message ?: "The Android KeyChain could not be read.",
                            )
                    }
                }
        }

        fun onAliasSelected(alias: String?) {
            if (alias == null) return

            if (repository.isX509CertificateAliasManaged()) {
                Log.w(TAG, "Ignoring a user-selected alias because the X.509 alias is managed")
            } else {
                repository.saveSelectedX509CertificateAliasSync(alias)
            }
            loadDetails()
        }

        fun forgetSelection() {
            if (repository.isX509CertificateAliasManaged()) return

            repository.saveSelectedX509CertificateAliasSync(null)
            loadDetails()
        }

        fun keyChainRequestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()

        internal data class UiState(
            val alias: String? = null,
            val isManaged: Boolean = false,
            val isLoading: Boolean = true,
            val summary: String = "",
            val details: String = "",
            val error: String? = null,
            val isProfileSupported: Boolean? = null,
        )

        companion object {
            private const val TAG = "X509SettingsViewModel"
        }
    }

private fun X509IdentityDetails.textDescription(): String =
    buildString {
        sections.forEachIndexed { sectionIndex, section ->
            if (sectionIndex > 0) appendLine()
            appendLine("[${section.title}]")
            section.fields.forEach { field ->
                appendLine("${field.label}:")
                field.value.lineSequence().forEach { line -> appendLine("  $line") }
            }
        }
    }
