// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.content.Intent
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.Firebase
import com.google.firebase.crashlytics.crashlytics
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.AuthCallbackResult
import dev.firezone.android.core.data.Repository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject

@HiltViewModel
internal class CustomUriViewModel
    @Inject
    constructor(
        private val repo: Repository,
    ) : ViewModel() {
        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow
        private val callbackMutex = Mutex()
        private var hasPublishedTerminalAction = false
        private var pendingHandoffState: String? = null

        fun parseCustomUri(intent: Intent) {
            viewModelScope.launch { processCustomUri(intent) }
        }

        internal suspend fun processCustomUri(intent: Intent) {
            callbackMutex.withLock {
                if (hasPublishedTerminalAction) {
                    return@withLock
                }

                val action = handleCustomUri(intent)
                hasPublishedTerminalAction = true
                if (action is ViewAction.AuthFlowError) {
                    action.errors.forEach { error ->
                        Firebase.crashlytics.log(error)
                        Log.e(TAG, error)
                    }
                }
                actionMutableStateFlow.value = action
            }
        }

        internal suspend fun handleCustomUri(intent: Intent): ViewAction {
            val uri = intent.data
            if (uri?.host != PATH_CALLBACK) {
                return ViewAction.AuthFlowError("Unknown path segment: ${uri?.lastPathSegment}")
            }

            val accountSlug = uri.getQueryParameter(QUERY_ACCOUNT_SLUG)
            val actorName = uri.getQueryParameter(QUERY_ACTOR_NAME)
            val state = uri.getQueryParameter(QUERY_CLIENT_STATE)
            val fragment = uri.getQueryParameter(QUERY_CLIENT_AUTH_FRAGMENT)
            val missingParameterErrors =
                buildList {
                    if (accountSlug.isNullOrBlank()) {
                        add("Account slug was missing or empty")
                    }
                    if (actorName.isNullOrBlank()) {
                        add("Actor name was missing or empty")
                    }
                    if (state.isNullOrBlank()) {
                        add("State parameter was missing or empty")
                    }
                    if (fragment.isNullOrBlank()) {
                        add("Auth fragment was missing or empty")
                    }
                }
            if (missingParameterErrors.isNotEmpty()) {
                return ViewAction.AuthFlowError(missingParameterErrors)
            }

            checkNotNull(accountSlug)
            checkNotNull(actorName)
            checkNotNull(state)
            checkNotNull(fragment)

            val result =
                repo.saveAuthCallbackIfStateValid(
                    state = state,
                    fragment = fragment,
                    accountSlug = accountSlug,
                    actorName = actorName,
                )
            return when (result) {
                AuthCallbackResult.NEW_HANDOFF,
                AuthCallbackResult.PENDING_HANDOFF,
                -> {
                    pendingHandoffState = state
                    ViewAction.AuthFlowComplete
                }

                AuthCallbackResult.INVALID -> {
                    ViewAction.AuthFlowError("Invalid state parameter")
                }
            }
        }

        fun acknowledgeAuthFlowComplete() {
            val state = pendingHandoffState ?: return
            repo.acknowledgeAuthCallbackHandoff(state)
            pendingHandoffState = null
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
