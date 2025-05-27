/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
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

        // This flag is used to ensure that the initial launch check is only performed once, so
        // that we can differentiate between a fresh launch and subsequent resumes for the connect
        // on start logic.
        private var hasPerformedInitialLaunchCheck = false

        internal fun checkTunnelState(
            context: Context,
            isInitialLaunch: Boolean = false,
        ) {
            viewModelScope.launch {
                // Stay a while and enjoy the logo
                delay(REQUEST_DELAY)

                // If this is an 'initial launch' call, but we've already handled the
                // initial launch logic for this ViewModel instance, then do nothing.
                if (isInitialLaunch && hasPerformedInitialLaunchCheck) {
                    return@launch
                }

                if (!hasVpnPermissions(context) && applicationMode != ApplicationMode.TESTING) {
                    actionMutableLiveData.postValue(ViewAction.NavigateToVpnPermission)
                } else {
                    val token = applicationRestrictions.getString("token") ?: repo.getTokenSync()
                    val connectOnStart = repo.getConfigSync().connectOnStart

                    // Determine if the tunnel should connect:
                    // 1. If it's an initial launch AND connectOnStart is true.
                    // OR
                    // 2. If it's NOT an initial launch (meaning it's a resume), always try to connect if a token exists.
                    if (!token.isNullOrBlank() && (isInitialLaunch && connectOnStart || !isInitialLaunch)) {
                        // token will be re-read by the TunnelService
                        if (!TunnelService.isRunning(context)) TunnelService.start(context)

                        actionMutableLiveData.postValue(ViewAction.NavigateToSession)
                    } else {
                        actionMutableLiveData.postValue(ViewAction.NavigateToSignIn)
                    }
                }
            }

            // Set the flag to true after the initial launch check is performed
            if (isInitialLaunch) {
                hasPerformedInitialLaunchCheck = true
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
