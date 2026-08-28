// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.features.permission.ui.compose.NotificationPermissionScreen
import dev.firezone.android.features.permission.ui.compose.VpnPermissionScreen
import dev.firezone.android.features.session.ui.SessionActivity
import dev.firezone.android.features.settings.ui.SettingsActivity
import dev.firezone.android.features.signin.ui.compose.SignInScreen
import dev.firezone.android.features.splash.ui.SplashViewModel
import dev.firezone.android.features.splash.ui.compose.SplashScreen

private const val ROUTE_SPLASH = "splash"
private const val ROUTE_SIGN_IN = "sign-in"
private const val ROUTE_VPN_PERMISSION = "vpn-permission"
private const val ROUTE_NOTIFICATION_PERMISSION = "notification-permission"

@Composable
fun AppNavHost(
    onNotificationPermissionRequested: () -> Unit,
    onSignInLaunched: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val navController = rememberNavController()

    NavHost(navController = navController, startDestination = ROUTE_SPLASH, modifier = modifier) {
        composable(ROUTE_SPLASH) { SplashRoute(navController) }
        composable(ROUTE_SIGN_IN) { SignInRoute(onSignInLaunched) }
        composable(ROUTE_VPN_PERMISSION) { VpnPermissionRoute(navController) }
        composable(ROUTE_NOTIFICATION_PERMISSION) {
            NotificationPermissionRoute(navController, onNotificationPermissionRequested)
        }
    }
}

@Composable
private fun SplashRoute(
    navController: NavHostController,
    viewModel: SplashViewModel = hiltViewModel(),
) {
    val context = LocalContext.current
    val action by viewModel.actionStateFlow.collectAsStateWithLifecycle()

    // The other destinations hand control back here when they are done, and the answer can change
    // while the app is in the background, so the check runs on every resume rather than once.
    LifecycleResumeEffect(Unit) {
        viewModel.checkTunnelState(context)
        onPauseOrDispose {}
    }

    LaunchedEffect(action) {
        val destination = action ?: return@LaunchedEffect
        viewModel.clearAction()

        when (destination) {
            is SplashViewModel.ViewAction.NavigateToVpnPermission -> {
                navController.navigateOnce(ROUTE_VPN_PERMISSION)
            }

            is SplashViewModel.ViewAction.NavigateToNotificationPermission -> {
                navController.navigateOnce(ROUTE_NOTIFICATION_PERMISSION)
            }

            is SplashViewModel.ViewAction.NavigateToSignIn -> {
                navController.navigateOnce(ROUTE_SIGN_IN)
            }

            is SplashViewModel.ViewAction.NavigateToSession -> {
                context.startActivity(
                    Intent(context, SessionActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    },
                )
            }
        }
    }

    SplashScreen()
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
private fun VpnPermissionRoute(navController: NavHostController) {
    val context = LocalContext.current
    val consent =
        rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            if (VpnService.prepare(context) == null) {
                navController.popBackStack()
            }
        }

    VpnPermissionScreen(
        onRequestPermission = {
            val request = VpnService.prepare(context)
            if (request == null) {
                navController.popBackStack()
            } else {
                consent.launch(request)
            }
        },
    )
}

@Composable
private fun NotificationPermissionRoute(
    navController: NavHostController,
    onNotificationPermissionRequested: () -> Unit,
) {
    val context = LocalContext.current

    // Denying is not a failure: either answer counts as having asked, and the flow moves on.
    val done = {
        onNotificationPermissionRequested()
        navController.popBackStack()
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

// The splash check runs again on every resume, so it can ask for the same destination twice.
private fun NavHostController.navigateOnce(route: String) = navigate(route) { launchSingleTop = true }
