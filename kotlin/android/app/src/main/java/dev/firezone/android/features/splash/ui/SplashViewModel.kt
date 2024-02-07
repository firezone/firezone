/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.splash.ui

import android.content.Context
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import javax.inject.Inject

private const val REQUEST_DELAY = 1000L

@HiltViewModel
internal class SplashViewModel
    @Inject
    constructor(
        private val useCase: GetConfigUseCase,
    ) : ViewModel() {
        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        internal fun checkUserState(context: Context) {
            viewModelScope.launch {
                delay(REQUEST_DELAY)
                if (!hasVpnPermissions(context)) {
                    actionMutableLiveData.postValue(ViewAction.NavigateToVpnPermission)
                } else {
                    useCase.invoke()
                        .collect { user ->
                            if (user.token.isNullOrBlank()) {
                                actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
                            } else {
                                actionMutableLiveData.postValue(ViewAction.NavigateToSession)
                            }
                        }
                }
            }
        }

        private fun hasVpnPermissions(context: Context): Boolean {
            return android.net.VpnService.prepare(context) == null
        }

        internal sealed class ViewAction {
            object NavigateToVpnPermission : ViewAction()

            object NavigateToSettings : ViewAction()

            object NavigateToSignIn : ViewAction()

            object NavigateToSession : ViewAction()
        }
    }
