// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SplashLaunchFlowTest {
    @Test
    fun `connects after granting VPN permission during initial launch`() {
        val launchFlow = SplashLaunchFlow()

        val permissionAction = launchFlow.vpnPermissionRequired()
        val resumedAction = launchFlow.resumeSignedInAndStopped()

        assertEquals(SplashLaunchFlow.Action.REQUEST_VPN_PERMISSION, permissionAction)
        assertEquals(SplashLaunchFlow.Action.CONNECT_AND_OPEN_SESSION, resumedAction)
    }

    @Test
    fun `connects after granting notification permission during initial launch`() {
        val launchFlow = SplashLaunchFlow()

        val permissionAction = launchFlow.notificationPermissionRequired()
        val resumedAction = launchFlow.resumeSignedInAndStopped()

        assertEquals(SplashLaunchFlow.Action.REQUEST_NOTIFICATION_PERMISSION, permissionAction)
        assertEquals(SplashLaunchFlow.Action.CONNECT_AND_OPEN_SESSION, resumedAction)
    }

    @Test
    fun `connects after skipping or denying notification permission during initial launch`() {
        listOf("skipped", "denied").forEach { outcome ->
            val launchFlow = SplashLaunchFlow()

            val permissionAction = launchFlow.notificationPermissionRequired()
            val resumedAction = launchFlow.resumeSignedInAndStopped()

            assertEquals(
                outcome,
                SplashLaunchFlow.Action.REQUEST_NOTIFICATION_PERMISSION,
                permissionAction,
            )
            assertEquals(
                outcome,
                SplashLaunchFlow.Action.CONNECT_AND_OPEN_SESSION,
                resumedAction,
            )
        }
    }

    @Test
    fun `connects after both permission detours during initial launch`() {
        val launchFlow = SplashLaunchFlow()

        val vpnPermissionAction = launchFlow.vpnPermissionRequired()
        val notificationPermissionAction = launchFlow.notificationPermissionRequired()
        val resumedAction = launchFlow.resumeSignedInAndStopped()

        assertEquals(SplashLaunchFlow.Action.REQUEST_VPN_PERMISSION, vpnPermissionAction)
        assertEquals(SplashLaunchFlow.Action.REQUEST_NOTIFICATION_PERMISSION, notificationPermissionAction)
        assertEquals(SplashLaunchFlow.Action.CONNECT_AND_OPEN_SESSION, resumedAction)
    }

    @Test
    fun `does not reconnect on a later ordinary resume`() {
        val launchFlow = SplashLaunchFlow()

        val initialAction = launchFlow.resumeSignedInAndStopped()
        val laterAction = launchFlow.resumeSignedInAndStopped()

        assertEquals(SplashLaunchFlow.Action.CONNECT_AND_OPEN_SESSION, initialAction)
        assertEquals(SplashLaunchFlow.Action.SIGN_IN, laterAction)
    }

    private fun SplashLaunchFlow.resumeSignedInAndStopped(): SplashLaunchFlow.Action =
        permissionsReady(
            hasToken = true,
            isTunnelRunning = false,
            connectOnStart = true,
        )
}
