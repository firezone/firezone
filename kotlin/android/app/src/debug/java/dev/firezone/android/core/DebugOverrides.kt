// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import android.app.Activity
import android.net.Uri
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import dev.firezone.android.features.auth.AuthCallbackHandler
import dev.firezone.android.features.auth.PendingAuthSession
import dev.firezone.android.features.auth.ui.fabricatedAuthCallback
import dev.firezone.android.tunnel.MockSessionFactory
import dev.firezone.android.tunnel.SessionFactory

/**
 * Runs the app with connlib and the portal stood in for, the way `--mock-tunnel` and
 * `--skip-portal-auth` do for the GUI client. Debug builds only: the release source set defines
 * this object with nothing to configure, so a release build takes every real path.
 *
 * Both are extras on the launch, which an Android Studio run configuration can pass, or:
 *
 *     adb shell am start -n dev.firezone.android/.core.presentation.MainActivity \
 *       --ez mockTunnel true --ez skipPortalAuth true
 *
 * An extra that is absent leaves its stand-in as it was, because a launch the app hands itself,
 * such as the one after signing in, carries none.
 */
object DebugOverrides {
    /** Stands in for connlib, so the app runs with no portal and no tunnel. */
    @Volatile
    var sessionFactory: SessionFactory? = null
        private set

    @Volatile
    private var skipPortalAuth = false

    fun configure(activity: Activity) {
        val intent = activity.intent

        if (intent.hasExtra(EXTRA_MOCK_TUNNEL)) {
            sessionFactory = if (intent.getBooleanExtra(EXTRA_MOCK_TUNNEL, false)) MockSessionFactory else null
        }

        if (intent.hasExtra(EXTRA_SKIP_PORTAL_AUTH)) {
            skipPortalAuth = intent.getBooleanExtra(EXTRA_SKIP_PORTAL_AUTH, false)

            // Standing the portal down leaves the launch already signed in, which is also what a
            // session needs before connecting on start is in reach.
            if (skipPortalAuth) {
                signIn(activity)
            }
        }
    }

    /**
     * The callback a launch with the portal stood down answers the request that issued [state]
     * with, or `null` to send the user to the portal.
     */
    fun authCallback(state: String?): Uri? = if (skipPortalAuth) fabricatedAuthCallback(state) else null

    // Through the machinery a real callback drives, so the token is one the app issued.
    private fun signIn(activity: Activity) {
        val auth = EntryPointAccessors.fromApplication<AuthEntryPoint>(activity)

        auth.pendingAuthSession().begin(nonce = NONCE, state = STATE)
        auth.authCallbackHandler().handle(fabricatedAuthCallback(STATE))
    }

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    internal interface AuthEntryPoint {
        fun pendingAuthSession(): PendingAuthSession

        fun authCallbackHandler(): AuthCallbackHandler
    }

    private const val EXTRA_MOCK_TUNNEL = "mockTunnel"
    private const val EXTRA_SKIP_PORTAL_AUTH = "skipPortalAuth"
    private const val NONCE = "mock-launch-"
    private const val STATE = "mock-launch-state"
}
