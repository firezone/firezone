// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import android.os.Bundle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.X509_CERTIFICATE_ALIAS_RESTRICTION
import dev.firezone.android.core.x509.X509Identity
import dev.firezone.android.core.x509.X509UserIdentity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

@HiltViewModel
internal class SignInViewModel
    @Inject
    constructor(
        private val repository: Repository,
        private val applicationRestrictions: Bundle,
        private val x509Identity: X509Identity,
    ) : ViewModel() {
        private val _certificateUserIdentity = MutableStateFlow<X509UserIdentity?>(null)
        val certificateUserIdentity: StateFlow<X509UserIdentity?> = _certificateUserIdentity

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
                                "Could not read the X.509 user identity; using web sign-in",
                                exception,
                            )
                        }.getOrNull()
                    }
            }
        }

        private fun configuredX509Alias(): String? =
            applicationRestrictions
                .getString(X509_CERTIFICATE_ALIAS_RESTRICTION)
                ?.takeUnless { it.isBlank() || it == "null" }
                ?: if (applicationRestrictions.containsKey(X509_CERTIFICATE_ALIAS_RESTRICTION)) {
                    null
                } else {
                    repository.getX509CertificateAliasSync()
                }

        companion object {
            private const val TAG = "SignInViewModel"
        }
    }
