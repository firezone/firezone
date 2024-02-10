/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.features.splash.ui

import android.content.Context
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.domain.preference.GetConfigUseCase
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import javax.inject.Inject

private const val REQUEST_DELAY = 1000L

@HiltViewModel
internal class SplashViewModel
    @Inject
    constructor(
        private val getConfigUseCase: GetConfigUseCase,
    ) : ViewModel() {
        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        internal fun checkTunnelState(context: Context) {
            viewModelScope.launch {
                // Stay a while and enjoy the logo
                delay(REQUEST_DELAY)
                if (!hasVpnPermissions(context)) {
                    actionMutableLiveData.postValue(ViewAction.NavigateToVpnPermission)
                } else {
                    getConfigUseCase.invoke().collect {
                        if (it.token.isNullOrBlank()) {
                            actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
                        } else {
                            // token will be re-read by the TunnelService
                            if (!TunnelService.isRunning(context)) TunnelService.start(context)

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
