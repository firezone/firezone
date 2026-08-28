// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.security.SecureRandom
import javax.inject.Inject

@HiltViewModel
internal class AuthViewModel
    @Inject
    constructor(
        private val repo: Repository,
        savedStateHandle: SavedStateHandle,
    ) : ViewModel() {
        private val requestState = AuthRequestState(savedStateHandle)
        private val actionMutableStateFlow =
            MutableStateFlow<ViewAction?>(requestState.issuedUrl?.let(ViewAction::LaunchAuthFlow))
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow

        fun onActivityResume() {
            if (!requestState.claimGeneration()) {
                return
            }

            viewModelScope.launch {
                try {
                    val state = generateRandomString(NONCE_LENGTH)
                    val nonce = generateRandomString(NONCE_LENGTH)
                    repo.saveNonceAndStateSync(nonce = nonce, state = state)
                    val config = repo.getConfigSync()
                    val authUrl = "${config.authUrl}/${config.accountSlug}?state=$state&nonce=$nonce&as=gui-client"

                    requestState.markIssued(authUrl)
                    actionMutableStateFlow.value =
                        ViewAction.LaunchAuthFlow(authUrl)
                } finally {
                    requestState.releaseGeneration()
                }
            }
        }

        fun clearAction() {
            actionMutableStateFlow.value = null
        }

        private fun generateRandomString(length: Int): String {
            val random = SecureRandom.getInstanceStrong()
            val bytes = ByteArray(length)
            random.nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it) }
        }

        internal sealed class ViewAction {
            data class LaunchAuthFlow(
                val url: String,
            ) : ViewAction()
        }

        internal companion object {
            private const val NONCE_LENGTH = 32
        }
    }
