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
                val errors = mutableListOf<String>()
                when (intent.data?.host) {
                    PATH_CALLBACK -> {
                        intent.data?.getQueryParameter(QUERY_ACTOR_NAME)?.let { actorName ->
                            Log.d(TAG, "Found actor name: $actorName")
                            repo.saveActorName(actorName).collect()
                        }
                        intent.data?.getQueryParameter(QUERY_CLIENT_STATE)?.let { state ->
                            if (repo.validateState(state).firstOrNull() == true) {
                                Log.d(TAG, "Valid state parameter. Continuing to save state...")
                            } else {
                                val msg = "Invalid state parameter $state"
                                Firebase.crashlytics.log(msg)
                                Log.e(TAG, msg)
                                errors += msg
                            }
                        }
                        intent.data?.getQueryParameter(QUERY_CLIENT_AUTH_FRAGMENT)?.let { fragment ->
                            if (fragment.isNotBlank()) {
                                Log.d(TAG, "Found valid auth fragment in response")

                                // Save token, then clear nonce and state since we don't
                                // need to keep them around anymore
                                repo.saveToken(fragment).collect()
                                repo.clearNonce()
                                repo.clearState()
                            } else {
                                val msg = "Invalid auth fragment $fragment"
                                Firebase.crashlytics.log(msg)
                                Log.e(TAG, msg)
                                errors += msg
                            }
                        }
                    }
                    else -> {
                        val msg = "Unknown path segment: ${intent.data?.lastPathSegment}"
                        Firebase.crashlytics.log(msg)
                        Log.e(TAG, msg)
                        errors += msg
                    }
                }
                if (errors.isNotEmpty()) {
                    actionMutableLiveData.postValue(ViewAction.AuthFlowError(errors))
                } else {
                    Log.d(TAG, "Auth flow complete")
                    actionMutableLiveData.postValue(ViewAction.AuthFlowComplete)
                }
            }
        }

        companion object {
            private const val PATH_CALLBACK = "handle_client_sign_in_callback"
            private const val QUERY_CLIENT_STATE = "state"
            private const val QUERY_CLIENT_AUTH_FRAGMENT = "fragment"
            private const val QUERY_ACTOR_NAME = "actor_name"

            private const val TAG = "CustomUriViewModel"
        }

        internal sealed class ViewAction {
            data object AuthFlowComplete : ViewAction()

            data class AuthFlowError(val errors: Iterable<String>) : ViewAction()
        }
    }
