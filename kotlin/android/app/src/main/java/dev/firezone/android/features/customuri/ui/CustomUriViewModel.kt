/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.customuri.ui

import android.content.Intent
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.SaveTokenUseCase
import dev.firezone.android.core.domain.preference.ValidateStateUseCase
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
internal class CustomUriViewModel
    @Inject
    constructor(
        private val validateStateUseCase: ValidateStateUseCase,
        private val saveTokenUseCase: SaveTokenUseCase,
    ) : ViewModel() {
        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        fun parseCustomUri(intent: Intent) {
            Log.d("CustomUriViewModel", "Parsing app link...")
            viewModelScope.launch {
                Log.d("CustomUriViewModel", "viewmodelScope.launch")
                when (intent.data?.lastPathSegment) {
                    PATH_CALLBACK -> {
                        Log.d("CustomUriViewModel", "PATH_CALLBACK")
                        intent.data?.getQueryParameter(QUERY_CLIENT_STATE)?.let { state ->
                            Log.d("CustomUriViewModel", "state: $state")
                            if (validateStateUseCase(state).firstOrNull() == true) {
                                Log.d("CustomUriViewModel", "Valid state parameter. Continuing to save state...")
                            } else {
                                Log.d("CustomUriViewModel", "Invalid state parameter! Ignoring...")
                                actionMutableLiveData.postValue(ViewAction.ShowError)
                            }
                            intent.data?.getQueryParameter(QUERY_CLIENT_AUTH_FRAGMENT)?.let { fragment ->
                                if (fragment.isNotBlank()) {
                                    Log.d("CustomUriViewModel", "Found valid auth fragment in response")
                                    saveTokenUseCase(fragment).collect()
                                } else {
                                    Log.d("CustomUriViewModel", "Didn't find auth fragment in response!")
                                }
                            }

                            actionMutableLiveData.postValue(ViewAction.AuthFlowComplete)
                        }
                    }
                    else -> {
                        Log.d("CustomUriViewModel", "Unknown path segment: ${intent.data?.lastPathSegment}")
                    }
                }
            }
        }

        companion object {
            private const val PATH_CALLBACK = "handle_client_sign_in_callback"
            private const val QUERY_CLIENT_STATE = "state"
            private const val QUERY_CLIENT_AUTH_FRAGMENT = "fragment"
            private const val QUERY_ACTOR_NAME = "actor_name"
            private const val QUERY_IDENTITY_PROVIDER_IDENTIFIER = "identity_provider_identifier"
        }

        internal sealed class ViewAction {
            object AuthFlowComplete : ViewAction()

            object ShowError : ViewAction()
        }
    }
