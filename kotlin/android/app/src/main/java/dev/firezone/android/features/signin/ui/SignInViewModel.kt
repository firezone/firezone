// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.x509.CertificateUser
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import uniffi.x509claims.Identity
import javax.inject.Inject

@HiltViewModel
internal class SignInViewModel
    @Inject
    constructor(
        private val certificateUser: CertificateUser,
    ) : ViewModel() {
        private val certificateIdentityMutableStateFlow = MutableStateFlow<Identity>(Identity.Absent)

        /** Who the configured client certificate says is connecting, which decides what we offer. */
        val certificateIdentityStateFlow: StateFlow<Identity> = certificateIdentityMutableStateFlow

        fun refreshCertificateIdentity() {
            viewModelScope.launch {
                certificateIdentityMutableStateFlow.value = certificateUser.identity()
            }
        }
    }
