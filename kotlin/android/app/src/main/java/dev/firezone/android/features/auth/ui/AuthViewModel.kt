/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.auth.ui

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.auth.GetNonceUseCase
import dev.firezone.android.core.domain.auth.GetStateUseCase
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import java.lang.Exception
import javax.inject.Inject

@HiltViewModel
internal class AuthViewModel
    @Inject
    constructor(
        private val getConfigUseCase: GetConfigUseCase,
        private val getStateUseCase: GetStateUseCase,
        private val getNonceUseCase: GetNonceUseCase,
    ) : ViewModel() {
        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        private var authFlowLaunched: Boolean = false

        fun onActivityResume() =
            try {
                viewModelScope.launch {
                    val config =
                        getConfigUseCase()
                            .firstOrNull() ?: throw Exception("config cannot be null")

                    val state =
                        getStateUseCase()
                            .firstOrNull() ?: throw Exception("state cannot be null")

                    val nonce =
                        getNonceUseCase()
                            .firstOrNull() ?: throw Exception("nonce cannot be null")

                    actionMutableLiveData.postValue(
                        if (authFlowLaunched || config.token != null) {
                            ViewAction.NavigateToSignIn
                        } else {
                            authFlowLaunched = true
                            ViewAction.LaunchAuthFlow(
                                url =
                                    "${config.authBaseUrl}" +
                                        "?state=$state&nonce=$nonce&client_platform=android",
                            )
                        },
                    )
                }
            } catch (e: Exception) {
                actionMutableLiveData.postValue(ViewAction.ShowError)
            }

        internal sealed class ViewAction {
            data class LaunchAuthFlow(val url: String) : ViewAction()

            object NavigateToSignIn : ViewAction()

            object ShowError : ViewAction()
        }
    }
