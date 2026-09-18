// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import dev.firezone.android.R
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.permission.certificate.ui.compose.CertificatePermissionScreen
import dev.firezone.android.features.permission.notification.ui.compose.NotificationPermissionScreen
import dev.firezone.android.features.permission.ui.CertificatePermissionViewModel
import dev.firezone.android.features.permission.vpn.ui.compose.VpnPermissionScreen
import dev.firezone.android.features.session.ui.SessionRoute
import dev.firezone.android.features.settings.ui.SettingsActivity
import dev.firezone.android.features.signin.ui.compose.SignInScreen
import dev.firezone.android.features.splash.ui.SplashViewModel

// Where the launch waits while the check decides. The system splash covers it; it has nothing
// of its own to draw.
private const val ROUTE_DECIDING = "deciding"
private const val ROUTE_SIGN_IN = "sign-in"
private const val ROUTE_SESSION = "session"
private const val ROUTE_VPN_PERMISSION = "vpn-permission"
private const val ROUTE_NOTIFICATION_PERMISSION = "notification-permission"
private const val ROUTE_CERTIFICATE_PERMISSION = "certificate-permission"

/**
 * Decides where the app belongs and holds the destinations it can reach.
 *
 * Every one of them is somewhere the app *is* rather than somewhere it went, so they replace each
 * other instead of stacking up and the check that picks between them lives here rather than in a
 * destination of its own.
 */
@Composable
internal fun AppShell(
    onNotificationPermissionRequested: () -> Unit,
    onSignInLaunched: () -> Unit,
    onLaunchResolved: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: SplashViewModel = hiltViewModel(),
) {
    val navController = rememberNavController()
    val activity = LocalActivity.current ?: return
    val action by viewModel.actionStateFlow.collectAsStateWithLifecycle()
    // Connect on start applies to the launch, not to every return to the shell.
    var isInitialLaunch by rememberSaveable { mutableStateOf(true) }
    // What a destination calls once it has done its part and the app needs placing again.
    val recheck = { viewModel.checkTunnelState(activity) }

    // The answer can change while the app is in the background, so the check runs on every resume
    // rather than once at launch.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        viewModel.checkTunnelState(activity, isInitialLaunch)
        isInitialLaunch = false
    }

    LaunchedEffect(action) {
        val destination = action ?: return@LaunchedEffect
        viewModel.clearAction()

        when (destination) {
            is SplashViewModel.ViewAction.NavigateToVpnPermission -> {
                navController.replaceWith(ROUTE_VPN_PERMISSION)
            }

            is SplashViewModel.ViewAction.NavigateToNotificationPermission -> {
                navController.replaceWith(ROUTE_NOTIFICATION_PERMISSION)
            }

            is SplashViewModel.ViewAction.NavigateToCertificatePermission -> {
                navController.replaceWith(ROUTE_CERTIFICATE_PERMISSION)
            }

            is SplashViewModel.ViewAction.NavigateToSignIn -> {
                navController.replaceWith(ROUTE_SIGN_IN)
            }

            is SplashViewModel.ViewAction.NavigateToSession -> {
                navController.replaceWith(ROUTE_SESSION)
            }
        }

        onLaunchResolved()
    }

    NavHost(navController = navController, startDestination = ROUTE_DECIDING, modifier = modifier) {
        composable(ROUTE_DECIDING) { }
        composable(ROUTE_SIGN_IN) { SignInRoute(onSignInLaunched) }
        composable(ROUTE_SESSION) { SessionRoute(onSessionEnded = recheck) }
        composable(ROUTE_VPN_PERMISSION) { VpnPermissionRoute(onGranted = recheck) }
        composable(ROUTE_NOTIFICATION_PERMISSION) {
            NotificationPermissionRoute(
                onRequested = {
                    onNotificationPermissionRequested()
                    recheck()
                },
            )
        }
        composable(ROUTE_CERTIFICATE_PERMISSION) { CertificatePermissionRoute(onSelected = recheck) }
    }
}

@Composable
private fun SignInRoute(onSignInLaunched: () -> Unit) {
    val context = LocalContext.current

    SignInScreen(
        onSignIn = {
            context.startActivity(Intent(context, AuthActivity::class.java))
            onSignInLaunched()
        },
        onSettings = { context.startActivity(SettingsActivity.createIntent(context, isUserSignedIn = false)) },
    )
}

@Composable
private fun CertificatePermissionRoute(
    onSelected: () -> Unit,
    viewModel: CertificatePermissionViewModel = hiltViewModel(),
) {
    val activity = LocalActivity.current ?: return
    var error by remember { mutableStateOf<String?>(null) }

    CertificatePermissionScreen(
        onSelectCertificate = {
            viewModel.chooseCertificate(activity) { outcome ->
                activity.runOnUiThread {
                    error =
                        when (outcome) {
                            CertificatePermissionViewModel.Outcome.Selected -> {
                                onSelected()
                                null
                            }

                            CertificatePermissionViewModel.Outcome.NothingSelected -> {
                                activity.getString(R.string.device_trust_no_certificate_selected)
                            }

                            is CertificatePermissionViewModel.Outcome.NotADeviceCertificate -> {
                                activity.getString(R.string.device_trust_not_device_certificate, outcome.alias)
                            }
                        }
                }
            }
        },
        error = error,
    )
}

@Composable
private fun VpnPermissionRoute(onGranted: () -> Unit) {
    val context = LocalContext.current
    val consent =
        rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            if (VpnService.prepare(context) == null) {
                onGranted()
            }
        }

    VpnPermissionScreen(
        onRequestPermission = {
            val request = VpnService.prepare(context)
            if (request == null) {
                onGranted()
            } else {
                consent.launch(request)
            }
        },
    )
}

@Composable
private fun NotificationPermissionRoute(onRequested: () -> Unit) {
    val context = LocalContext.current

    // Denying is not a failure: either answer counts as having asked, and the flow moves on.
    val done = {
        onRequested()
        Unit
    }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { done() }

    NotificationPermissionScreen(
        onRequestPermission = {
            val granted =
                Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    ContextCompat.checkSelfPermission(
                        context,
                        Manifest.permission.POST_NOTIFICATIONS,
                    ) == PackageManager.PERMISSION_GRANTED

            if (granted) done() else request.launch(Manifest.permission.POST_NOTIFICATIONS)
        },
        onSkip = done,
    )
}

// Nothing here is reached by going forwards, so nothing should be left behind to go back to:
// replacing the destination keeps the back stack one deep, which is what lets back close the app.
// The check runs again on every resume, so asking for the destination already on screen is normal
// and must not tear it down and rebuild it.
private fun NavHostController.replaceWith(route: String) {
    val current = currentDestination?.route ?: return

    if (current == route) {
        return
    }

    navigate(route) { popUpTo(current) { inclusive = true } }
}
