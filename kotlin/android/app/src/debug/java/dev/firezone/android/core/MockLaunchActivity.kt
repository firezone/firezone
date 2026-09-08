// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.features.auth.AuthCallbackHandler
import dev.firezone.android.features.auth.PendingAuthSession
import dev.firezone.android.features.auth.ui.fabricatedAuthCallback
import dev.firezone.android.tunnel.MockSessionFactory
import javax.inject.Inject

/**
 * Starts the app with connlib and the portal stood in for, the way `--mock-tunnel` and
 * `--skip-portal-auth` do for the GUI client. Debug builds only; see `mise run //kotlin/android:dev-mock`.
 *
 * Each extra is on unless one turns it off, so either stand-in can be exercised against the real
 * other half, and the launch can start from either side of sign-in:
 *
 *     adb shell am start -n dev.firezone.android/dev.firezone.android.core.MockLaunchActivity \
 *       --ez skipPortalAuth false --ez signedIn true
 */
@AndroidEntryPoint
class MockLaunchActivity : ComponentActivity() {
    @Inject
    internal lateinit var tokenStore: TokenStore

    @Inject
    internal lateinit var pendingAuthSession: PendingAuthSession

    @Inject
    internal lateinit var authCallbackHandler: AuthCallbackHandler

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent.getBooleanExtra("mockTunnel", true)) {
            DebugOverrides.sessionFactory = MockSessionFactory
        }
        DebugOverrides.skipPortalAuth = intent.getBooleanExtra("skipPortalAuth", true)

        // Where the launch starts is the launch's to say, so that neither the sign-in flow nor
        // what a signed-in launch does, such as connecting on start, depends on what the last one
        // left behind.
        if (intent.getBooleanExtra("signedIn", false)) {
            signIn()
        } else {
            tokenStore.clear()
        }

        startActivity(
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK
            },
        )
        finish()
    }

    /** Signs in through the machinery a real callback drives, so the token is one the app issued. */
    private fun signIn() {
        pendingAuthSession.begin(nonce = NONCE, state = STATE)
        authCallbackHandler.handle(fabricatedAuthCallback(STATE))
    }

    private companion object {
        const val NONCE = "mock-launch-"
        const val STATE = "mock-launch-state"
    }
}
