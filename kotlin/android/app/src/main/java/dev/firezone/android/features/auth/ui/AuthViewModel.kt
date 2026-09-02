// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import dev.firezone.android.features.auth.AuthCallbackHandler
import dev.firezone.android.features.auth.AuthCallbackOutcome
import dev.firezone.android.features.auth.PendingAuthSession
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
        private val pendingAuthSession: PendingAuthSession,
        private val authCallbackHandler: AuthCallbackHandler,
    ) : ViewModel() {
        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow
        private var hasStartedAuthFlow = false
        private var isProcessingAuthCallback = false
        private var authState: String? = null

        fun startAuthFlow() {
            if (hasStartedAuthFlow) {
                return
            }
            hasStartedAuthFlow = true

            viewModelScope.launch {
                val state = generateRandomString(NONCE_LENGTH)
                val nonce = generateRandomString(NONCE_LENGTH)
                authState = state
                pendingAuthSession.begin(nonce = nonce, state = state)
                val config = repo.getConfigSync()
                val authUrl = "${config.authUrl}/${config.accountSlug}?state=$state&nonce=$nonce&as=gui-client"

                actionMutableStateFlow.value =
                    ViewAction.LaunchAuthFlow(authUrl)
            }
        }

        fun processAuthCallback(uri: Uri?) {
            isProcessingAuthCallback = true
            viewModelScope.launch {
                try {
                    val action = handleAuthCallback(uri)
                    if (action is ViewAction.AuthFlowError) {
                        cancelAuthFlow()
                    }
                    actionMutableStateFlow.value = action
                } finally {
                    isProcessingAuthCallback = false
                }
            }
        }

        internal suspend fun handleAuthCallback(uri: Uri?): ViewAction =
            when (val outcome = authCallbackHandler.handle(uri)) {
                is AuthCallbackOutcome.Success -> {
                    authState = null
                    ViewAction.AuthFlowComplete
                }

                is AuthCallbackOutcome.Error -> {
                    ViewAction.AuthFlowError(outcome.errors)
                }
            }

        fun cancelAuthFlow() {
            val state = authState ?: return
            pendingAuthSession.cancel(state)
            authState = null
        }

        fun canRestoreAuthFlow(): Boolean =
            hasStartedAuthFlow ||
                isProcessingAuthCallback ||
                actionMutableStateFlow.value != null ||
                pendingAuthSession.hasPendingRequest()

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

            data object AuthFlowComplete : ViewAction()

            data class AuthFlowError(
                val errors: List<String>,
            ) : ViewAction()
        }

        internal companion object {
            private const val NONCE_LENGTH = 32
        }
    }
