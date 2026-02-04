// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.ContextCompat
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.ApplicationMode
import dev.firezone.android.core.data.Repository
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
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
        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow

        internal fun checkTunnelState(
            context: Context,
            isInitialLaunch: Boolean = false,
        ) {
            viewModelScope.launch {
                // Stay a while and enjoy the logo
                delay(REQUEST_DELAY)

                // If we don't have VPN permission, we can't continue.
                if (!hasVpnPermissions(context) && applicationMode != ApplicationMode.TESTING) {
                    actionMutableStateFlow.value = ViewAction.NavigateToVpnPermission
                    return@launch
                }

                // Check if we need to request notification permission (only once)
                if (shouldRequestNotificationPermission(context)) {
                    actionMutableLiveData.postValue(ViewAction.NavigateToNotificationPermission)
                    return@launch
                }

                val token = applicationRestrictions.getString("token") ?: repo.getTokenSync()

                // If we don't have a token, we can't connect.
                if (token.isNullOrBlank()) {
                    actionMutableStateFlow.value = ViewAction.NavigateToSignIn
                    return@launch
                }

                val isRunning = TunnelService.isRunning(context)

                // If the service is already running, we can go directly to the session.
                if (isRunning) {
                    actionMutableStateFlow.value = ViewAction.NavigateToSession
                    return@launch
                }

                val connectOnStart = repo.getConfigSync().connectOnStart

                // If this is the initial launch and connectOnStart is true, try to connect
                if (isInitialLaunch && connectOnStart) {
                    TunnelService.start(context)
                    actionMutableStateFlow.value = ViewAction.NavigateToSession
                    return@launch
                }

                // If we get here, we shouldn't start the tunnel, so show the sign in screen
                actionMutableStateFlow.value = ViewAction.NavigateToSignIn
            }
        }

        internal fun clearAction() {
            actionMutableStateFlow.value = null
        }

        private fun hasVpnPermissions(context: Context): Boolean = android.net.VpnService.prepare(context) == null

        private fun shouldRequestNotificationPermission(context: Context): Boolean {
            // Only request on Android 13+ where runtime permission is required
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return false
            }

            // Check if we've already requested permission
            if (repo.hasRequestedNotificationPermission()) {
                return false
            }

            // Check if permission is already granted
            val isGranted =
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED

            // If already granted, mark as requested and don't show the screen
            if (isGranted) {
                repo.setNotificationPermissionRequested()
                return false
            }

            // Permission not granted and not yet requested
            return true
        }

        internal sealed class ViewAction {
            object NavigateToVpnPermission : ViewAction()

            object NavigateToNotificationPermission : ViewAction()

            object NavigateToSettings : ViewAction()

            object NavigateToSignIn : ViewAction()

            object NavigateToSession : ViewAction()
        }
    }
