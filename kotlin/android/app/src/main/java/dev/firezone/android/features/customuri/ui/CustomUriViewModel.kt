/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.customuri.ui

import android.content.Intent
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.crashlytics.ktx.crashlytics
import com.google.firebase.ktx.Firebase
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import java.lang.IllegalStateException
import javax.inject.Inject

@HiltViewModel
internal class CustomUriViewModel
    @Inject
    constructor(
        private val repo: Repository,
    ) : ViewModel() {
        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        fun parseCustomUri(intent: Intent) {
            viewModelScope.launch {
                when (intent.data?.host) {
                    PATH_CALLBACK -> {
                        intent.data?.getQueryParameter(QUERY_ACTOR_NAME)?.let { actorName ->
                            Log.d("CustomUriViewModel", "Found actor name: $actorName")
                            repo.saveActorName(actorName).collect()
                        }
                        intent.data?.getQueryParameter(QUERY_CLIENT_STATE)?.let { state ->
                            if (repo.validateState(state).firstOrNull() == true) {
                                Log.d("CustomUriViewModel", "Valid state parameter. Continuing to save state...")
                            } else {
                                throw IllegalStateException("Invalid state parameter $state! Authentication will not succeed...")
                            }
                            intent.data?.getQueryParameter(QUERY_CLIENT_AUTH_FRAGMENT)?.let { fragment ->
                                if (fragment.isNotBlank()) {
                                    Log.d("CustomUriViewModel", "Found valid auth fragment in response")

                                    // Save token, then clear nonce and state since we don't
                                    // need to keep them around anymore
                                    repo.saveToken(fragment).collect()
                                    repo.clearNonce()
                                    repo.clearState()

                                    actionMutableLiveData.postValue(ViewAction.AuthFlowComplete)
                                } else {
                                    throw IllegalStateException("Invalid auth fragment $fragment! Authentication will not succeed...")
                                }
                            }
                        }
                    }
                    else -> {
                        Firebase.crashlytics.log("Unknown path segment: ${intent.data?.lastPathSegment}")
                        Log.e("CustomUriViewModel", "Unknown path segment: ${intent.data?.lastPathSegment}")
                    }
                }
            }
        }

        companion object {
            private const val PATH_CALLBACK = "handle_client_sign_in_callback"
            private const val QUERY_CLIENT_STATE = "state"
            private const val QUERY_CLIENT_AUTH_FRAGMENT = "fragment"
            private const val QUERY_ACTOR_NAME = "actor_name"
        }

        internal sealed class ViewAction {
            object AuthFlowComplete : ViewAction()
        }
    }
