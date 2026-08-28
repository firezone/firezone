// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.ContextCompat
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.ApplicationMode
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.CertificateAccess
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.Job
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
        private val certificateAccess: CertificateAccess,
        savedStateHandle: SavedStateHandle,
    ) : ViewModel() {
        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        private val launchFlow = SplashLaunchFlow(savedStateHandle)
        private var checkTunnelStateJob: Job? = null
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow

        internal fun checkTunnelState(context: Context) {
            checkTunnelStateJob?.cancel()
            checkTunnelStateJob =
                viewModelScope.launch {
                    // Stay a while and enjoy the logo
                    delay(REQUEST_DELAY)

                    // If we don't have VPN permission, we can't continue.
                    if (!hasVpnPermissions(context) && applicationMode != ApplicationMode.TESTING) {
                        publish(launchFlow.vpnPermissionRequired(), context)
                        return@launch
                    }

                    // Check if we need to request notification permission (only once)
                    if (shouldRequestNotificationPermission(context)) {
                        publish(launchFlow.notificationPermissionRequired(), context)
                        return@launch
                    }

                    // An administrator can configure a certificate that only the user can release, which
                    // is what a work profile on a personally-owned device looks like. Ask once per
                    // launch: pressing on without it only fails later, at the tunnel.
                    if (!certificateSelectionOffered && certificateAccess.needsSelection()) {
                        certificateSelectionOffered = true
                        publish(launchFlow.certificatePermissionRequired(), context)
                        return@launch
                    }

                    val token = applicationRestrictions.getString("token") ?: repo.getTokenSync()
                    val isRunning = TunnelService.isRunning(context)
                    val connectOnStart = repo.getConfigSync().connectOnStart

                    publish(
                        launchFlow.permissionsReady(
                            hasToken = !token.isNullOrBlank(),
                            isTunnelRunning = isRunning,
                            connectOnStart = connectOnStart,
                        ),
                        context,
                    )
                }
        }

        internal fun clearAction() {
            actionMutableStateFlow.value = null
        }

        private fun publish(
            action: SplashLaunchFlow.Action,
            context: Context,
        ) {
            actionMutableStateFlow.value =
                when (action) {
                    SplashLaunchFlow.Action.REQUEST_VPN_PERMISSION -> {
                        ViewAction.NavigateToVpnPermission
                    }

                    SplashLaunchFlow.Action.REQUEST_NOTIFICATION_PERMISSION -> {
                        ViewAction.NavigateToNotificationPermission
                    }

                    SplashLaunchFlow.Action.REQUEST_CERTIFICATE_PERMISSION -> {
                        ViewAction.NavigateToCertificatePermission
                    }

                    SplashLaunchFlow.Action.SIGN_IN -> {
                        ViewAction.NavigateToSignIn
                    }

                    SplashLaunchFlow.Action.OPEN_SESSION -> {
                        ViewAction.NavigateToSession
                    }

                    SplashLaunchFlow.Action.CONNECT_AND_OPEN_SESSION -> {
                        TunnelService.start(context)
                        ViewAction.NavigateToSession
                    }
                }
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

        private companion object {
            /**
             * Survives the ViewModel so the screen appears once per launch rather than every time
             * the splash re-checks, and returns on the next start while the certificate is still
             * out of reach.
             */
            @Volatile
            private var certificateSelectionOffered = false
        }

        internal sealed class ViewAction {
            object NavigateToVpnPermission : ViewAction()

            object NavigateToNotificationPermission : ViewAction()

            object NavigateToCertificatePermission : ViewAction()

            object NavigateToSettings : ViewAction()

            object NavigateToSignIn : ViewAction()

            object NavigateToSession : ViewAction()
        }
    }
