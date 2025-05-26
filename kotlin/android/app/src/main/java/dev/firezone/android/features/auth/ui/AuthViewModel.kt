/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.auth.ui

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.launch
import java.security.SecureRandom
import javax.inject.Inject

@HiltViewModel
internal class AuthViewModel
    @Inject
    constructor(
        private val repo: Repository,
    ) : ViewModel() {
        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        private var authFlowLaunched: Boolean = false

        fun onActivityResume() =
            viewModelScope.launch {
                val state = generateRandomString(NONCE_LENGTH)
                val nonce = generateRandomString(NONCE_LENGTH)
                repo.saveNonceSync(nonce)
                repo.saveStateSync(state)
                val config = repo.getConfigSync()
                val token = repo.getTokenSync()

                actionMutableLiveData.postValue(
                    if (authFlowLaunched || token != null) {
                        ViewAction.NavigateToSignIn
                    } else {
                        authFlowLaunched = true
                        ViewAction.LaunchAuthFlow("${config.authUrl}/${config.accountSlug}?state=$state&nonce=$nonce&as=client")
                    },
                )
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

            object NavigateToSignIn : ViewAction()

            object ShowError : ViewAction()
        }

        internal companion object {
            private const val NONCE_LENGTH = 32
        }
    }
