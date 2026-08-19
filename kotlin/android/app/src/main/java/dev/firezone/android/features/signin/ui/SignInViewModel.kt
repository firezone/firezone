// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.signin.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.x509.CertificateUser
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import uniffi.x509claims.UserIdentity
import javax.inject.Inject

@HiltViewModel
internal class SignInViewModel
    @Inject
    constructor(
        private val certificateUser: CertificateUser,
    ) : ViewModel() {
        private val certificateUserMutableStateFlow = MutableStateFlow<UserIdentity?>(null)

        /** The user a configured client certificate authenticates, who needs no browser sign-in. */
        val certificateUserStateFlow: StateFlow<UserIdentity?> = certificateUserMutableStateFlow

        fun refreshCertificateUser() {
            viewModelScope.launch {
                certificateUserMutableStateFlow.value = certificateUser.identity()
            }
        }
    }
