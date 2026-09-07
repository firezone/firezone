// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.ApplicationMode
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.x509.CertificateAccess
import dev.firezone.android.core.x509.KeyChain
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import kotlin.coroutines.resume

private const val REQUEST_DELAY = 1000L
private const val POLICY_ANSWER_TIMEOUT = 10_000L

@HiltViewModel
internal class SplashViewModel
    @Inject
    constructor(
        private val repo: Repository,
        private val tokenStore: TokenStore,
        private val managedConfigurationSource: ManagedConfigurationSource,
        private val applicationMode: ApplicationMode,
        private val certificateAccess: CertificateAccess,
        private val keyChain: KeyChain,
        savedStateHandle: SavedStateHandle,
    ) : ViewModel() {
        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        private val launchFlow = SplashLaunchFlow(savedStateHandle)
        private var check: Job? = null
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow

        internal fun checkTunnelState(activity: Activity) {
            // Asking the device policy goes through an Activity of the KeyChain's, and coming back
            // from it resumes the splash into a check that is still waiting for the answer.
            if (check?.isActive == true) {
                return
            }

            check = viewModelScope.launch { checkTunnelStateNow(activity) }
        }

        private suspend fun checkTunnelStateNow(activity: Activity) {
            // Stay a while and enjoy the logo
            delay(REQUEST_DELAY)

            // If we don't have VPN permission, we can't continue.
            if (!hasVpnPermissions(activity) && applicationMode != ApplicationMode.TESTING) {
                publish(launchFlow.vpnPermissionRequired(), activity)
                return
            }

            // Check if we need to request notification permission (only once)
            if (shouldRequestNotificationPermission(activity)) {
                publish(launchFlow.notificationPermissionRequired(), activity)
                return
            }

            // An administrator can name the certificate by answering the KeyChain for us, which
            // takes no configuration on our side and no tap on the user's. Ask once per launch
            // whenever nothing we hold loads, so a rotated certificate is picked up too.
            if (!policyAsked && certificateAccess.needsDiscovery()) {
                policyAsked = true
                rememberPolicyAlias(activity)
            }

            // An administrator who requires a certificate the policy did not hand over leaves
            // only the user to release it, which is what a work profile on a personally-owned
            // device looks like. There is no way around that screen: coming back to the splash
            // lands on it again until the certificate is released.
            if (certificateAccess.needsSelection()) {
                actionMutableStateFlow.value = ViewAction.NavigateToCertificatePermission
                return
            }

            val managedConfiguration = managedConfigurationSource.refresh()
            val credential = managedConfiguration.resolveSessionCredential(tokenStore.get())
            val isRunning = TunnelService.isRunning(activity)
            val connectOnStart =
                repo
                    .getEffectiveConfig(repo.getUserConfigSync(), managedConfiguration)
                    .connectOnStart

            publish(
                launchFlow.permissionsReady(
                    hasToken = credential != null,
                    isTunnelRunning = isRunning,
                    connectOnStart = connectOnStart,
                ),
                activity,
            )
        }

        /** Records the alias the device policy names, provided it holds a device certificate. */
        private suspend fun rememberPolicyAlias(activity: Activity) {
            val alias = askPolicyForAlias(activity) ?: return

            if (withContext(Dispatchers.IO) { certificateAccess.holdsDeviceCertificate(alias) }) {
                repo.saveX509CertificateAliasSync(alias)
            } else {
                Log.w(TAG, "The device policy named alias '$alias', which holds no device certificate")
            }
        }

        /** The alias the device policy names for the portal, or `null` when it names none in time. */
        private suspend fun askPolicyForAlias(activity: Activity): String? =
            withTimeoutOrNull(POLICY_ANSWER_TIMEOUT) {
                suspendCancellableCoroutine { continuation ->
                    keyChain.policyAlias(activity, apiUri()) { alias ->
                        if (continuation.isActive) {
                            continuation.resume(alias)
                        }
                    }
                }
            }

        /** The portal the certificate is meant for, which a policy may scope its answer to. */
        private fun apiUri(): Uri? = runCatching { Uri.parse(repo.getConfigSync().apiUrl) }.getOrNull()

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

        internal companion object {
            private const val TAG = "SplashViewModel"

            /**
             * Survives the ViewModel so the policy is asked once per launch rather than every time
             * the splash re-checks: the answer is recorded, so asking again gains nothing. Tests
             * reset it, since they share one process across many launches.
             */
            @Volatile
            internal var policyAsked = false
        }

        internal sealed class ViewAction {
            object NavigateToVpnPermission : ViewAction()

            object NavigateToNotificationPermission : ViewAction()

            object NavigateToCertificatePermission : ViewAction()

            object NavigateToSignIn : ViewAction()

            object NavigateToSession : ViewAction()
        }
    }
