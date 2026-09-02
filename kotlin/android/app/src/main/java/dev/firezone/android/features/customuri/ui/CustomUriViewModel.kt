// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.content.Intent
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.Firebase
import com.google.firebase.crashlytics.crashlytics
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.features.auth.AuthCallbackHandler
import dev.firezone.android.features.auth.AuthCallbackOutcome
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
        private val authCallbackHandler: AuthCallbackHandler,
    ) : ViewModel() {
        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow
        private val callbackMutex = Mutex()
        private var hasPublishedTerminalAction = false

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

        internal suspend fun handleCustomUri(intent: Intent): ViewAction =
            when (val outcome = authCallbackHandler.handle(intent.data)) {
                is AuthCallbackOutcome.Success -> ViewAction.AuthFlowComplete
                is AuthCallbackOutcome.Error -> ViewAction.AuthFlowError(outcome.errors)
            }

        fun clearAction() {
            actionMutableStateFlow.value = null
        }

        companion object {
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
