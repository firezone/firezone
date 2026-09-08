// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.tunnel.MockSessionFactory
import javax.inject.Inject

/**
 * Starts the app with connlib and the portal stood in for, the way `--mock-tunnel` and
 * `--skip-portal-auth` do for the GUI client. Debug builds only; see `mise run //kotlin/android:dev-mock`.
 *
 * Both stand-ins are on unless an extra turns one off, so either half can be exercised against the
 * real other half:
 *
 *     adb shell am start -n dev.firezone.android/dev.firezone.android.core.MockLaunchActivity \
 *       --ez skipPortalAuth false
 */
@AndroidEntryPoint
class MockLaunchActivity : ComponentActivity() {
    @Inject
    internal lateinit var tokenStore: TokenStore

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent.getBooleanExtra("mockTunnel", true)) {
            DebugOverrides.sessionFactory = MockSessionFactory
        }
        DebugOverrides.skipPortalAuth = intent.getBooleanExtra("skipPortalAuth", true)

        // Every mock launch starts signed out, so it walks the sign-in it stands in for rather than
        // resuming one. It also keeps a fabricated token from outliving the launch that made it,
        // which a later real launch would otherwise present to the portal.
        tokenStore.clear()

        startActivity(
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK
            },
        )
        finish()
    }
}
