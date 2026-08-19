// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.net.Uri
import android.os.Bundle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.LoadedX509Identity
import dev.firezone.android.core.x509.X509Identity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.x509claims.DetailField
import javax.inject.Inject

@HiltViewModel
internal class X509SettingsViewModel
    @Inject
    constructor(
        private val repository: Repository,
        private val applicationRestrictions: Bundle,
        private val x509Identity: X509Identity,
    ) : ViewModel() {
        private val uiMutableStateFlow = MutableStateFlow(UiState())
        val uiStateFlow: StateFlow<UiState> = uiMutableStateFlow
        private var loadJob: Job? = null

        fun loadDetails() {
            val alias = repository.getX509CertificateAliasSync(applicationRestrictions)
            val isManaged = repository.isX509CertificateAliasManaged(applicationRestrictions)

            uiMutableStateFlow.value =
                UiState(alias = alias, isManaged = isManaged, isLoading = alias != null)

            loadJob?.cancel()

            if (alias == null) {
                return
            }

            loadJob =
                viewModelScope.launch {
                    val identity =
                        try {
                            withContext(Dispatchers.IO) { x509Identity.load(alias) }
                        } catch (exception: CancellationException) {
                            throw exception
                        } catch (exception: Exception) {
                            Log.w(TAG, "Failed to read the client certificate diagnostics", exception)
                            uiMutableStateFlow.value =
                                uiMutableStateFlow.value.copy(
                                    isLoading = false,
                                    error = exception.message ?: exception.javaClass.simpleName,
                                )

                            return@launch
                        }

                    uiMutableStateFlow.value =
                        uiMutableStateFlow.value.copy(
                            isLoading = false,
                            details = identity?.diagnostics().orEmpty(),
                        )
                }
        }

        /** Records the alias the user picked, unless the administrator dictates one. */
        fun onAliasSelected(alias: String) {
            if (repository.isX509CertificateAliasManaged(applicationRestrictions)) {
                Log.w(TAG, "Ignoring a user-picked alias because the administrator configured one")
            } else {
                repository.saveX509CertificateAliasSync(alias)
            }

            loadDetails()
        }

        fun forgetSelection() {
            if (repository.isX509CertificateAliasManaged(applicationRestrictions)) {
                return
            }

            repository.saveX509CertificateAliasSync(null)
            loadDetails()
        }

        /** The portal the certificate is meant for, shown by Android in the chooser dialog. */
        fun keyChainRequestUri(): Uri? = runCatching { Uri.parse(repository.getConfigSync().apiUrl) }.getOrNull()

        internal data class UiState(
            val alias: String? = null,
            val isManaged: Boolean = false,
            val isLoading: Boolean = false,
            val details: String = "",
            val error: String? = null,
        )

        private companion object {
            private const val TAG = "X509SettingsViewModel"
        }
    }

/**
 * The certificate rendered for a support ticket.
 *
 * The rows come from the Rust parser, so this only lays them out and adds what the KeyChain itself
 * knows.
 */
private fun LoadedX509Identity.diagnostics(): String =
    (
        listOf(
            DetailField("KeyChain Alias", alias),
            DetailField("Certificates In Chain", certificateCount.toString()),
        ) + certificate?.detailFields.orEmpty()
    ).joinToString("\n") { field ->
        val value = field.value.lineSequence().joinToString("\n") { line -> "  $line" }

        "${field.label}:\n$value"
    }
