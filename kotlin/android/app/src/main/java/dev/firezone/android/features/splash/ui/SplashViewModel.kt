// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import android.content.Context
import android.os.Bundle
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.ApplicationMode
import dev.firezone.android.core.data.Repository
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import javax.inject.Inject

private const val REQUEST_DELAY = 1000L

@HiltViewModel
internal class SplashViewModel
    @Inject
    constructor(
        private val repo: Repository,
        private val applicationRestrictions: Bundle,
        private val applicationMode: ApplicationMode,
    ) : ViewModel() {
        private val actionMutableLiveData = MutableLiveData<ViewAction>()
        val actionLiveData: LiveData<ViewAction> = actionMutableLiveData

        internal fun checkTunnelState(
            context: Context,
            isInitialLaunch: Boolean = false,
        ) {
            viewModelScope.launch {
                // Stay a while and enjoy the logo
                delay(REQUEST_DELAY)

                // If we don't have VPN permission, we can't continue.
                if (!hasVpnPermissions(context) && applicationMode != ApplicationMode.TESTING) {
                    actionMutableLiveData.postValue(ViewAction.NavigateToVpnPermission)
                    return@launch
                }

                val token = applicationRestrictions.getString("token") ?: repo.getTokenSync()

                // If we don't have a token, we can't connect.
                if (token.isNullOrBlank()) {
                    actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
                    return@launch
                }

                val isRunning = TunnelService.isRunning(context)

                // If the service is already running, we can go directly to the session.
                if (isRunning) {
                    actionMutableLiveData.postValue(ViewAction.NavigateToSession)
                    return@launch
                }

                val connectOnStart = repo.getConfigSync().connectOnStart

                // If this is the initial launch and connectOnStart is true, try to connect
                if (isInitialLaunch && connectOnStart) {
                    TunnelService.start(context)
                    actionMutableLiveData.postValue(ViewAction.NavigateToSession)
                    return@launch
                }

                // If we get here, we shouldn't start the tunnel, so show the sign in screen
                actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
            }
        }

        private fun hasVpnPermissions(context: Context): Boolean = android.net.VpnService.prepare(context) == null

        internal sealed class ViewAction {
            object NavigateToVpnPermission : ViewAction()

            object NavigateToSettings : ViewAction()

            object NavigateToSignIn : ViewAction()

            object NavigateToSession : ViewAction()
        }
    }
