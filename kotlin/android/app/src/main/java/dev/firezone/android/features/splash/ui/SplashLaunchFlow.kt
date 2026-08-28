// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import androidx.lifecycle.SavedStateHandle

private const val INITIAL_LAUNCH_CONSUMED = "initialLaunchConsumed"

internal class SplashLaunchFlow(
    private val savedStateHandle: SavedStateHandle,
) {
    fun vpnPermissionRequired(): Action = Action.REQUEST_VPN_PERMISSION

    fun notificationPermissionRequired(): Action = Action.REQUEST_NOTIFICATION_PERMISSION

    fun certificatePermissionRequired(): Action = Action.REQUEST_CERTIFICATE_PERMISSION

    fun permissionsReady(
        hasToken: Boolean,
        isTunnelRunning: Boolean,
        connectOnStart: Boolean,
    ): Action {
        val shouldConnect = savedStateHandle[INITIAL_LAUNCH_CONSUMED] != true && connectOnStart
        savedStateHandle[INITIAL_LAUNCH_CONSUMED] = true

        if (!hasToken) {
            return Action.SIGN_IN
        }

        if (isTunnelRunning) {
            return Action.OPEN_SESSION
        }

        if (shouldConnect) {
            return Action.CONNECT_AND_OPEN_SESSION
        }

        return Action.SIGN_IN
    }

    enum class Action {
        REQUEST_VPN_PERMISSION,
        REQUEST_NOTIFICATION_PERMISSION,
        REQUEST_CERTIFICATE_PERMISSION,
        SIGN_IN,
        OPEN_SESSION,
        CONNECT_AND_OPEN_SESSION,
    }
}
