package dev.firezone.android.features.signin.ui

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
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
internal class SignInViewModel
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
                // We've already posted the initial action, so we can skip the rest of the checks
                if (isInitialLaunch && hasPerformedInitialLaunchCheck) {
                    return@launch
                }

                if (isInitialLaunch) {
                    hasPerformedInitialLaunchCheck = true
                }

                // If we don't have VPN permission, we can't continue.
                if (!hasVpnPermissions(context) && applicationMode != ApplicationMode.TESTING) {
                    actionMutableLiveData.postValue(ViewAction.NavigateToVpnPermission)
                    return@launch
                }

                val token = applicationRestrictions.getString("token") ?: repo.getTokenSync()
                val connectOnStart = repo.getConfigSync().connectOnStart

                // If we don't have a token, we can't connect.
                if (token.isNullOrBlank()) {
                    return@launch
                }

                // If it's the initial launch but connect on start isn't enabled, then do nothing.
                if (isInitialLaunch && !connectOnStart) {
                    return@launch
                }

                // If we reach here, we have a token and should attempt to connect.
                if (!TunnelService.isRunning(context)) {
                    TunnelService.start(context)
                }
                actionMutableLiveData.postValue(ViewAction.NavigateToSession)
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