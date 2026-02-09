// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.content.Intent
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.Firebase
import com.google.firebase.crashlytics.crashlytics
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
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
        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow

        fun parseCustomUri(intent: Intent) {
            viewModelScope.launch {
                val accumulatedErrors = mutableListOf<String>()
                val error = { msg: String ->
                    accumulatedErrors += msg
                    Firebase.crashlytics.log(msg)
                    Log.e(TAG, msg)
                }

                when (intent.data?.host) {
                    PATH_CALLBACK -> {
                        intent.data?.getQueryParameter(QUERY_ACCOUNT_SLUG)?.let { accountSlug ->
                            repo.saveAccountSlug(accountSlug).collect()
                        }
                        intent.data?.getQueryParameter(QUERY_ACTOR_NAME)?.let { actorName ->
                            repo.saveActorName(actorName).collect()
                        }
                        intent.data?.getQueryParameter(QUERY_CLIENT_STATE)?.let { state ->
                            if (repo.validateState(state).firstOrNull() != true) {
                                error("Invalid state parameter $state")
                            }
                        }
                        intent.data?.getQueryParameter(QUERY_CLIENT_AUTH_FRAGMENT)?.let { fragment ->
                            if (fragment.isNotBlank()) {
                                // Save token, then clear nonce and state since we don't
                                // need to keep them around anymore
                                repo.saveToken(fragment).collect()
                                repo.clearNonce()
                                repo.clearState()
                            } else {
                                error("Auth fragment was empty")
                            }
                        }
                    }

                    else -> {
                        error("Unknown path segment: ${intent.data?.lastPathSegment}")
                    }
                }
                if (accumulatedErrors.isNotEmpty()) {
                    actionMutableStateFlow.value = ViewAction.AuthFlowError(accumulatedErrors)
                } else {
                    actionMutableStateFlow.value = ViewAction.AuthFlowComplete
                }
            }
        }

        fun clearAction() {
            actionMutableStateFlow.value = null
        }

        companion object {
            private const val PATH_CALLBACK = "handle_client_sign_in_callback"
            private const val QUERY_ACCOUNT_SLUG = "account_slug"
            private const val QUERY_CLIENT_STATE = "state"
            private const val QUERY_CLIENT_AUTH_FRAGMENT = "fragment"
            private const val QUERY_ACTOR_NAME = "actor_name"

            private const val TAG = "CustomUriViewModel"
        }

        internal sealed class ViewAction {
            data object AuthFlowComplete : ViewAction()

            data class AuthFlowError(
                val errors: Iterable<String>,
            ) : ViewAction() {
                constructor(vararg errors: String) : this(errors.toList())
            }
        }
    }
