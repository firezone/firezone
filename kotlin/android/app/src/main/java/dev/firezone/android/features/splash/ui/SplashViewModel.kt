// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
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
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.x509.CertificateAccess
import dev.firezone.android.core.x509.KeyChain
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
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
        private val applicationRestrictions: Bundle,
        private val applicationMode: ApplicationMode,
        private val certificateAccess: CertificateAccess,
        private val keyChain: KeyChain,
    ) : ViewModel() {
        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow
        private var check: Job? = null

        internal fun checkTunnelState(
            activity: Activity,
            isInitialLaunch: Boolean = false,
        ) {
            // Asking the device policy goes through an Activity of the KeyChain's, and coming back
            // from it resumes the splash into a check that is still waiting for the answer.
            if (check?.isActive == true) {
                return
            }

            check =
                viewModelScope.launch {
                    checkTunnelStateNow(activity, isInitialLaunch)
                }
        }

        private suspend fun checkTunnelStateNow(
            activity: Activity,
            isInitialLaunch: Boolean,
        ) {
            // Stay a while and enjoy the logo
            delay(REQUEST_DELAY)

            // If we don't have VPN permission, we can't continue.
            if (!hasVpnPermissions(activity) && applicationMode != ApplicationMode.TESTING) {
                actionMutableStateFlow.value = ViewAction.NavigateToVpnPermission
                return
            }

            // Check if we need to request notification permission (only once)
            if (shouldRequestNotificationPermission(activity)) {
                actionMutableStateFlow.value = ViewAction.NavigateToNotificationPermission
                return
            }

            // An administrator can name the certificate by answering the KeyChain for us, which
            // takes no configuration on our side and no tap on the user's. Ask once per launch
            // whenever nothing we hold loads, so a rotated certificate is picked up too.
            if (!policyAsked && certificateAccess.needsPolicyAlias()) {
                policyAsked = true
                repo.savePolicyX509CertificateAliasSync(askPolicyForAlias(activity))
            }

            // An administrator can configure a certificate that only the user can release, which
            // is what a work profile on a personally-owned device looks like. Ask once per
            // launch: pressing on without it only fails later, at the tunnel.
            if (!certificateSelectionOffered && certificateAccess.needsSelection()) {
                certificateSelectionOffered = true
                actionMutableStateFlow.value = ViewAction.NavigateToCertificatePermission
                return
            }

            val token = applicationRestrictions.getString("token") ?: tokenStore.get()

            if (token.isNullOrBlank()) {
                actionMutableStateFlow.value = ViewAction.NavigateToSignIn
                return
            }

            val isRunning = TunnelService.isRunning(activity)

            // If the service is already running, we can go directly to the session.
            if (isRunning) {
                actionMutableStateFlow.value = ViewAction.NavigateToSession
                return
            }

            val connectOnStart = repo.getConfigSync().connectOnStart

            // If this is the initial launch and connectOnStart is true, try to connect
            if (isInitialLaunch && connectOnStart) {
                TunnelService.start(activity)
                actionMutableStateFlow.value = ViewAction.NavigateToSession
                return
            }

            // If we get here, we shouldn't start the tunnel, so show the sign in screen
            actionMutableStateFlow.value = ViewAction.NavigateToSignIn
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
            /**
             * Survives the ViewModel so the screen appears once per launch rather than every time
             * the splash re-checks, and returns on the next start while the certificate is still
             * out of reach. Tests reset it, since they share one process across many launches.
             */
            @Volatile
            internal var certificateSelectionOffered = false

            /** Once per launch as well: the answer is recorded, so asking again gains nothing. */
            @Volatile
            internal var policyAsked = false
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
